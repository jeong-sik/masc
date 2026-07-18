#!/usr/bin/env bash
# Exact runtime-artifact identity contract shared by start-masc.sh and the
# process supervisor.  This file is both sourceable and directly executable.

MASC_RUNTIME_ARTIFACT_SCHEMA="masc.runtime_artifact.v1"

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

masc_runtime_artifact_valid_port () {
  local value="${1:-}"
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$value" -ge 1 ] && [ "$value" -le 65535 ]
}

masc_runtime_artifact_descriptor_write () {
  local file="${1:-}"
  local mode="${2:-}"
  local path="${3:-}"
  local sha256="${4:-}"
  local port="${5:-}"
  local parent temp

  [ -n "$file" ] || return 2
  [ "$mode" = "http" ] || return 2
  case "$path" in
    /*) ;;
    *) return 2 ;;
  esac
  case "$path" in
    *$'\n'*|*$'\r'*) return 2 ;;
  esac
  masc_runtime_artifact_valid_hash "$sha256" || return 2
  masc_runtime_artifact_valid_port "$port" || return 2

  parent="$(dirname "$file")"
  mkdir -p "$parent" || return 1
  temp="$file.tmp.$$"
  umask 077
  if ! printf '%s\n%s\n%s\n%s\n%s\n' \
      "$MASC_RUNTIME_ARTIFACT_SCHEMA" "$mode" "$path" "$sha256" "$port" \
      >"$temp"
  then
    rm -f "$temp"
    return 1
  fi
  chmod 600 "$temp" || {
    rm -f "$temp"
    return 1
  }
  mv -f "$temp" "$file"
}

masc_runtime_artifact_descriptor_read () {
  local file="${1:-}"
  local schema mode path sha256 port

  [ -f "$file" ] || return 1
  {
    IFS= read -r schema || return 1
    IFS= read -r mode || return 1
    IFS= read -r path || return 1
    IFS= read -r sha256 || return 1
    IFS= read -r port || return 1
    if IFS= read -r _; then
      return 1
    fi
  } <"$file"

  [ "$schema" = "$MASC_RUNTIME_ARTIFACT_SCHEMA" ] || return 1
  [ "$mode" = "http" ] || return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  masc_runtime_artifact_valid_hash "$sha256" || return 1
  masc_runtime_artifact_valid_port "$port" || return 1

  MASC_ARTIFACT_MODE="$mode"
  MASC_ARTIFACT_PATH="$path"
  MASC_ARTIFACT_SHA256="$sha256"
  MASC_ARTIFACT_PORT="$port"
  export MASC_ARTIFACT_MODE MASC_ARTIFACT_PATH MASC_ARTIFACT_SHA256 MASC_ARTIFACT_PORT
}

masc_runtime_artifact_descriptor_verify () {
  local file="${1:-}"
  local actual

  masc_runtime_artifact_descriptor_read "$file" || return 1
  [ -f "$MASC_ARTIFACT_PATH" ] || return 1
  [ -x "$MASC_ARTIFACT_PATH" ] || return 1
  actual="$(masc_runtime_artifact_hash "$MASC_ARTIFACT_PATH")" || return 1
  [ "$actual" = "$MASC_ARTIFACT_SHA256" ]
}

masc_runtime_artifact_promote () {
  local candidate_file="${1:-}"
  local lkg_file="${2:-}"
  local repo_root="${3:-}"
  local source_path source_hash mode port promoted_path promoted_dir temp actual

  masc_runtime_artifact_descriptor_verify "$candidate_file" || return 1
  source_path="$MASC_ARTIFACT_PATH"
  source_hash="$MASC_ARTIFACT_SHA256"
  mode="$MASC_ARTIFACT_MODE"
  port="$MASC_ARTIFACT_PORT"
  promoted_path="$source_path"

  # Local Dune outputs are mutable.  Preserve the exact healthy bytes beside
  # the selected executable so Sys.executable_name keeps the same repo/layout
  # ancestry on fallback.  Release and installed artifacts remain at their
  # already-stable path and are still protected by the descriptor hash.
  case "$source_path" in
    "$repo_root"/_build/*)
      promoted_dir="$(dirname "$source_path")"
      promoted_path="$promoted_dir/.masc-lkg-$source_hash-$(basename "$source_path")"
      if [ ! -f "$promoted_path" ]; then
        temp="$promoted_path.tmp.$$"
        cp -p "$source_path" "$temp" || {
          rm -f "$temp"
          return 1
        }
        chmod 700 "$temp" || {
          rm -f "$temp"
          return 1
        }
        actual="$(masc_runtime_artifact_hash "$temp")" || {
          rm -f "$temp"
          return 1
        }
        if [ "$actual" != "$source_hash" ]; then
          rm -f "$temp"
          return 1
        fi
        mv -f "$temp" "$promoted_path" || {
          rm -f "$temp"
          return 1
        }
      fi
      actual="$(masc_runtime_artifact_hash "$promoted_path")" || return 1
      [ "$actual" = "$source_hash" ] || return 1
      ;;
  esac

  masc_runtime_artifact_descriptor_write "$lkg_file" "$mode" \
    "$promoted_path" "$source_hash" "$port"
}

masc_runtime_artifact_cli () {
  local command="${1:-}"
  shift || true
  case "$command" in
    hash)
      [ "$#" -eq 1 ] || return 2
      masc_runtime_artifact_hash "$1"
      ;;
    write)
      [ "$#" -eq 5 ] || return 2
      masc_runtime_artifact_descriptor_write "$1" "$2" "$3" "$4" "$5"
      ;;
    verify)
      [ "$#" -eq 1 ] || return 2
      masc_runtime_artifact_descriptor_verify "$1"
      ;;
    promote)
      [ "$#" -eq 3 ] || return 2
      masc_runtime_artifact_promote "$1" "$2" "$3"
      ;;
    *)
      printf 'usage: %s {hash FILE|write FILE MODE PATH SHA256 PORT|verify FILE|promote CANDIDATE LKG REPO_ROOT}\n' \
        "$0" >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  masc_runtime_artifact_cli "$@"
fi
