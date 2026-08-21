#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

retired_names='\b(taskmaster|sangsu|rondo|kidsnote|analyst|code-reviewer|lane-smith|polisher|nick0cave|scholar|issue_king|issue-king|adversary|qa-king|ramarama|velvet-hammer|masc-improver|tech_glutton|tech-glutton|imseonghan|sojin|jobsian_purist)\b'
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
