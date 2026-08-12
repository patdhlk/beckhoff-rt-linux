#!/usr/bin/env bash
set -euo pipefail

# Warn once on startup if real-time scheduling capability looks unavailable.
# Heuristic: an empty or all-zero capability bitset suggests we are NOT running
# privileged on an RT-capable host. Quietable via BHF_QUIET=1.
#
# BHF_CAPS_FILE exists so the check can be pointed at a fixture; the default is
# the only path that matters in the image.
warn_no_rt() {
  if [ "${BHF_QUIET:-0}" = "1" ]; then
    return
  fi
  local caps_file caps
  caps_file="${BHF_CAPS_FILE:-/proc/self/status}"
  caps=$(awk -F: '/^CapBnd:/{gsub(/[[:space:]]/, "", $2); print $2}' "$caps_file" 2>/dev/null || true)
  if [ -z "$caps" ] || [ "$caps" = "0000000000000000" ]; then
    echo "[beckhoff-rt-linux] note: real-time scheduling not available in this container." >&2
    echo "[beckhoff-rt-linux] note: containers share the host kernel; RT requires a PREEMPT_RT host." >&2
  fi
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
