#!/usr/bin/env bash
# RFC-0084 §10 + PR-14 — CI lint: enforce single-entry dispatch surface.
#
# After PR-7 (keeper turn) / PR-8 (MCP server) / PR-9 (tag-dispatch
# fallback) migration and PR-11 mli surface removal, the public
# dispatch surface is `Tool_dispatch.guarded_dispatch` only. Both
# legacy entries (`Tool_dispatch.dispatch`, `Tool_dispatch.dispatch_structured`)
# remain in `tool_dispatch.ml` as private implementation details and
# are no longer reachable through the mli.
#
# This script fails CI if any file under `lib/` or `bin/` (excluding
# `lib/tool_dispatch.ml` itself) references the legacy entries — the
# pinned invariant from `test/test_dispatch_legacy_removed.ml`.
#
# Exit codes:
#   0  : invariant holds (zero external callers of legacy entries)
#   1  : invariant broken (legacy caller introduced)
#
# Run locally:
#   bash ci/lint-no-direct-dispatch.sh
#
# RFC-0084 §10 verification matrix entry: `Tool_dispatch.dispatch`
# direct caller in lib/, bin/, test/ must be 0.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Search lib/ and bin/ but exclude tool_dispatch.ml itself (private
# implementation file is allowed to call its own helpers).
EXCLUDE='lib/tool_dispatch.ml'

violations=0

scan() {
  local pattern="$1"
  local label="$2"
  # rg with -P (PCRE) for word-boundary matching to distinguish
  # `Tool_dispatch.dispatch` from `Tool_dispatch.dispatch_structured`
  # and from `Tool_dispatch.guarded_dispatch`.
  local hits
  hits=$(rg -nP "$pattern" lib/ bin/ --glob "!${EXCLUDE}" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "ERROR: legacy ${label} caller(s) found:" >&2
    echo "$hits" >&2
    violations=$((violations + 1))
  fi
}

# `Tool_dispatch.dispatch` followed by whitespace (excludes `dispatch_structured` and `guarded_dispatch`).
scan 'Tool_dispatch\.dispatch(?=[\s\(])' 'Tool_dispatch.dispatch'

# `Tool_dispatch.dispatch_structured` (exact).
scan 'Tool_dispatch\.dispatch_structured' 'Tool_dispatch.dispatch_structured'

# `Tool_dispatch.run_pre_hooks` — PR-8 intentionally retained the manual
# call inside dispatch_by_tag because it does tag-based dispatch (not
# handler-registry) and re-routes pre-hook
# semantics inside the Tool_telemetry.with_span wrap (PR-8 PR body
# §"What this PR does NOT do"). Excluded from this lint by design;
# follow-up cleanup PR may inline pre-hook chain into guarded_dispatch.
# (No scan for `Tool_dispatch.run_pre_hooks` — see rationale above.)

if [ "$violations" -gt 0 ]; then
  echo "" >&2
  echo "RFC-0084 single-dispatch-path invariant broken: $violations" \
       "legacy caller pattern(s) found." >&2
  echo "All keeper-originated dispatch must go through" \
       "Tool_dispatch.guarded_dispatch (PR-3, PR-7, PR-8, PR-9)." >&2
  exit 1
fi

echo "RFC-0084 dispatch surface invariant: OK (0 external callers of legacy entries)."
exit 0
