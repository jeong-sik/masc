#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_root="${AGENT_CORE_ROOT:-${repo_root}/packages/agent_core}"

fail() {
  echo "agent-core boundary: $*" >&2
  exit 1
}

[[ ! -L "${core_root}" ]] || fail "package root must not be a symlink: ${core_root}"
[[ -d "${core_root}/lib" ]] || fail "missing required source tree: ${core_root}/lib"
[[ -f "${core_root}/lib/dune" ]] || fail "missing required root library stanza"
[[ -f "${core_root}/test/dune" ]] || fail "missing required behavior suite"
[[ -f "${core_root}/models.toml" ]] || fail "missing required model catalog"

# Agent Core is a source subtree in the MASC workspace, not an independently
# released package. Dune owns dependency resolution; this cheap guard owns only
# the filesystem/package shape that Dune's library graph does not describe.
if independent_surfaces="$(find "${core_root}" -mindepth 1 \
  \( -name dune-project -o -name 'dune-workspace*' -o -name '*.opam' \
     -o -name .github -o -name release-please-config.json \
     -o -name .release-please-manifest.json \) -print)"; then
  :
else
  fail "could not inspect package surfaces below ${core_root}"
fi
[[ -z "${independent_surfaces}" ]] || {
  printf '%s\n' "${independent_surfaces}" >&2
  fail "independent package surface is forbidden"
}

# A source symlink can make Dune compile a coordinator-owned file while the
# library itself still appears to live below packages/agent_core. Reject that
# direct filesystem escape; generated-source provenance is outside this guard.
if source_symlinks="$(find "${core_root}" -mindepth 1 -type l -print)"; then
  :
else
  fail "could not inspect source links below ${core_root}"
fi
[[ -z "${source_symlinks}" ]] || {
  printf '%s\n' "${source_symlinks}" >&2
  fail "source symlinks are forbidden"
}

# Dune's resolved graph is the authority for library dependencies. Keep the
# existing source-level coordinator-name guard as defense in depth until the
# parser-backed replacement tracked by #28258 lands; it is intentionally not
# presented as the dependency authority.
coordinator_module_pattern='(Masc_[A-Za-z0-9_]*|Keeper_[A-Za-z0-9_]*|Board_[A-Za-z0-9_]*|Gate_[A-Za-z0-9_]*|Server_[A-Za-z0-9_]*|Operator_[A-Za-z0-9_]*|Runtime_agent|Runtime_toml|Workspace_[A-Za-z0-9_]*)'
if module_violations="$(rg -n \
  -e "\\b${coordinator_module_pattern}\\." \
  -e "\\b(open!?|include)[[:space:]]+${coordinator_module_pattern}\\b" \
  -e "\\bmodule([[:space:]]+type)?[[:space:]]+[A-Z][A-Za-z0-9_]*([[:space:]]*:[^=[:cntrl:]]+)?[[:space:]]*=[[:space:]]*${coordinator_module_pattern}\\b" \
  -e "\\([[:space:]]*module[[:space:]]+${coordinator_module_pattern}\\b" \
  "${core_root}/lib" \
  --glob '*.ml' --glob '*.mli')"; then
  :
else
  status=$?
  if [[ "${status}" -eq 1 ]]; then
    module_violations=""
  else
    fail "could not scan agent core source imports"
  fi
fi
[[ -z "${module_violations}" ]] || {
  printf '%s\n' "${module_violations}" >&2
  fail "agent core source imports a MASC coordinator module"
}

echo "agent-core package shape: ok"
