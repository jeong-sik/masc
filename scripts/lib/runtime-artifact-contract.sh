#!/usr/bin/env bash
# Runtime-artifact hashing sourced by scripts/run-local.sh.

masc_runtime_artifact_hash () {
  local path="${1:-}"
  [ -f "$path" ] || return 1

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{ print $1 }'
  else
    printf 'no SHA-256 implementation found (requires shasum or sha256sum)\n' >&2
    return 127
  fi
}

masc_runtime_artifact_valid_hash () {
  local value="${1:-}"
  [ "${#value}" -eq 64 ] || return 1
  case "$value" in
    *[!0-9a-f]*) return 1 ;;
    *) return 0 ;;
  esac
}
