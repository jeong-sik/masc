#!/usr/bin/env bash
# validate-keeper-fsm-graph.sh — verify each edge label in
# docs/keeper-fsm-graph.dot has a corresponding instrumentation site
# in the OCaml sources.
#
# Exit 0 on success, 1 if any documented edge is missing instrumentation.
# This is a structural check; PR-H tests the predicates themselves.
#
# The validator deliberately greps for the literal label string the
# producer uses with [Prometheus.inc_counter ... ~labels:[("edge", "...")]].
# A wiring rename will surface as a validator failure rather than a
# silently dead counter.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOT_FILE="$REPO_ROOT/docs/keeper-fsm-graph.dot"
SEARCH_ROOT="$REPO_ROOT/lib"

if [ ! -f "$DOT_FILE" ]; then
  echo "ERROR: $DOT_FILE not found" >&2
  exit 1
fi

# Edge labels we expect to be instrumented (match docs/keeper-fsm-graph.dot
# solid edges).  Dashed edges in the .dot file are documented-only and
# intentionally omitted.
declare -a INSTRUMENTED_EDGES=(
  "ksm_to_kcl_routing"
  "ksm_to_kmc_compact_trigger"
  "kmc_to_ksm_compact_completed"
  "kcl_to_ktc_exhaustion"
)

missing=0
for edge in "${INSTRUMENTED_EDGES[@]}"; do
  if ! grep -r -q --include="*.ml" "\"edge\", \"$edge\"" "$SEARCH_ROOT"; then
    echo "MISSING: edge \"$edge\" not instrumented in $SEARCH_ROOT" >&2
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  echo "" >&2
  echo "$missing edge(s) documented in $DOT_FILE but not instrumented." >&2
  echo "Either wire the counter in OCaml or remove the edge from the .dot file." >&2
  exit 1
fi

# Reverse check: any edge label used in OCaml that is not documented?
# Portable to bash 3.2 (macOS default) — uses sorted lists + comm
# instead of associative arrays.
expected_list=$(printf '%s\n' "${INSTRUMENTED_EDGES[@]}" | sort -u)
actual_list=$(grep -r -h --include="*.ml" -oE '"edge", "[a-z_]+"' "$SEARCH_ROOT" \
              | sed -E 's/.*"edge", "([^"]+)".*/\1/' \
              | sort -u)

unknown_edges=$(comm -23 <(printf '%s\n' "$actual_list") <(printf '%s\n' "$expected_list"))
if [ -n "$unknown_edges" ]; then
  echo "" >&2
  echo "UNDOCUMENTED edge label(s) instrumented but not in $DOT_FILE:" >&2
  echo "$unknown_edges" >&2
  exit 1
fi

echo "OK: all ${#INSTRUMENTED_EDGES[@]} documented edges are instrumented and vice versa."
