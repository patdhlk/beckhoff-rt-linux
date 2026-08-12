#!/usr/bin/env bash
# Render Beckhoff apt-auth.conf content from env vars.
# Output: stdout by default, or to --out <path> with mode 0600.
set -euo pipefail

err() { echo "render-bhf-conf: $*" >&2; exit 1; }

OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    *)     err "unknown arg: $1" ;;
  esac
done

[ -n "${BECKHOFF_EMAIL:-}" ]    || err "BECKHOFF_EMAIL not set"
[ -n "${BECKHOFF_PASSWORD:-}" ] || err "BECKHOFF_PASSWORD not set"

content="machine deb.beckhoff.com
login ${BECKHOFF_EMAIL}
password ${BECKHOFF_PASSWORD}
"

if [ -n "$OUT" ]; then
  # Create (or truncate) the target and lock its mode down BEFORE the
  # credentials are written, so they never land in a world-readable file.
  ( umask 077; : > "$OUT" )
  chmod 600 "$OUT"
  printf '%s' "$content" > "$OUT"
else
  printf '%s' "$content"
fi
