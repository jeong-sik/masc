#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
mode="check"
previous_baseline=""
previous_pure_modules=""

cleanup() {
  if [[ -n "${previous_baseline}" ]]; then
    rm -f -- "${previous_baseline}"
  fi
  if [[ -n "${previous_pure_modules}" ]]; then
    rm -f -- "${previous_pure_modules}"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: scripts/ocaml-boundary-ratchet.sh [--regenerate|--json]

  no argument    verify the typed mechanical baseline and pure-module contract
  --regenerate   write an initial or strictly smaller baseline
  --json         print the current typed-tree site report as JSON

The production .cmt graph must already exist. CI runs this after @check; local
callers should build the relevant full graph only when they intentionally run
the repository-wide audit.
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
  --root "${repo_root}"
  --build-dir "${repo_root}/_build/default"
  --pure-modules scripts/ocaml-pure-modules.txt
  --baseline scripts/ocaml-boundary-baseline.tsv
)

case "${mode}" in
  check) args+=(--check) ;;
  write) args+=(--write-baseline) ;;
  json) args+=(--format json) ;;
esac

if [[ "${mode}" != "json" ]]; then
  base_ref="${OCAML_BOUNDARY_BASE_REF:-origin/main}"
  if [[ -n "${base_ref}" ]]; then
    if ! git cat-file -e "${base_ref}^{commit}" 2>/dev/null; then
      echo "ocaml-boundary-ratchet: base revision is unavailable: ${base_ref}" >&2
      exit 1
    fi
    if git cat-file -e "${base_ref}:scripts/ocaml-boundary-baseline.tsv" 2>/dev/null; then
      previous_baseline="$(mktemp "${TMPDIR:-/tmp}/ocaml-boundary-baseline.XXXXXX")"
      git show "${base_ref}:scripts/ocaml-boundary-baseline.tsv" > "${previous_baseline}"
      args+=(--previous-baseline "${previous_baseline}")
    fi
    if git cat-file -e "${base_ref}:scripts/ocaml-pure-modules.txt" 2>/dev/null; then
      previous_pure_modules="$(mktemp "${TMPDIR:-/tmp}/ocaml-pure-modules.XXXXXX")"
      git show "${base_ref}:scripts/ocaml-pure-modules.txt" > "${previous_pure_modules}"
      args+=(--previous-pure-modules "${previous_pure_modules}")
    fi
  fi
fi

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  opam exec -- dune exec --root "${repo_root}" \
    tools/ocaml_boundary_audit/main.exe -- "${args[@]}"
else
  "${repo_root}/scripts/dune-local.sh" \
    exec --root "${repo_root}" \
    tools/ocaml_boundary_audit/main.exe -- "${args[@]}"
fi
