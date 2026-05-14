#!/usr/bin/env bash
# RFC-0047 caller inventory freeze.
#
# Generates two files:
#   docs/rfc/RFC-0047-caller-inventory.txt — every external reference
#     to the `lib/oas_*` adapter family (file:line:caller_module).
#   docs/rfc/RFC-0047-module-graph.dot     — Graphviz DOT showing
#     cross-domain references FROM each oas_* file.
#
# Subsequent RFC-0047 phase PRs re-run this script and diff against
# the baseline to detect caller-surface drift.
#
# Usage:
#   scripts/rfc-0047-oas-adapter-inventory.sh
#   scripts/rfc-0047-oas-adapter-inventory.sh --check   # exit 1 on drift
#
# Exits 0 normally; with --check, exits 1 if regenerated output differs
# from the committed baseline.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

INVENTORY_FILE=docs/rfc/RFC-0047-caller-inventory.txt
GRAPH_FILE=docs/rfc/RFC-0047-module-graph.dot
MODE=${1:-write}

# Module names exported by lib/oas_*.ml (capitalize first letter of basename).
oas_modules() {
  ls lib/oas_*.ml 2>/dev/null | while read -r f; do
    base=$(basename "$f" .ml)
    # First-letter capitalize (portable for bash 3.2): oas_worker_named → Oas_worker_named
    echo "$base" | awk '{print toupper(substr($0,1,1)) substr($0,2)}'
  done
}

# 1. Caller inventory: every reference to Oas_*.f from outside the file
#    that defines it.
generate_inventory() {
  {
    echo "# RFC-0047 caller inventory (frozen at Phase 1)"
    echo "# Format: caller_path:line:module_referenced"
    echo "# Regenerate: scripts/rfc-0047-oas-adapter-inventory.sh"
    echo "# Drift check: scripts/rfc-0047-oas-adapter-inventory.sh --check"
    echo ""
    for mod in $(oas_modules | sort); do
      defining_file="lib/$(echo "$mod" | tr '[:upper:]' '[:lower:]').ml"
      # Find all references to "Mod." outside the defining file/mli.
      rg -n --no-heading "\\b${mod}\\." \
        --glob '!'"$defining_file" \
        --glob '!lib/'"$(basename "$defining_file" .ml)"'.mli' \
        --glob '!docs/rfc/RFC-0047-*.md' \
        --glob '!docs/rfc/RFC-0047-caller-inventory.txt' \
        2>/dev/null \
        | awk -v m="$mod" -F: '{print $1":"$2":"m}' \
        || true
    done
  } | sort
}

# 2. Module graph DOT: oas_* file → cross-domain category, weight = ref count.
generate_graph() {
  {
    echo "// RFC-0047 module graph (frozen at Phase 1)"
    echo "// Edges: oas_*.ml → external domain category, label = ref count."
    echo "digraph rfc_0047 {"
    echo "  rankdir=LR;"
    echo "  node [shape=box, fontname=\"Helvetica\"];"
    echo "  edge [fontname=\"Helvetica\", fontsize=10];"
    echo ""
    echo "  // OAS adapter family"
    for f in lib/oas_*.ml; do
      [ -f "$f" ] || continue
      base=$(basename "$f" .ml)
      echo "  \"$base\" [style=filled, fillcolor=\"#fce4ec\"];"
    done
    echo ""
    echo "  // Target domain categories"
    for cat in Cascade Keeper Masc Dashboard Auth Coord Pulse Briefing Board; do
      echo "  \"${cat}_*\" [style=filled, fillcolor=\"#e3f2fd\"];"
    done
    echo ""
    echo "  // Cross-domain references"
    for f in lib/oas_*.ml; do
      [ -f "$f" ] || continue
      base=$(basename "$f" .ml)
      for cat in Cascade Keeper Masc Dashboard Auth Coord Pulse Briefing Board; do
        count=$(rg -c "\\b${cat}_[a-z]" "$f" 2>/dev/null || true)
        count=${count:-0}
        if [ "$count" -gt 0 ]; then
          echo "  \"$base\" -> \"${cat}_*\" [label=\"$count\"];"
        fi
      done
    done
    echo "}"
  }
}

if [ "$MODE" = "--check" ]; then
  tmp_inv=$(mktemp); tmp_graph=$(mktemp)
  trap 'rm -f "$tmp_inv" "$tmp_graph"' EXIT
  generate_inventory > "$tmp_inv"
  generate_graph > "$tmp_graph"
  drift=0
  if ! diff -q "$INVENTORY_FILE" "$tmp_inv" >/dev/null 2>&1; then
    echo "DRIFT: $INVENTORY_FILE differs from regenerated baseline."
    diff "$INVENTORY_FILE" "$tmp_inv" | head -30
    drift=1
  fi
  if ! diff -q "$GRAPH_FILE" "$tmp_graph" >/dev/null 2>&1; then
    echo "DRIFT: $GRAPH_FILE differs from regenerated baseline."
    diff "$GRAPH_FILE" "$tmp_graph" | head -30
    drift=1
  fi
  if [ "$drift" -eq 0 ]; then
    echo "OK: caller inventory and module graph match committed baseline."
  fi
  exit "$drift"
fi

generate_inventory > "$INVENTORY_FILE"
generate_graph > "$GRAPH_FILE"
echo "Wrote $INVENTORY_FILE ($(wc -l <"$INVENTORY_FILE") lines)"
echo "Wrote $GRAPH_FILE ($(wc -l <"$GRAPH_FILE") lines)"
