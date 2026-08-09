#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_root="${AGENT_CORE_ROOT:-${repo_root}/packages/agent_core}"

fail() {
  echo "agent-core boundary: $*" >&2
  exit 1
}

[[ -d "${core_root}/lib" ]] || fail "missing required source tree: ${core_root}/lib"
[[ -f "${core_root}/lib/dune" ]] || fail "missing required root library stanza"
[[ -f "${core_root}/test/dune" ]] || fail "missing required behavior suite"
[[ -f "${core_root}/models.toml" ]] || fail "missing required model catalog"

for forbidden in dune-project agent_core.opam .github release-please-config.json; do
  [[ ! -e "${core_root}/${forbidden}" ]] \
    || fail "independent package surface is forbidden: ${core_root}/${forbidden}"
done

dune_violations="$({
  find "${core_root}" -name dune -type f -print0 \
    | xargs -0 rg -n 'masc\.' \
    | rg -v '\(public_name masc\.agent_core(\.[a-z_]+)?\)' \
    || true
})"
[[ -z "${dune_violations}" ]] || {
  printf '%s\n' "${dune_violations}" >&2
  fail "agent core must not depend on MASC coordinator libraries"
}

module_violations="$({
  rg -n \
    '\b(Masc_[A-Za-z0-9_]*|Keeper_[A-Za-z0-9_]*|Board_[A-Za-z0-9_]*|Gate_[A-Za-z0-9_]*|Server_[A-Za-z0-9_]*|Operator_[A-Za-z0-9_]*|Runtime_agent|Runtime_toml|Workspace_[A-Za-z0-9_]*)\.' \
    "${core_root}/lib" \
    --glob '*.ml' --glob '*.mli' \
    || true
})"
[[ -z "${module_violations}" ]] || {
  printf '%s\n' "${module_violations}" >&2
  fail "agent core source imports a MASC coordinator module"
}

echo "agent-core boundary: ok"
