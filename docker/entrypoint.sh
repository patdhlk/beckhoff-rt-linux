#!/usr/bin/env bash
set -euo pipefail

# Real-time scheduling needs two things, and a container can miss either one:
#
#   1. CAP_SYS_NICE, capability bit 23. Docker's default bounding set omits it
#      (a stock `docker run` reports CapBnd 00000000a80425fb), so this is the
#      common failure and it is NOT detectable by asking "is the bitset zero";
#      the bitset is never zero under stock docker.
#   2. A PREEMPT_RT host kernel. Containers share the host's kernel, so no
#      amount of privilege inside the container substitutes for it.
#
# Both probes read overridable paths so they can be pointed at fixtures; the
# defaults are the only values that matter in the image. Quietable via
# BHF_QUIET=1.

has_sys_nice() {
  local caps_file caps
  caps_file="${BHF_CAPS_FILE:-/proc/self/status}"
  caps=$(awk -F: '/^CapBnd:/{gsub(/[[:space:]]/, "", $2); print $2}' "$caps_file" 2>/dev/null || true)
  [ -n "$caps" ] || return 1
  # CAP_SYS_NICE is bit 23 of the capability bounding set.
  (( ( 16#$caps >> 23 ) & 1 ))
}

has_rt_kernel() {
  local rt_file
  rt_file="${BHF_REALTIME_FILE:-/sys/kernel/realtime}"
  if [ -r "$rt_file" ] && [ "$(cat "$rt_file" 2>/dev/null || true)" = "1" ]; then
    return 0
  fi
  case "$(uname -v 2>/dev/null || true)" in
    *PREEMPT_RT*) return 0 ;;
    *)            return 1 ;;
  esac
}

warn_no_rt() {
  if [ "${BHF_QUIET:-0}" = "1" ]; then
    return
  fi
  local missing_cap=0 missing_kernel=0
  has_sys_nice   || missing_cap=1
  has_rt_kernel  || missing_kernel=1
  if [ "$missing_cap" = "0" ] && [ "$missing_kernel" = "0" ]; then
    return
  fi
  echo "[beckhoff-rt-linux] note: real-time scheduling is not available here." >&2
  if [ "$missing_cap" = "1" ]; then
    echo "[beckhoff-rt-linux] note:   missing CAP_SYS_NICE; rerun with --cap-add SYS_NICE (or --privileged)." >&2
  fi
  if [ "$missing_kernel" = "1" ]; then
    echo "[beckhoff-rt-linux] note:   host kernel is not PREEMPT_RT; containers share the host kernel." >&2
  fi
  echo "[beckhoff-rt-linux] note: silence this with BHF_QUIET=1." >&2
}

warn_no_rt

if [ $# -eq 0 ]; then
  exec bash
fi

case "$1" in
  --systemd)
    shift
    exec /lib/systemd/systemd "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
