#!/usr/bin/env bash
# Mutation-lint ratchet gate.
#
# Runs scripts/tla-mutation-lint.sh --count and compares the output
# against scripts/tla-mutation-lint-baseline.json. The baseline is a
# *ceiling*: current_count must be <= keeper_mutation_sites_max.
#
# Inversion vs tla-ppx-ratchet.sh: the adoption ratchet enforces a
# *floor* (current >= baseline) because we want monotonic adoption
# growth. This ratchet enforces a *ceiling* (current <= baseline)
# because we want monotonic mutation-site decrease.
#
# Reference: planning/claude-plans/greedy-sleeping-blossom.md (Track 1A).
# Sister script: scripts/tla-ppx-ratchet.sh.
#
# Usage:
#   scripts/tla-mutation-lint-ratchet.sh              # check; exit 0 ok / 2 drift up / 1 error
#   scripts/tla-mutation-lint-ratchet.sh --regenerate # rewrite baseline from current count
#   scripts/tla-mutation-lint-ratchet.sh --print      # print current count, no compare
#
# CI integration: a job in .github/workflows/ci.yml runs this on
# every PR; a non-zero exit blocks merge if the check is required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DETECTOR="${SCRIPT_DIR}/tla-mutation-lint.sh"
BASELINE_FILE="${SCRIPT_DIR}/tla-mutation-lint-baseline.json"

for tool in bash python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[tla-mutation-lint-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

if [ ! -x "$DETECTOR" ]; then
  echo "[tla-mutation-lint-ratchet] detector not executable: $DETECTOR" >&2
  exit 1
fi

current_count() {
  bash "$DETECTOR" --count
}

baseline_max() {
  jq -r '.keeper_mutation_sites_max' "$BASELINE_FILE"
}

write_baseline() {
  local count="$1"
  python3 - "$BASELINE_FILE" "$count" <<'PY'
import json, sys
path, count = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    data = json.load(f)
data["keeper_mutation_sites_max"] = count
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

MODE="check"
case "${1:-}" in
  --regenerate) MODE="regen" ;;
  --print)      MODE="print" ;;
  "")           MODE="check" ;;
  *)
    echo "[tla-mutation-lint-ratchet] unknown flag: $1" >&2
    echo "  use --regenerate or --print" >&2
    exit 1
    ;;
esac

current="$(current_count)"

case "$MODE" in
  print)
    echo "current=$current"
    echo "baseline_max=$(baseline_max)"
    exit 0
    ;;
  regen)
    write_baseline "$current"
    echo "[tla-mutation-lint-ratchet] regenerated baseline: keeper_mutation_sites_max=$current"
    exit 0
    ;;
esac

baseline="$(baseline_max)"

if [ "$current" -le "$baseline" ]; then
  if [ "$current" -lt "$baseline" ]; then
    echo "[tla-mutation-lint-ratchet] OK — mutations decreased from $baseline to $current"
    echo "[tla-mutation-lint-ratchet] consider running --regenerate in this PR to lower the floor"
  else
    echo "[tla-mutation-lint-ratchet] OK — mutations at floor ($current)"
  fi
  exit 0
fi

echo "[tla-mutation-lint-ratchet] FAIL — mutations rose from $baseline to $current" >&2
echo "" >&2
echo "Recent additions in lib/keeper/ added new ref-state mutations." >&2
echo "Either:" >&2
echo "  (a) Refactor the new site to avoid mutation (preferred)" >&2
echo "  (b) Annotate with a line comment immediately above the mutation:" >&2
echo "        (* tla-lint: allow-mutation: <reason> *)" >&2
echo "" >&2
echo "If the increase is intentional and unavoidable, run:" >&2
echo "  bash scripts/tla-mutation-lint-ratchet.sh --regenerate" >&2
echo "and open a paired follow-up issue documenting the rationale." >&2
echo "" >&2
echo "List the new sites with:" >&2
echo "  bash scripts/tla-mutation-lint.sh" >&2
exit 2
