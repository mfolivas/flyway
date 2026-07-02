#!/usr/bin/env bash
#
# Smoke-test the trading API endpoints against a running stack (V4).
# Exits 0 on success, non-zero on the first failure.
#
# V4 is a forward-only rollback of V3. Compared to step-3, this script:
#   - asserts /counterparties is gone (404, not reachable)
#   - asserts trade responses no longer expose counterparty_id
#   - keeps V2 coverage (status/fees/counterparty string, SETTLED backfill)
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
    info "V2 backfill preserved: V1 seed rows should still be SETTLED"
    local settled_count
    settled_count=$(http_body "${BASE_URL}/trades" \
        | jq '[.[] | select(.status == "SETTLED")] | length')
    if (( settled_count >= 3 )); then
        pass "V2 backfill preserved after V4 rollback (SETTLED count=${settled_count})"
    else
        fail "expected >= 3 SETTLED rows, got ${settled_count}"
    fi
}

test_counterparties_endpoint_gone() {
    info "GET /counterparties should be gone after V4 rollback"
    local status_code
    status_code=$(http_status "${BASE_URL}/counterparties")
    assert_eq "/counterparties returns 404" "404" "${status_code}"
}

test_create_with_counterparty_string() {
    info "POST /trades with counterparty=JPM writes the string only"
    local body
    body=$(http_body -X POST "${BASE_URL}/trades" \
        -H 'Content-Type: application/json' \
        -d '{"symbol":"NVDA","side":"BUY","quantity":10,"price":950.50,"counterparty":"JPM"}')
    local cp_name
    cp_name=$(printf '%s' "${body}" | jq -r '.counterparty')
    assert_eq "counterparty string echoed back" "JPM" "${cp_name}"
    local cp_id_present
    cp_id_present=$(printf '%s' "${body}" | jq 'has("counterparty_id")')
    assert_eq "counterparty_id absent from response" "false" "${cp_id_present}"
    trade_a_id=$(printf '%s' "${body}" | jq -r '.id')
}

test_create_without_counterparty() {
    info "POST /trades without counterparty succeeds"
    local body
    body=$(http_body -X POST "${BASE_URL}/trades" \
        -H 'Content-Type: application/json' \
        -d '{"symbol":"AAPL","side":"SELL","quantity":2,"price":195.00}')
    local cp_name
    cp_name=$(printf '%s' "${body}" | jq -r '.counterparty')
    assert_eq "counterparty null when omitted" "null" "${cp_name}"
    trade_b_id=$(printf '%s' "${body}" | jq -r '.id')
}

test_mark_settled() {
    info "PUT /trades/${trade_a_id} (mark SETTLED with fees)"
    local body
    body=$(http_body -X PUT "${BASE_URL}/trades/${trade_a_id}" \
        -H 'Content-Type: application/json' \
        -d '{"status":"SETTLED","fees":1.25}')
    local st
    st=$(printf '%s' "${body}" | jq -r '.status')
    assert_eq "status is SETTLED" "SETTLED" "${st}"
}

test_delete_created() {
    info "DELETE created trades (${trade_a_id}, ${trade_b_id})"
    for tid in "${trade_a_id}" "${trade_b_id}"; do
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
    trade_a_id=""; trade_b_id=""

    if ! command -v jq >/dev/null; then
        fail "jq is required (brew install jq)"
        exit 1
    fi

    wait_for_api
    test_health
    test_seed_settled
    test_counterparties_endpoint_gone
    test_create_with_counterparty_string
    test_create_without_counterparty
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
