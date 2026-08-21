#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

# No \b anchors. '_' counts as a word character, so '\bvelvet-hammer\b' does not
# see the name inside an OCaml identifier such as
# [test_velvet_hammer_cannot_post_as_delta], which is how one survived the
# first sweep. Separators are a character class so both spellings are one
# pattern instead of two alternatives that can drift apart.
retired_names='(taskmaster|sangsu|rondo|kidsnote|analyst|code[-_]reviewer|lane[-_]smith|polisher|nick0cave|scholar|issue[-_]king|adversary|qa[-_]king|ramarama|velvet[-_]hammer|masc[-_]improver|tech[-_]glutton|imseonghan|sojin|jobsian[-_]purist)'
identity_role_names='keeper-(verifier|executor)-agent|keeper_name[[:space:]]*=[[:space:]]*"(verifier|executor)"|~keeper_name:"(verifier|executor)"'

status=0
if rg -n -i --glob '*.ml' --glob '*.mli' \
  "${retired_names}" lib test packages bin; then
  status=1
fi

if rg -n --glob '*.ml' --glob '*.mli' \
  "${identity_role_names}" lib test packages bin; then
  status=1
fi

if [[ "${status}" -ne 0 ]]; then
  echo "no-concrete-keeper-names-in-ocaml: concrete Keeper identity found" >&2
  exit "${status}"
fi

echo "no-concrete-keeper-names-in-ocaml: clean"
