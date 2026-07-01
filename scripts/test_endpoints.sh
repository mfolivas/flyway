#!/usr/bin/env bash
#
# Smoke-test the trading API endpoints against a running stack.
# Exits 0 on success, non-zero on the first failure.
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
    local body
    body=$(http_body "${BASE_URL}/health")
    local db_status
    db_status=$(printf '%s' "${body}" | jq -r '.database')
    assert_eq "database reachable" "reachable" "${db_status}"
}

test_list_seed_data() {
    info "GET /trades (expect at least 3 seed rows)"
    local count
    count=$(http_body "${BASE_URL}/trades" | jq 'length')
    if (( count >= 3 )); then
        pass "seed rows present (count=${count})"
    else
        fail "expected >= 3 seed rows, got ${count}"
    fi
}

test_create_buy() {
    info "POST /trades (BUY)"
    local status_code
    status_code=$(http_status -X POST "${BASE_URL}/trades" \
        -H 'Content-Type: application/json' \
        -d '{"symbol":"NVDA","side":"BUY","quantity":10,"price":950.50}')
    assert_eq "BUY create status" "201" "${status_code}"
}

test_create_sell_and_capture_id() {
    info "POST /trades (SELL) and capture id"
    local body
    body=$(http_body -X POST "${BASE_URL}/trades" \
        -H 'Content-Type: application/json' \
        -d '{"symbol":"AMD","side":"SELL","quantity":5,"price":170.25}')
    created_id=$(printf '%s' "${body}" | jq -r '.id')
    if [[ -n "${created_id}" && "${created_id}" != "null" ]]; then
        pass "SELL create returned id=${created_id}"
    else
        fail "SELL create did not return an id (body=${body})"
        exit 1
    fi
}

test_filter_by_symbol() {
    info "GET /trades?symbol=NVDA"
    local count
    count=$(http_body "${BASE_URL}/trades?symbol=NVDA" | jq 'length')
    if (( count >= 1 )); then
        pass "symbol filter returned ${count} rows"
    else
        fail "symbol filter returned no rows"
    fi
}

test_filter_by_side() {
    info "GET /trades?side=BUY"
    local nonbuy
    nonbuy=$(http_body "${BASE_URL}/trades?side=BUY" | jq '[.[] | select(.side != "BUY")] | length')
    assert_eq "no non-BUY rows in side=BUY filter" "0" "${nonbuy}"
}

test_get_one() {
    info "GET /trades/${created_id}"
    local status_code
    status_code=$(http_status "${BASE_URL}/trades/${created_id}")
    assert_eq "GET one status" "200" "${status_code}"
}

test_update() {
    info "PUT /trades/${created_id}"
    local status_code
    status_code=$(http_status -X PUT "${BASE_URL}/trades/${created_id}" \
        -H 'Content-Type: application/json' \
        -d '{"price":175.00}')
    assert_eq "PUT status" "200" "${status_code}"
}

test_delete() {
    info "DELETE /trades/${created_id}"
    local status_code
    status_code=$(http_status -X DELETE "${BASE_URL}/trades/${created_id}")
    assert_eq "DELETE status" "204" "${status_code}"
    local followup
    followup=$(http_status "${BASE_URL}/trades/${created_id}")
    assert_eq "GET after DELETE" "404" "${followup}"
}

test_not_found() {
    info "GET /trades/999999 (expect 404)"
    local status_code
    status_code=$(http_status "${BASE_URL}/trades/999999")
    assert_eq "unknown trade returns 404" "404" "${status_code}"
}

main() {
    created_id=""

    if ! command -v jq >/dev/null; then
        fail "jq is required (brew install jq)"
        exit 1
    fi

    wait_for_api
    test_health
    test_list_seed_data
    test_create_buy
    test_create_sell_and_capture_id
    test_filter_by_symbol
    test_filter_by_side
    test_get_one
    test_update
    test_delete
    test_not_found

    info "----------------------------------------"
    info "passed=${pass_count} failed=${fail_count}"
    if (( fail_count > 0 )); then
        exit 1
    fi
    info "All checks passed."
}

main "$@"
