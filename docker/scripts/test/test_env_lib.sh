#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=docker/scripts/test/_helpers.sh
source "$HERE/_helpers.sh"
# shellcheck source=docker/scripts/env-lib.sh
source "$HERE/../env-lib.sh"

# NOTE: heredocs here stay at statement level, never inside $( ). macOS ships
# bash 3.2, whose command-substitution parser mis-handles a ')' inside a
# nested heredoc.

test_reads_plain_value() {
  local d f got
  d=$(mktemp -d); f="$d/.env"
  cat > "$f" <<'EOF'
BECKHOFF_EMAIL=a@b.c
BECKHOFF_PASSWORD=simple
EOF
  got=$(env_file_get BECKHOFF_PASSWORD "$f")
  rm -rf "$d"
  assert_equals "simple" "$got" "plain value"
}

test_reads_value_with_shell_metacharacters() {
  local d f got
  d=$(mktemp -d); f="$d/.env"
  cat > "$f" <<'EOF'
BECKHOFF_PASSWORD=pa)ss(word&|;<>
EOF
  got=$(env_file_get BECKHOFF_PASSWORD "$f")
  rm -rf "$d"
  assert_equals 'pa)ss(word&|;<>' "$got" "metacharacters must survive verbatim"
}

test_does_not_execute_command_substitution() {
  local d f got pwned
  d=$(mktemp -d); f="$d/.env"
  # If the parser evaluates the value, this touches the marker file.
  # shellcheck disable=SC2016  # literal $(...) is the payload under test
  printf 'BECKHOFF_PASSWORD=$(touch %s/pwned)\n' "$d" > "$f"
  got=$(env_file_get BECKHOFF_PASSWORD "$f")
  pwned="no"; [ -e "$d/pwned" ] && pwned="yes"
  rm -rf "$d"
  assert_equals "no" "$pwned" "value must never be executed"
  # shellcheck disable=SC2016  # literal $(...) is the expected value
  assert_equals '$(touch '"$d"'/pwned)' "$got" "value returned verbatim"
}

test_does_not_execute_backticks() {
  local d f pwned
  d=$(mktemp -d); f="$d/.env"
  # shellcheck disable=SC2016  # literal backticks are the payload under test
  printf 'BECKHOFF_PASSWORD=`touch %s/pwned`\n' "$d" > "$f"
  env_file_get BECKHOFF_PASSWORD "$f" >/dev/null
  pwned="no"; [ -e "$d/pwned" ] && pwned="yes"
  rm -rf "$d"
  assert_equals "no" "$pwned" "backticks must never be executed"
}

test_strips_surrounding_quotes() {
  local d f got
  d=$(mktemp -d); f="$d/.env"
  cat > "$f" <<'EOF'
SINGLE='quoted value'
DOUBLE="other value"
EOF
  got=$(env_file_get SINGLE "$f")
  assert_equals "quoted value" "$got" "single quotes stripped"
  got=$(env_file_get DOUBLE "$f")
  rm -rf "$d"
  assert_equals "other value" "$got" "double quotes stripped"
}

test_ignores_comments_and_blanks() {
  local d f got
  d=$(mktemp -d); f="$d/.env"
  cat > "$f" <<'EOF'
# BECKHOFF_PASSWORD=commented-out

BECKHOFF_PASSWORD=real
EOF
  got=$(env_file_get BECKHOFF_PASSWORD "$f")
  rm -rf "$d"
  assert_equals "real" "$got" "commented line must not win"
}

test_returns_empty_for_missing_key() {
  local d f got
  d=$(mktemp -d); f="$d/.env"
  cat > "$f" <<'EOF'
BECKHOFF_EMAIL=a@b.c
EOF
  got=$(env_file_get BECKHOFF_PASSWORD "$f")
  rm -rf "$d"
  assert_equals "" "$got" "absent key yields empty string"
}

test_last_assignment_wins() {
  local d f got
  d=$(mktemp -d); f="$d/.env"
  cat > "$f" <<'EOF'
BECKHOFF_PASSWORD=first
BECKHOFF_PASSWORD=second
EOF
  got=$(env_file_get BECKHOFF_PASSWORD "$f")
  rm -rf "$d"
  assert_equals "second" "$got" "later assignment overrides, as sourcing would"
}

test_handles_missing_trailing_newline() {
  local d f got
  d=$(mktemp -d); f="$d/.env"
  printf 'BECKHOFF_PASSWORD=no-newline' > "$f"
  got=$(env_file_get BECKHOFF_PASSWORD "$f")
  rm -rf "$d"
  assert_equals "no-newline" "$got" "final line without newline must be read"
}

run_tests
