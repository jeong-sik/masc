#!/usr/bin/env bash
# check-sandbox-dune-version.sh
#
# CI gate: verify that Dockerfile.keeper-sandbox is aligned with the repo
# build contract: dune is new enough and the image installs the pinned OCaml
# dependency closure used by keeper repo tasks.
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

# --- Extract installed dune version from Dockerfile.keeper-sandbox -----------
# Looks for an opam install line containing dune.X.Y.Z
sandbox_ver="$(grep -oE 'dune\.[0-9]+\.[0-9]+(\.[0-9]+)?' \
               "$repo_root/Dockerfile.keeper-sandbox" \
               | head -1 | sed 's/^dune\.//')"

if [[ -z "$sandbox_ver" ]]; then
  printf 'ERROR: could not extract dune version from Dockerfile.keeper-sandbox\n' >&2
  printf '  Expected an opam install line containing: dune.X.Y.Z\n' >&2
  exit 1
fi

printf 'dune-project requires  : %s\n' "$req_ver"
printf 'Dockerfile installs    : %s\n' "$sandbox_ver"

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

if grep -q 'scripts/opam-pin-external-deps.sh' "$repo_root/Dockerfile.keeper-sandbox" \
   && grep -q 'opam install . --deps-only -y' "$repo_root/Dockerfile.keeper-sandbox"; then
  printf 'OK: sandbox installs repo opam dependency closure\n'
else
  printf 'FAIL: Dockerfile.keeper-sandbox does not install pinned repo dependencies\n' >&2
  printf '  Fix: run scripts/opam-pin-external-deps.sh and opam install . --deps-only -y during image build\n' >&2
  exit 1
fi

if grep -q 'agent_sdk.llm_provider' "$repo_root/scripts/keeper-sandbox-smoke.sh"; then
  printf 'OK: sandbox smoke checks agent_sdk.llm_provider availability\n'
else
  printf 'FAIL: keeper-sandbox-smoke.sh must verify agent_sdk.llm_provider is available\n' >&2
  exit 1
fi
