#!/usr/bin/env bash
# check-sandbox-ocaml-version.sh
#
# CI gate: verify that the OCaml compiler Dockerfile.keeper-sandbox installs is
# the one masc.opam requires.
#
# Rationale: the image starts from `ocaml/opam:ubuntu-24.04-ocaml-5.5`, whose
# switch carries ocaml-base-compiler 5.5.0 and pins the package to it. #34143
# moved masc.opam to `ocaml = 5.5.1` and nothing in the image followed, so
# `opam install --deps-only` stopped solving and the image became unbuildable.
# No workflow builds it, so the break surfaced a day later, by hand.
#
# This is the second drift of its kind: check-sandbox-dune-version.sh exists
# because the same gap opened for dune. Both read the image's version out of
# the Dockerfile and compare it with what the repo asks for, at PR time rather
# than at keeper task-execution time.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="$repo_root/Dockerfile.keeper-sandbox"

# --- What masc.opam requires: "ocaml" {= "X.Y.Z"} ----------------------------
req_ver="$(grep -oE '"ocaml" \{= "[0-9]+\.[0-9]+\.[0-9]+"\}' "$repo_root/masc.opam" \
           | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"

if [[ -z "$req_ver" ]]; then
  printf 'ERROR: masc.opam does not pin ocaml to an exact version\n' >&2
  printf '  Looked for: `"ocaml" {= "X.Y.Z"}` in masc.opam\n' >&2
  exit 1
fi

# --- What the image installs: an explicit ocaml-base-compiler.X.Y.Z line -----
# `|| true` is required: a no-match grep exits 1 under `set -e`, which would
# kill the script before it could print the diagnostic below.
img_ver="$(grep -oE 'ocaml-base-compiler\.[0-9]+\.[0-9]+\.[0-9]+' "$dockerfile" \
           | head -1 | sed 's/^ocaml-base-compiler\.//' || true)"

if [[ -z "$img_ver" ]]; then
  from_tag="$(grep -oE '^FROM ocaml/opam:[^ ]+' "$dockerfile" | head -1 || true)"
  printf 'FAIL: masc.opam requires ocaml %s and the sandbox image installs no exact compiler\n' \
         "$req_ver" >&2
  printf '  Base image: %s\n' "${from_tag:-<no ocaml/opam FROM line>}" >&2
  printf '  A base tag names a minor version, so it cannot satisfy an exact pin\n' >&2
  printf '  on its own. Fix: install ocaml-base-compiler.%s in Dockerfile.keeper-sandbox.\n' \
         "$req_ver" >&2
  exit 1
fi

printf 'masc.opam requires     : ocaml %s\n' "$req_ver"
printf 'sandbox image installs : ocaml-base-compiler %s\n' "$img_ver"

# An exact pin admits one answer, so this compares for equality rather than
# ordering: an image ahead of the pin fails to solve exactly as one behind it does.
if [[ "$img_ver" == "$req_ver" ]]; then
  printf 'OK: sandbox compiler %s matches the masc.opam pin\n' "$img_ver"
else
  printf 'FAIL: sandbox compiler %s does not match the masc.opam pin %s\n' \
         "$img_ver" "$req_ver" >&2
  printf '  Fix: update Dockerfile.keeper-sandbox to install ocaml-base-compiler.%s\n' \
         "$req_ver" >&2
  exit 1
fi
