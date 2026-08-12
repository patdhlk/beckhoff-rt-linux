#!/usr/bin/env bash
# Read values out of a .env-style file WITHOUT sourcing it.
#
# Sourcing (`. ./.env`) executes the file. A credential containing `$(...)`
# or backticks would then run as a command, and one containing `()` fails to
# parse at all. Beckhoff passwords are user-chosen, so both are live risks.
#
# Usage: value=$(env_file_get KEY /path/to/.env)
# Absent key yields an empty string. Later assignments win, as sourcing would.

env_file_get() {
  local key="$1" file="$2" line value=""

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key"=*) value="${line#"$key"=}" ;;
      *)        continue ;;
    esac
  done < "$file"

  # Strip one layer of surrounding quotes, if present.
  case "$value" in
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
  esac

  printf '%s' "$value"
}
