#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=docker/scripts/test/_helpers.sh
source "$HERE/_helpers.sh"
RENDER="$HERE/../render-bhf-conf.sh"

test_renders_apt_auth_format() {
  local out
  out=$(BECKHOFF_EMAIL="a@b.c" BECKHOFF_PASSWORD="secret" bash "$RENDER")
  assert_contains "$out" "machine deb.beckhoff.com" "missing machine line"
  assert_contains "$out" "login a@b.c" "missing login line"
  assert_contains "$out" "password secret" "missing password line"
}

# Note: the target must NOT be an mktemp file: mktemp already creates 0600,
# which would make this pass regardless of what the renderer does. Fresh path
# under umask 022 means a naive redirect yields 0644.
test_out_file_is_mode_0600() {
  local d tmp perms
  d=$(mktemp -d)
  tmp="$d/bhf.conf"
  ( umask 022; BECKHOFF_EMAIL="a@b.c" BECKHOFF_PASSWORD="x" bash "$RENDER" --out "$tmp" )
  perms=$(stat -f '%Lp' "$tmp" 2>/dev/null || stat -c '%a' "$tmp")
  rm -rf "$d"
  assert_equals "600" "$perms" "rendered file must be mode 0600"
}

test_out_file_holds_credentials() {
  local tmp content
  tmp=$(mktemp)
  BECKHOFF_EMAIL="a@b.c" BECKHOFF_PASSWORD="secret" bash "$RENDER" --out "$tmp"
  content=$(cat "$tmp")
  rm -f "$tmp"
  assert_contains "$content" "machine deb.beckhoff.com" "missing machine line in file"
  assert_contains "$content" "login a@b.c" "missing login line in file"
  assert_contains "$content" "password secret" "missing password line in file"
}

test_fails_when_email_unset() {
  local got
  set +e
  env -u BECKHOFF_EMAIL BECKHOFF_PASSWORD=x bash "$RENDER" >/dev/null 2>&1
  got=$?
  set -e
  assert_equals 1 "$got" "missing email should exit 1"
}

test_fails_when_password_unset() {
  local got
  set +e
  env -u BECKHOFF_PASSWORD BECKHOFF_EMAIL=a@b.c bash "$RENDER" >/dev/null 2>&1
  got=$?
  set -e
  assert_equals 1 "$got" "missing password should exit 1"
}

test_rejects_unknown_arg() {
  local got
  set +e
  env BECKHOFF_EMAIL=a@b.c BECKHOFF_PASSWORD=x bash "$RENDER" --nope >/dev/null 2>&1
  got=$?
  set -e
  assert_equals 1 "$got" "unknown arg should exit 1"
}

run_tests
