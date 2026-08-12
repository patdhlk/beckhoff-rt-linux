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

test_passes_with_metacharacter_password() {
  local d got
  d=$(mk_sandbox)
  cat > "$d/.env" <<'EOF'
BECKHOFF_EMAIL=a@b.c
BECKHOFF_PASSWORD=pa)ss(word&|;<>
EOF
  set +e
  ( cd "$d" && PATH="$d/bin:/usr/bin:/bin" bash "$PREFLIGHT" ) >/dev/null 2>&1
  got=$?
  set -e
  rm -rf "$d"
  assert_equals 0 "$got" "password with shell metacharacters should still pass"
}

test_does_not_execute_env_file() {
  local d pwned
  d=$(mk_sandbox)
  # shellcheck disable=SC2016  # literal $(...) is the payload under test
  printf 'BECKHOFF_EMAIL=a@b.c\nBECKHOFF_PASSWORD=$(touch %s/pwned)\n' "$d" > "$d/.env"
  set +e
  ( cd "$d" && PATH="$d/bin:/usr/bin:/bin" bash "$PREFLIGHT" ) >/dev/null 2>&1
  set -e
  pwned="no"; [ -e "$d/pwned" ] && pwned="yes"
  rm -rf "$d"
  assert_equals "no" "$pwned" ".env must be parsed, never executed"
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
