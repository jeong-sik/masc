#!/usr/bin/env bash
# Shared release-version extraction helpers.

release_extract_dune_project_version() {
  local file="${1:-dune-project}"
  sed -nE 's/^[[:space:]]*\(version[[:space:]]+([^[:space:])]+).*/\1/p' "$file" | head -n 1
}

release_extract_sdk_version() {
  local file="${1:-lib/sdk_version.ml}"
  sed -nE 's/^[[:space:]]*let[[:space:]]+version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$file" | head -n 1
}

release_extract_opam_version() {
  local file="${1:-agent_sdk.opam}"
  sed -nE 's/^[[:space:]]*version:[[:space:]]*"([^"]+)".*/\1/p' "$file" | head -n 1
}

release_is_supported_version() {
  local version="${1:-}"
  [[ "$version" =~ ^[0-9]+[.][0-9]+([.][0-9]+)?([-+][0-9A-Za-z][0-9A-Za-z._+-]*)?$ ]]
}
