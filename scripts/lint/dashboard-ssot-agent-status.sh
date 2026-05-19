#!/usr/bin/env bash
# RFC-0139 — dashboard agent-status SSOT guard.
#
# Block re-introduction of raw `agent.status === '<literal>'` direct
# comparisons. The typed parser + predicates in
# `dashboard/src/lib/agent-status.ts` (PR-1a) are the canonical
# decoder. PR-1b ~ PR-1d migrated `live-store.ts`,
# `components/ide/ide-presence-strip.ts`, and
# `lib/monitoring-runtime.ts`. After PR-2 (this lint guard) the
# in-tree count of qualifying literal compares is zero — new
# regressions are caught at lint time instead of audit time.
#
# Reference RFC: docs/rfc/RFC-0139-dashboard-agent-status-ssot.md
#
# Signals checked:
#   §10-1  `<bound_name>.status === '<literal>'` where the bound name
#          is one of the conventional agent-shaped identifiers
#          (`agent`, `agents`, `a`, `userAgent`, callback param) and
#          the literal is in the closed AgentStatus union. The
#          regex matches the actual call shape, not free-form
#          mentions in strings or comments (those are filtered).
#
# Allowlist: scripts/lint/dashboard-ssot-agent-status.allowlist
#   path:line — line-anchored debt entry
#
# Exit codes:
#   0 — clean
#   1 — new violations (not in allowlist)
#   2 — stale allowlist entries (entry no longer maps to a violation)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

ALLOWLIST_FILE="scripts/lint/dashboard-ssot-agent-status.allowlist"
if [[ ! -f "$ALLOWLIST_FILE" ]]; then
  touch "$ALLOWLIST_FILE"
fi

violations=()

# §10-1 — Agent.status raw literal comparison.
#
# Match `<agent_identifier>.status === '<AgentStatus literal>'`. The
# left operand identifier set is curated to the conventional names
# used across dashboard code; widening it risks false positives from
# the many unrelated `.status` fields (RemoteData, governance judge,
# graph node, etc.).
#
# Exempt files (canonical readers — comparison is their job):
#   - lib/agent-status.ts        : typed parser + predicate SSOT
#   - lib/agent-status.test.ts   : exhaustive variant coverage
agent_literal_compares=$(
  rg -n \
    --type ts \
    -g '!dashboard/src/lib/agent-status.ts' \
    -g '!dashboard/src/lib/agent-status.test.ts' \
    '\b(agent|agents\[[^]]+\]|userAgent)\.status\s*===\s*[\x27"](active|busy|listening|idle|inactive|offline)[\x27"]' \
    dashboard/src 2>/dev/null || true
)
if [[ -n "$agent_literal_compares" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && violations+=("§10-1 agent.status literal comparison:$line")
  done <<< "$agent_literal_compares"
fi

# Allowlist filter.
allowlist_lines=$(grep -vE '^\s*(#|$)' "$ALLOWLIST_FILE" || true)
unmatched_violations=()
# `${violations[@]:-}` guards against `set -u` failing when no signal
# matched (clean run) — bash treats an empty array as unbound otherwise.
for v in "${violations[@]:-}"; do
  [[ -z "$v" ]] && continue
  path_line=$(echo "$v" | sed -E 's/^§10-[0-9]+ [^:]+://' | cut -d: -f1,2)
  if grep -Fxq "$path_line" <<< "$allowlist_lines"; then
    continue
  fi
  unmatched_violations+=("$v")
done

# Stale allowlist detection — any allowlist entry that doesn't map to
# a current violation is stale.
stale_allowlist=()
if [[ -n "$allowlist_lines" ]]; then
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    found=0
    for v in "${violations[@]:-}"; do
      [[ -z "$v" ]] && continue
      path_line=$(echo "$v" | sed -E 's/^§10-[0-9]+ [^:]+://' | cut -d: -f1,2)
      if [[ "$path_line" == "$entry" ]]; then
        found=1
        break
      fi
    done
    if [[ "$found" == "0" ]]; then
      stale_allowlist+=("$entry")
    fi
  done <<< "$allowlist_lines"
fi

if (( ${#unmatched_violations[@]} > 0 )); then
  echo "RFC-0139 §10 SSOT guard — ${#unmatched_violations[@]} new violation(s):"
  for v in "${unmatched_violations[@]}"; do
    echo "  $v"
  done
  echo
  echo "Use the typed parser + predicates in"
  echo "  dashboard/src/lib/agent-status.ts"
  echo "(parseAgentStatus / isAgentActive / isAgentOffline / isAgentPresent)."
  echo
  echo "If a violation is intentional and approved (rare), add the"
  echo "path:line to $ALLOWLIST_FILE with a comment explaining why."
  exit 1
fi

if (( ${#stale_allowlist[@]} > 0 )); then
  echo "RFC-0139 §10 SSOT guard — ${#stale_allowlist[@]} stale allowlist entry/entries:"
  for entry in "${stale_allowlist[@]}"; do
    echo "  $entry"
  done
  exit 2
fi

violations_count=${#violations[@]}
echo "RFC-0139 §10 SSOT guard: clean (${violations_count} allowlisted violation(s))"
exit 0
