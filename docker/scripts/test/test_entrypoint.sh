#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=docker/scripts/test/_helpers.sh
source "$HERE/_helpers.sh"
ENTRY="$HERE/../../entrypoint.sh"

# Real-time needs two things, and the entrypoint warns about each separately:
#   1. CAP_SYS_NICE (capability bit 23): Docker's default bounding set omits it
#   2. a PREEMPT_RT host kernel: containers share the host's
#
# CAPS_FULL has bit 23 set; CAPS_DOCKER_DEFAULT is what a stock `docker run`
# actually reports, and notably is non-zero, which is why "is the bitset zero"
# never fired.
CAPS_FULL=000001ffffffffff
CAPS_DOCKER_DEFAULT=00000000a80425fb

# Fixtures keep the outcome off the host: macOS has no /proc, and a Linux CI
# runner reports its own caps and kernel.
mk_status() {
  local d
  d=$(mktemp -d)
  printf 'Name:\tbash\nCapBnd:\t%s\nSeccomp:\t0\n' "$1" > "$d/status"
  echo "$d/status"
}

# A stub `uname` so the PREEMPT_RT fallback is deterministic.
mk_uname_stub() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" > "$d/bin/uname"
  chmod +x "$d/bin/uname"
  echo "$d/bin"
}

rt_yes() { local d; d=$(mktemp -d); echo 1 > "$d/realtime"; echo "$d/realtime"; }
rt_no()  { local d; d=$(mktemp -d); echo 0 > "$d/realtime"; echo "$d/realtime"; }

test_passthrough_runs_command() {
  local out caps rt
  caps=$(mk_status "$CAPS_FULL"); rt=$(rt_yes)
  out=$(BHF_CAPS_FILE="$caps" BHF_REALTIME_FILE="$rt" bash "$ENTRY" echo hello 2>/dev/null)
  rm -rf "$(dirname "$caps")" "$(dirname "$rt")"
  assert_equals "hello" "$out" "passthrough should exec the given command"
}

test_passthrough_preserves_exit_code() {
  local got caps rt
  caps=$(mk_status "$CAPS_FULL"); rt=$(rt_yes)
  set +e
  BHF_CAPS_FILE="$caps" BHF_REALTIME_FILE="$rt" bash "$ENTRY" sh -c 'exit 3' >/dev/null 2>&1
  got=$?
  set -e
  rm -rf "$(dirname "$caps")" "$(dirname "$rt")"
  assert_equals 3 "$got" "exit code of the exec'd command must survive"
}

test_warns_under_stock_docker_capabilities() {
  local err caps rt
  caps=$(mk_status "$CAPS_DOCKER_DEFAULT"); rt=$(rt_yes)
  err=$(BHF_CAPS_FILE="$caps" BHF_REALTIME_FILE="$rt" bash "$ENTRY" true 2>&1 >/dev/null)
  rm -rf "$(dirname "$caps")" "$(dirname "$rt")"
  assert_contains "$err" "CAP_SYS_NICE" "stock docker caps lack CAP_SYS_NICE and must warn"
}

test_warns_when_kernel_is_not_preempt_rt() {
  local err caps rt stub
  caps=$(mk_status "$CAPS_FULL"); rt=$(rt_no)
  stub=$(mk_uname_stub "#1 SMP Debian 6.1.0-18")
  err=$(PATH="$stub:$PATH" BHF_CAPS_FILE="$caps" BHF_REALTIME_FILE="$rt" \
        bash "$ENTRY" true 2>&1 >/dev/null)
  rm -rf "$(dirname "$caps")" "$(dirname "$rt")" "$(dirname "$stub")"
  assert_contains "$err" "PREEMPT_RT" "non-RT kernel must warn"
}

test_silent_when_rt_is_actually_available() {
  local err caps rt
  caps=$(mk_status "$CAPS_FULL"); rt=$(rt_yes)
  err=$(BHF_CAPS_FILE="$caps" BHF_REALTIME_FILE="$rt" bash "$ENTRY" true 2>&1 >/dev/null)
  rm -rf "$(dirname "$caps")" "$(dirname "$rt")"
  assert_equals "" "$err" "cap + RT kernel means no warning"
}

test_detects_rt_kernel_via_uname_fallback() {
  local err caps stub
  caps=$(mk_status "$CAPS_FULL")
  stub=$(mk_uname_stub "#1 SMP PREEMPT_RT Debian 6.1.0-18")
  err=$(PATH="$stub:$PATH" BHF_CAPS_FILE="$caps" BHF_REALTIME_FILE=/nonexistent/realtime \
        bash "$ENTRY" true 2>&1 >/dev/null)
  rm -rf "$(dirname "$caps")" "$(dirname "$stub")"
  assert_equals "" "$err" "PREEMPT_RT in uname -v counts when /sys/kernel/realtime is absent"
}

test_warns_when_caps_file_is_absent() {
  local err rt
  rt=$(rt_yes)
  err=$(BHF_CAPS_FILE=/nonexistent/status BHF_REALTIME_FILE="$rt" \
        bash "$ENTRY" true 2>&1 >/dev/null)
  rm -rf "$(dirname "$rt")"
  assert_contains "$err" "CAP_SYS_NICE" "unreadable caps file should warn, not crash"
}

test_quiet_suppresses_warning() {
  local err caps rt
  caps=$(mk_status "$CAPS_DOCKER_DEFAULT"); rt=$(rt_no)
  err=$(BHF_QUIET=1 BHF_CAPS_FILE="$caps" BHF_REALTIME_FILE="$rt" \
        bash "$ENTRY" true 2>&1 >/dev/null)
  rm -rf "$(dirname "$caps")" "$(dirname "$rt")"
  assert_equals "" "$err" "BHF_QUIET=1 must silence the warning"
}

test_no_args_starts_a_shell() {
  local got caps rt
  caps=$(mk_status "$CAPS_FULL"); rt=$(rt_yes)
  set +e
  BHF_CAPS_FILE="$caps" BHF_REALTIME_FILE="$rt" bash "$ENTRY" </dev/null >/dev/null 2>&1
  got=$?
  set -e
  rm -rf "$(dirname "$caps")" "$(dirname "$rt")"
  assert_equals 0 "$got" "no args should exec a shell, which exits 0 on EOF"
}

run_tests
