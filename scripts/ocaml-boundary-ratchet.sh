#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
mode="check"
previous_baseline=""

cleanup() {
  if [[ -n "$previous_baseline" ]]; then
    rm -f -- "$previous_baseline"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: scripts/ocaml-boundary-ratchet.sh [--regenerate|--json]

  no argument    verify the exact semantic baseline
  --regenerate   write an initial or strictly smaller baseline
  --json         print the current site report as JSON
USAGE
}

if [[ "$#" -gt 1 ]]; then
  usage >&2
  exit 2
fi

case "${1:-}" in
  "") ;;
  --regenerate) mode="write" ;;
  --json) mode="json" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

args=(
  --root "$repo_root"
  --pure-modules scripts/ocaml-pure-modules.txt
  --baseline scripts/ocaml-boundary-baseline.tsv
)

case "$mode" in
  check) args+=(--check) ;;
  write) args+=(--write-baseline) ;;
  json) args+=(--format json) ;;
esac

if [[ "$mode" != "json" ]]; then
  base_ref="${OCAML_BOUNDARY_BASE_REF:-origin/main}"
  if ! git cat-file -e "${base_ref}^{commit}" 2>/dev/null; then
    echo "ocaml-boundary-ratchet: base revision is unavailable: $base_ref" >&2
    exit 1
  fi
  if git cat-file -e "${base_ref}:scripts/ocaml-boundary-baseline.tsv" 2>/dev/null; then
    previous_baseline="$(mktemp "${TMPDIR:-/tmp}/ocaml-boundary-baseline.XXXXXX")"
    git show "${base_ref}:scripts/ocaml-boundary-baseline.tsv" > "$previous_baseline"
    args+=(--previous-baseline "$previous_baseline")
  fi
fi

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  opam exec -- dune exec --root "$repo_root" \
    tools/ocaml_boundary_audit/main.exe -- "${args[@]}"
else
  "$repo_root/scripts/dune-local.sh" \
    exec --root "$repo_root" \
    tools/ocaml_boundary_audit/main.exe -- "${args[@]}"
fi
