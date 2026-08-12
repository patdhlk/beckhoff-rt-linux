#!/usr/bin/env bash
set -euo pipefail

# Resolved with parameter expansion, not `dirname`: this script must still
# reach its own directory when PATH is broken (one of the cases below).
case "$0" in
  */*) HERE="${0%/*}" ;;
  *)   HERE="." ;;
esac
# shellcheck source=docker/scripts/env-lib.sh
. "$HERE/env-lib.sh"

err() { echo "preflight: $*" >&2; exit 1; }

# Docker present?
command -v docker >/dev/null 2>&1 || err "docker not found in PATH"

# BuildKit available? Either DOCKER_BUILDKIT=1 or buildx.
if [ "${DOCKER_BUILDKIT:-}" != "1" ] && ! docker buildx version >/dev/null 2>&1; then
  err "BuildKit required. Export DOCKER_BUILDKIT=1 or install 'docker buildx'."
fi

# .env present?
[ -f .env ] || err ".env not found. Copy .env.example to .env and fill in your Beckhoff credentials."

# Required vars set and non-empty. Parsed, never sourced: a password holding
# $(...) or backticks would otherwise execute, and one holding () would break
# the parse outright.
[ -n "$(env_file_get BECKHOFF_EMAIL ./.env)" ] \
  || err "BECKHOFF_EMAIL is empty in .env"
[ -n "$(env_file_get BECKHOFF_PASSWORD ./.env)" ] \
  || err "BECKHOFF_PASSWORD is empty in .env"

echo "preflight: OK"
