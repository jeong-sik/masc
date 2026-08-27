#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "source binary identity requires a Git checkout" >&2
  exit 1
}

# One scope shared by the build-time stamp and the local launcher.  These are
# the inputs that can change the server executable; unrelated evidence/docs do
# not make an otherwise exact binary stale.
source_scope=(
  bin
  lib
  packages
  proto
  config/prompts
  dune-project
  dune-workspace
  scripts/source-binary-identity.sh
)

fingerprint() {
  (
    cd "$repo_root"
    git rev-parse 'HEAD^{tree}'
    git diff --binary HEAD -- "${source_scope[@]}"
    while IFS= read -r -d '' path; do
      blob="$(git hash-object -- "$path")"
      printf '%s\0%s\0' "$path" "$blob"
    done < <(git ls-files --others --exclude-standard -z -- "${source_scope[@]}")
  ) | git hash-object --stdin
}

state() {
  if git -C "$repo_root" status --porcelain=v1 --untracked-files=all -- \
      "${source_scope[@]}" | grep -q .; then
    printf 'dirty\n'
  else
    printf 'clean\n'
  fi
}

case "${1:-fingerprint}" in
  fingerprint) fingerprint ;;
  state) state ;;
  *)
    echo "usage: scripts/source-binary-identity.sh [fingerprint|state]" >&2
    exit 2
    ;;
esac
