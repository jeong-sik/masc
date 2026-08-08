#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/release-version-lib.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL ${label}: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

assert_valid() {
  local label="$1"
  local actual="$2"

  if ! release_is_supported_version "$actual"; then
    echo "FAIL ${label}: invalid version ${actual}" >&2
    exit 1
  fi
}

write_fixture() {
  local path="$1"
  local content="$2"
  printf '%s\n' "$content" > "$path"
}

write_fixture "$tmpdir/dune-marker" '(version 0.196.10) ; x-release-please-version'
write_fixture "$tmpdir/dune-plain" '(version 0.196.10)'
write_fixture "$tmpdir/sdk-marker" 'let version = "0.196.10" (* x-release-please-version *)'
write_fixture "$tmpdir/sdk-plain" 'let version = "0.196.10"'
write_fixture "$tmpdir/opam-marker" 'version: "0.196.10" # x-release-please-version'
write_fixture "$tmpdir/opam-plain" 'version: "0.196.10"'

assert_eq "dune marker" "0.196.10" "$(release_extract_dune_project_version "$tmpdir/dune-marker")"
assert_eq "dune plain" "0.196.10" "$(release_extract_dune_project_version "$tmpdir/dune-plain")"
assert_eq "sdk marker" "0.196.10" "$(release_extract_sdk_version "$tmpdir/sdk-marker")"
assert_eq "sdk plain" "0.196.10" "$(release_extract_sdk_version "$tmpdir/sdk-plain")"
assert_eq "opam marker" "0.196.10" "$(release_extract_opam_version "$tmpdir/opam-marker")"
assert_eq "opam plain" "0.196.10" "$(release_extract_opam_version "$tmpdir/opam-plain")"

current_dune="$(release_extract_dune_project_version "${repo_root}/dune-project")"
current_sdk="$(release_extract_sdk_version "${repo_root}/lib/sdk_version.ml")"
current_opam="$(release_extract_opam_version "${repo_root}/agent_sdk.opam")"

assert_eq "current dune/sdk" "$current_dune" "$current_sdk"
assert_eq "current dune/opam" "$current_dune" "$current_opam"
assert_valid "current dune" "$current_dune"
assert_valid "current sdk" "$current_sdk"
assert_valid "current opam" "$current_opam"

case "$current_dune $current_sdk $current_opam" in
  *x-release-please-version*)
    echo "FAIL current extraction leaked release-please marker" >&2
    exit 1
    ;;
esac

echo "release version extraction fixtures passed for ${current_dune}"
