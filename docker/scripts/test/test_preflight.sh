#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=docker/scripts/test/_helpers.sh
source "$HERE/_helpers.sh"
PREFLIGHT="$HERE/../preflight.sh"

# Make a temp dir with a stub `docker` in PATH so the docker check passes.
mk_sandbox() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat > "$d/bin/docker" <<'EOF'
#!/bin/sh
case "$*" in
  "buildx version") exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$d/bin/docker"
  echo "$d"
}

test_passes_with_complete_env() {
  local d; d=$(mk_sandbox)
  cat > "$d/.env" <<EOF
BECKHOFF_EMAIL=a@b.c
BECKHOFF_PASSWORD=x
EOF
  set +e
  ( cd "$d" && PATH="$d/bin:/usr/bin:/bin" bash "$PREFLIGHT" ) >/dev/null 2>&1
  local got=$?
  set -e
  rm -rf "$d"
  assert_equals 0 "$got" "complete env should exit 0"
}

test_fails_when_env_missing() {
  local d; d=$(mk_sandbox)
  set +e
  ( cd "$d" && PATH="$d/bin:/usr/bin:/bin" bash "$PREFLIGHT" ) >/dev/null 2>&1
  local got=$?
  set -e
  rm -rf "$d"
  assert_equals 1 "$got" "missing .env should exit 1"
}

test_fails_when_email_empty() {
  local d; d=$(mk_sandbox)
  cat > "$d/.env" <<EOF
BECKHOFF_EMAIL=
BECKHOFF_PASSWORD=x
EOF
  set +e
  ( cd "$d" && PATH="$d/bin:/usr/bin:/bin" bash "$PREFLIGHT" ) >/dev/null 2>&1
  local got=$?
  set -e
  rm -rf "$d"
  assert_equals 1 "$got" "empty email should exit 1"
}

test_fails_when_docker_missing() {
  local d; d=$(mktemp -d)  # NO stub docker
  cat > "$d/.env" <<EOF
BECKHOFF_EMAIL=a@b.c
BECKHOFF_PASSWORD=x
EOF
  set +e
  ( cd "$d" && PATH="/nonexistent" /bin/bash "$PREFLIGHT" ) >/dev/null 2>&1
  local got=$?
  set -e
  rm -rf "$d"
  assert_equals 1 "$got" "missing docker should exit 1"
}

run_tests
