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

# Dune accepts both an installed [public_name] and its workspace-private
# [name] in a [libraries] field.  Build the private-name denylist from the
# coordinator-owned library tree so a dependency such as [voice_config] or
# [run_registry_core] cannot bypass the public [masc.*] namespace check.
coordinator_library_names="$({
  find "${repo_root}/lib" -type f \( -name dune -o -name '*.inc' \) \
    -exec perl -0777 -ne '
      while (/\(\s*name\s+([A-Za-z0-9_-]+)\s*\)/g) {
        print "$1\n";
      }
    ' {} + \
    | LC_ALL=C sort -u
})" || fail "could not derive coordinator library names"
[[ -n "${coordinator_library_names}" ]] \
  || fail "coordinator library name registry is empty"
coordinator_library_pattern="$(
  printf '%s\n' "${coordinator_library_names}" | paste -sd '|' -
)" || fail "could not build coordinator library matcher"

dune_violations="$({
  # In Dune syntax, [;] starts a comment through end-of-line unless it appears
  # inside a quoted string. Preserve quoted semicolons while scanning the code
  # prefix so comments cannot hide or imitate a library dependency.
  find "${core_root}" -type f \( -name dune -o -name '*.inc' \) -print0 \
    | while IFS= read -r -d '' dune_file; do
        if code="$(awk '
          BEGIN {
            in_string = 0
            escaped = 0
          }
          {
            code = ""
            for (i = 1; i <= length($0); i++) {
              ch = substr($0, i, 1)
              if (!in_string && ch == ";") break
              code = code ch
              if (in_string && escaped) {
                escaped = 0
              } else if (in_string && ch == "\\") {
                escaped = 1
              } else if (ch == "\"") {
                in_string = !in_string
              }
            }
            print code
          }
        ' "${dune_file}")"; then
          :
        else
          exit $?
        fi
        if code="$(perl -0777 -pe '
          s{\(\s*public_name\s+masc\.agent_core(?:\.[a-z_]+)?\s*\)}{
            my $allowed = $&;
            $allowed =~ s/[^\n]/ /g;
            $allowed
          }gex
        ' <<< "${code}")"; then
          :
        else
          exit $?
        fi
        if matches="$(rg -n \
          -e 'masc[._]' \
          -e "(^|[^A-Za-z0-9_.-])(${coordinator_library_pattern})([^A-Za-z0-9_.-]|$)" \
          <<< "${code}")"; then
          printf '%s\n' "${matches}" | sed "s#^#${dune_file}:#"
        else
          status=$?
          # ripgrep uses 1 for "no matches". Any other status means the
          # scanner itself failed, which must fail closed rather than silently
          # accepting a dependency.
          [[ "${status}" -eq 1 ]] || exit "${status}"
        fi
      done
})"
[[ -z "${dune_violations}" ]] || {
  printf '%s\n' "${dune_violations}" >&2
  fail "agent core must not depend on MASC coordinator libraries"
}

coordinator_module_pattern='(Masc_[A-Za-z0-9_]*|Keeper_[A-Za-z0-9_]*|Board_[A-Za-z0-9_]*|Gate_[A-Za-z0-9_]*|Server_[A-Za-z0-9_]*|Operator_[A-Za-z0-9_]*|Runtime_agent|Runtime_toml|Workspace_[A-Za-z0-9_]*)'
if module_violations="$(rg -n \
  -e "\\b${coordinator_module_pattern}\\." \
  -e "\\b(open!?|include)[[:space:]]+${coordinator_module_pattern}\\b" \
  -e "\\bmodule([[:space:]]+type)?[[:space:]]+[A-Z][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*${coordinator_module_pattern}\\b" \
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

echo "agent-core boundary: ok"
