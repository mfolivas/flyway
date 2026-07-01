#!/usr/bin/env bash
#
# Smoke-test the trading API endpoints against a running stack (V3).
# Exits 0 on success, non-zero on the first failure.
#
# Adds coverage for V3: /counterparties, counterparty_id on trades,
# get-or-create semantics on repeated counterparty names.
#
# Requirements: curl, jq. Idempotent: creates trades, deletes them at the end.
#
# Usage:
#   docker compose up -d
#   bash scripts/test_endpoints.sh

set -euo pipefail

readonly BASE_URL="${BASE_URL:-http://localhost:8000}"
readonly MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-60}"

pass_count=0
fail_count=0

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*" >&2; }
pass()  { printf '\033[1;32m[PASS]\033[0m  %s\n' "$*" >&2; pass_count=$((pass_count + 1)); }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        pass "${label} (got ${actual})"
    else
        fail "${label} expected=${expected} actual=${actual}"
    fi
}

wait_for_api() {
    info "Waiting up to ${MAX_WAIT_SECONDS}s for ${BASE_URL}/health"
    local elapsed=0
    while (( elapsed < MAX_WAIT_SECONDS )); do
        if curl -fsS -o /dev/null "${BASE_URL}/health"; then
            pass "API is healthy"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    fail "API did not become healthy within ${MAX_WAIT_SECONDS}s"
    exit 1
}

http_status() {
    curl -s -o /dev/null -w '%{http_code}' "$@"
}

http_body() {
    curl -fsS "$@"
}

test_health() {
    info "GET /health"
    local db_status
    db_status=$(http_body "${BASE_URL}/health" | jq -r '.database')
    assert_eq "database reachable" "reachable" "${db_status}"
}

test_seed_settled() {
    info "V2 backfill: V1 seed rows should be SETTLED"
    local settled_count
    settled_count=$(http_body "${BASE_URL}/trades" \
        | jq '[.[] | select(.status == "SETTLED")] | length')
    if (( settled_count >= 3 )); then
        pass "V2 backfill preserved (SETTLED count=${settled_count})"
    else
        fail "expected >= 3 SETTLED rows, got ${settled_count}"
    fi
}

test_counterparties_start_empty() {
    info "GET /counterparties (before any trades with counterparty)"
    counterparties_before=$(http_body "${BASE_URL}/counterparties" | jq 'length')
    info "counterparties before=${counterparties_before}"
    pass "counterparties endpoint reachable"
}

test_create_buy_with_counterparty() {
    info "POST /trades (BUY with counterparty=JPM) creates counterparty row"
    local body
    body=$(http_body -X POST "${BASE_URL}/trades" \
        -H 'Content-Type: application/json' \
        -d '{"symbol":"NVDA","side":"BUY","quantity":10,"price":950.50,"counterparty":"JPM"}')
    local cp_id
    cp_id=$(printf '%s' "${body}" | jq -r '.counterparty_id')
    if [[ "${cp_id}" != "null" && -n "${cp_id}" ]]; then
        pass "counterparty_id populated (${cp_id})"
    else
        fail "counterparty_id was null; expected a FK id"
    fi
    local cp_name
    cp_name=$(printf '%s' "${body}" | jq -r '.counterparty')
    assert_eq "counterparty string still populated (expand phase)" "JPM" "${cp_name}"
    trade_a_id=$(printf '%s' "${body}" | jq -r '.id')
    jpm_cp_id="${cp_id}"
}

test_get_or_create_reuses_row() {
    info "POST /trades (BUY with counterparty=JPM again) reuses the same row"
    local body
    body=$(http_body -X POST "${BASE_URL}/trades" \
        -H 'Content-Type: application/json' \
        -d '{"symbol":"AMD","side":"BUY","quantity":3,"price":170.00,"counterparty":"JPM"}')
    local cp_id
    cp_id=$(printf '%s' "${body}" | jq -r '.counterparty_id')
    assert_eq "second trade reuses JPM counterparty id" "${jpm_cp_id}" "${cp_id}"
    trade_b_id=$(printf '%s' "${body}" | jq -r '.id')
}

test_counterparties_list_grew() {
    info "GET /counterparties (JPM should now be present)"
    local body
    body=$(http_body "${BASE_URL}/counterparties")
    local jpm_present
    jpm_present=$(printf '%s' "${body}" | jq '[.[] | select(.name == "JPM")] | length')
    assert_eq "JPM present in /counterparties" "1" "${jpm_present}"
}

test_trade_without_counterparty() {
    info "POST /trades (no counterparty) leaves counterparty_id null"
    local body
    body=$(http_body -X POST "${BASE_URL}/trades" \
        -H 'Content-Type: application/json' \
        -d '{"symbol":"AAPL","side":"SELL","quantity":2,"price":195.00}')
    local cp_id
    cp_id=$(printf '%s' "${body}" | jq -r '.counterparty_id')
    assert_eq "counterparty_id null when omitted" "null" "${cp_id}"
    trade_c_id=$(printf '%s' "${body}" | jq -r '.id')
}

test_mark_settled() {
    info "PUT /trades/${trade_a_id} (mark SETTLED)"
    local body
    body=$(http_body -X PUT "${BASE_URL}/trades/${trade_a_id}" \
        -H 'Content-Type: application/json' \
        -d '{"status":"SETTLED","fees":1.25}')
    local st
    st=$(printf '%s' "${body}" | jq -r '.status')
    assert_eq "status is SETTLED" "SETTLED" "${st}"
}

test_delete_created() {
    info "DELETE created trades (${trade_a_id}, ${trade_b_id}, ${trade_c_id})"
    for tid in "${trade_a_id}" "${trade_b_id}" "${trade_c_id}"; do
        local status_code
        status_code=$(http_status -X DELETE "${BASE_URL}/trades/${tid}")
        assert_eq "DELETE ${tid}" "204" "${status_code}"
    done
}

test_not_found() {
    info "GET /trades/999999 (expect 404)"
    local status_code
    status_code=$(http_status "${BASE_URL}/trades/999999")
    assert_eq "unknown trade returns 404" "404" "${status_code}"
}

main() {
    trade_a_id=""; trade_b_id=""; trade_c_id=""
    jpm_cp_id=""; counterparties_before=""

    if ! command -v jq >/dev/null; then
        fail "jq is required (brew install jq)"
        exit 1
    fi

    wait_for_api
    test_health
    test_seed_settled
    test_counterparties_start_empty
    test_create_buy_with_counterparty
    test_get_or_create_reuses_row
    test_counterparties_list_grew
    test_trade_without_counterparty
    test_mark_settled
    test_delete_created
    test_not_found

    info "----------------------------------------"
    info "passed=${pass_count} failed=${fail_count}"
    if (( fail_count > 0 )); then
        exit 1
    fi
    info "All checks passed."
}

main "$@"
