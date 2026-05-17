#!/usr/bin/env bash
# Detect the OCaml block-comment terminator trap: a wildcard suffix
# `*` directly adjacent to a closing paren `)` produces the `*)`
# byte sequence inside a comment, which the OCaml lexer interprets
# as the comment terminator. The comment ends earlier than the
# author intended, and the prose that follows is parsed as OCaml
# source, surfacing as a generic "Syntax error".
#
# Why this gate exists:
#   PR #15836 cleanup added a comment naming pr_url consumers as
#     (keeper_tool_call_log, keeper_hooks_oas, audit_keeper_*)
#   The trailing `_*)` closed the surrounding block comment, so the
#   next line ("already read pr_url as a typed field ...") was
#   parsed as OCaml source. `dune build` reported:
#     File "lib/tool_task.ml", line 907, characters 29-31: Syntax error
#   PR #15846 hotfixed by replacing the glob with `audit_keeper_...`.
#   This gate prevents the same trap from re-entering the tree.
#
# Signal:
#   Substring `_*)` anywhere in tracked *.ml or *.mli files under
#   lib/, test/, or oas/lib/. The underscore-before-glob form is
#   the practical signature — naked `*)` shows up as the legitimate
#   comment terminator on almost every comment-ending line and is
#   not a useful signal.
#
# Allowed (never flagged):
#   - Lines listed in the allowlist file as "path:line". The
#     existing tree has two such cases inside OCaml string literals
#     (where `*)` is not a comment terminator):
#       lib/server/server_runtime_bootstrap.ml — log message
#       lib/keeper/keeper_types_profile.ml     — error message
#
# Allowlist format: one entry per line, "path:line", '#' comments
# allowed.
#
# Exit codes:
#   0 - clean
#   1 - new violations (not in allowlist)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="${ROOT}/scripts/lint/no-ocaml-comment-terminator-trap.allowlist"

ROOTS=("${ROOT}/lib" "${ROOT}/test" "${ROOT}/oas/lib")

# bash 3.2 (macOS dev shell) lacks associative arrays, so allowlist
# membership is checked via per-line grep against the file directly.
# Missing allowlist file is fine: treated as empty.
is_allowed() {
  local key="$1"
  [[ -f "${ALLOWLIST}" ]] || return 1
  grep -qE "^[[:space:]]*${key}[[:space:]]*(#.*)?$" "${ALLOWLIST}"
}

violations=()
while IFS= read -r match; do
  [[ -z "${match}" ]] && continue
  path="${match%%:*}"
  rest="${match#*:}"
  lineno="${rest%%:*}"
  rel="${path#${ROOT}/}"
  key="${rel}:${lineno}"
  if is_allowed "${key}"; then
    continue
  fi
  violations+=("${key}  ${match##*:}")
done < <(
  for r in "${ROOTS[@]}"; do
    [[ -d "${r}" ]] || continue
    rg --no-heading --line-number --color=never \
       --glob '*.ml' --glob '*.mli' \
       -F '_*)' "${r}" 2>/dev/null || true
  done
)

if [[ ${#violations[@]} -gt 0 ]]; then
  echo "OCaml block-comment terminator trap detected (\`_*)\` adjacent" >&2
  echo "to wildcard suffix). The lexer closes the surrounding comment" >&2
  echo "early, and the next line is parsed as OCaml source." >&2
  echo "" >&2
  echo "Fix: replace the glob suffix with an ellipsis or placeholder," >&2
  echo "or insert a space before the closing paren." >&2
  echo "  Bad : audit_keeper_*)" >&2
  echo "  Good: audit_keeper_...)" >&2
  echo "  Good: audit_keeper_<name>)" >&2
  echo "  Good: audit_keeper_* )" >&2
  echo "" >&2
  echo "If the match is inside a string literal (where \`*)\` is not a" >&2
  echo "comment terminator), add the path:line to:" >&2
  echo "  ${ALLOWLIST#${ROOT}/}" >&2
  echo "" >&2
  echo "Violations:" >&2
  for v in "${violations[@]}"; do
    echo "  ${v}" >&2
  done
  exit 1
fi

echo "no-ocaml-comment-terminator-trap: clean"
