#!/usr/bin/env bash
# check-sandbox-dune-version.sh
#
# CI gate: verify that the dune version installed in Dockerfile.keeper-sandbox
# meets or exceeds the (lang dune X.Y) requirement in dune-project.
#
# Rationale: Ubuntu 24.04's ocaml-dune apt package provides dune 3.14 while
# the repo dune-project requires (lang dune 3.22).  This script is wired into
# CI (meta job) so any future drift is caught at PR time rather than at keeper
# task-execution time.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Extract required dune version from dune-project: (lang dune X.Y) --------
req_ver="$(grep -E '^\(lang dune\b' "$repo_root/dune-project" \
           | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"

if [[ -z "$req_ver" ]]; then
  printf 'ERROR: could not extract dune version from dune-project\n' >&2
  exit 1
fi

# --- Extract installed dune version -----------------------------------------
# Two ways the image can end up with dune, checked in that order:
#
#   1. an explicit `opam install dune.X.Y.Z` line in the Dockerfile
#   2. `opam install --deps-only` against masc.opam, which resolves dune from
#      masc.opam.locked — the Dockerfile copies that lock in and installs from
#      it, so the lock's pin is the version the image gets
#
# `|| true` is required: these greps run under `set -euo pipefail`, and a
# no-match grep exits 1, which would kill the script before it could print
# the diagnostic below.
sandbox_ver="$(grep -oE 'dune\.[0-9]+\.[0-9]+(\.[0-9]+)?' \
               "$repo_root/Dockerfile.keeper-sandbox" 2>/dev/null \
               | head -1 | sed 's/^dune\.//' || true)"
sandbox_source="Dockerfile.keeper-sandbox (explicit install)"

if [[ -z "$sandbox_ver" ]] \
   && grep -qE '^[[:space:]]*(RUN|&&)?[^#]*--deps-only' \
        "$repo_root/Dockerfile.keeper-sandbox"; then
  sandbox_ver="$(grep -oE '"dune" \{= "[0-9]+\.[0-9]+(\.[0-9]+)?"\}' \
                 "$repo_root/masc.opam.locked" 2>/dev/null \
                 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)"
  sandbox_source="masc.opam.locked (via --deps-only)"
fi

if [[ -z "$sandbox_ver" ]]; then
  printf 'ERROR: could not determine the dune version the sandbox image installs\n' >&2
  printf '  Looked for: an `opam install dune.X.Y.Z` line in Dockerfile.keeper-sandbox,\n' >&2
  printf '  then, if it installs with --deps-only, `"dune" {= "X.Y.Z"}` in masc.opam.locked\n' >&2
  exit 1
fi

printf 'dune-project requires  : %s\n' "$req_ver"
printf 'sandbox image installs : %s  (from %s)\n' "$sandbox_ver" "$sandbox_source"

# --- Version comparison: sandbox_ver >= req_ver (using sort -V) ---------------
# printf puts req_ver first; sort -V -C returns 0 only when the two lines are
# already in non-decreasing order, i.e. req_ver <= sandbox_ver.
if printf '%s\n%s\n' "$req_ver" "$sandbox_ver" | sort -V -C; then
  printf 'OK: sandbox dune %s >= dune-project required %s\n' "$sandbox_ver" "$req_ver"
else
  printf 'FAIL: sandbox dune %s < dune-project required %s\n' \
         "$sandbox_ver" "$req_ver" >&2
  printf '  Fix: update Dockerfile.keeper-sandbox to install dune >= %s\n' \
         "$req_ver" >&2
  exit 1
fi
