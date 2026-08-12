#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=docker/scripts/test/_helpers.sh
source "$HERE/_helpers.sh"
ENTRY="$HERE/../../entrypoint.sh"

# The RT warning reads a capability bitset. Tests point BHF_CAPS_FILE at a
# fixture so the outcome does not depend on the host: macOS has no /proc, and
# a Linux CI runner reports full caps, so a host-dependent test would pass
# vacuously on one and fail on the other.
mk_caps() {
  local d bits
  d=$(mktemp -d); bits="$1"
  printf 'Name:\tbash\nCapBnd:\t%s\nSeccomp:\t0\n' "$bits" > "$d/status"
  echo "$d/status"
}

test_passthrough_runs_command() {
  local out caps
  caps=$(mk_caps 000001ffffffffff)
  out=$(BHF_CAPS_FILE="$caps" bash "$ENTRY" echo hello 2>/dev/null)
  rm -rf "$(dirname "$caps")"
  assert_equals "hello" "$out" "passthrough should exec the given command"
}

test_passthrough_preserves_exit_code() {
  local got caps
  caps=$(mk_caps 000001ffffffffff)
  set +e
  BHF_CAPS_FILE="$caps" bash "$ENTRY" sh -c 'exit 3' >/dev/null 2>&1
  got=$?
  set -e
  rm -rf "$(dirname "$caps")"
  assert_equals 3 "$got" "exit code of the exec'd command must survive"
}

test_warns_when_capabilities_are_empty() {
  local err caps
  caps=$(mk_caps 0000000000000000)
  err=$(BHF_CAPS_FILE="$caps" bash "$ENTRY" true 2>&1 >/dev/null)
  rm -rf "$(dirname "$caps")"
  assert_contains "$err" "real-time" "zero caps should warn about real-time"
}

test_silent_when_capabilities_look_privileged() {
  local err caps
  caps=$(mk_caps 000001ffffffffff)
  err=$(BHF_CAPS_FILE="$caps" bash "$ENTRY" true 2>&1 >/dev/null)
  rm -rf "$(dirname "$caps")"
  assert_equals "" "$err" "full caps should produce no warning"
}

test_warns_when_caps_file_is_absent() {
  local err
  err=$(BHF_CAPS_FILE=/nonexistent/status bash "$ENTRY" true 2>&1 >/dev/null)
  assert_contains "$err" "real-time" "unreadable caps file should warn, not crash"
}

test_quiet_suppresses_warning() {
  local err caps
  caps=$(mk_caps 0000000000000000)
  err=$(BHF_QUIET=1 BHF_CAPS_FILE="$caps" bash "$ENTRY" true 2>&1 >/dev/null)
  rm -rf "$(dirname "$caps")"
  assert_equals "" "$err" "BHF_QUIET=1 must silence the warning"
}

test_no_args_starts_a_shell() {
  local got caps
  caps=$(mk_caps 000001ffffffffff)
  set +e
  BHF_CAPS_FILE="$caps" bash "$ENTRY" </dev/null >/dev/null 2>&1
  got=$?
  set -e
  rm -rf "$(dirname "$caps")"
  assert_equals 0 "$got" "no args should exec a shell, which exits 0 on EOF"
}

run_tests
