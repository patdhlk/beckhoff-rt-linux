#!/usr/bin/env bash
# Tiny test helpers. Source this, declare test_* functions, then call run_tests.
set -euo pipefail

TESTS_RUN=0
TESTS_FAILED=0
FAILED_NAMES=()

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILED_NAMES+=("${TEST_NAME:-?}")
  echo "FAIL: ${TEST_NAME:-?}: $*" >&2
}

assert_equals() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$expected" != "$actual" ]; then
    fail "expected '$expected', got '$actual' $msg"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected to contain '$needle', got '$haystack' $msg" ;;
  esac
}

assert_exit_code() {
  local expected="$1"; shift
  set +e
  ( "$@" ) >/dev/null 2>&1
  local got=$?
  set -e
  if [ "$got" -ne "$expected" ]; then
    fail "expected exit $expected, got $got from: $*"
  fi
}

run_tests() {
  local fn rc before_failures
  for fn in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
    TEST_NAME="$fn"
    TESTS_RUN=$((TESTS_RUN + 1))
    before_failures=$TESTS_FAILED
    set +e
    "$fn"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] && [ "$TESTS_FAILED" -eq "$before_failures" ]; then
      fail "test exited with code $rc (no assertion failed; unhandled error)"
    fi
  done
  echo
  echo "Tests run: $TESTS_RUN  Failed: $TESTS_FAILED" >&2
  if [ "$TESTS_FAILED" -gt 0 ]; then
    printf '  - %s\n' "${FAILED_NAMES[@]}" >&2
    exit 1
  fi
}
