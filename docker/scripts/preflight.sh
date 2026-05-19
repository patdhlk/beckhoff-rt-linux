#!/usr/bin/env bash
set -euo pipefail

err() { echo "preflight: $*" >&2; exit 1; }

# Docker present?
command -v docker >/dev/null 2>&1 || err "docker not found in PATH"

# BuildKit available? Either DOCKER_BUILDKIT=1 or buildx.
if [ "${DOCKER_BUILDKIT:-}" != "1" ] && ! docker buildx version >/dev/null 2>&1; then
  err "BuildKit required. Export DOCKER_BUILDKIT=1 or install 'docker buildx'."
fi

# .env present?
[ -f .env ] || err ".env not found. Copy .env.example to .env and fill in your Beckhoff credentials."

# Required vars set and non-empty. Sourced in a subshell so values do not leak.
(
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  [ -n "${BECKHOFF_EMAIL:-}" ]    || exit 1
  [ -n "${BECKHOFF_PASSWORD:-}" ] || exit 1
) || err "BECKHOFF_EMAIL or BECKHOFF_PASSWORD is empty in .env"

echo "preflight: OK"
