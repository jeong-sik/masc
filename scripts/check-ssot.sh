#!/usr/bin/env bash
# SSOT bypass guardrail.
#
# Ratchet-based: each rule has a baseline count. CI fails if the count grows.
# Baselines are lowered as SSOT-consolidation PRs land.
#
# See #8462 for the proposal and #8355/#8387/#8403/#8414/#8448/#8455 for
# the bypass class this rule set targets.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: check-ssot.sh requires ripgrep (rg)." >&2
  exit 2
fi

fail=0

count_rule_excluding() {
  local pattern="$1"
  local exclude_regex="$2"
  shift 2
  # grep -Ev returns 1 when all lines are filtered; avoid tripping pipefail.
  if [ -n "$exclude_regex" ]; then
    { rg -c --no-heading "$pattern" "$@" 2>/dev/null || true; } \
      | { grep -Ev "$exclude_regex" || true; } \
      | awk -F: '{sum += $2} END {print sum+0}'
  else
    { rg -c --no-heading "$pattern" "$@" 2>/dev/null || true; } \
      | awk -F: '{sum += $2} END {print sum+0}'
  fi
}

check_rule() {
  local name="$1"
  local baseline="$2"
  local replacement_hint="$3"
  local pattern="$4"
  local exclude_regex="$5"
  shift 5
  local current
  current="$(count_rule_excluding "$pattern" "$exclude_regex" "$@")"

  if [ "$current" -gt "$baseline" ]; then
    echo "ERROR[$name]: $current occurrences (baseline $baseline) — SSOT bypass grew." >&2
    echo "  Replace with: $replacement_hint" >&2
    echo "  Offending lines:" >&2
    if [ -n "$exclude_regex" ]; then
      rg -n --no-heading "$pattern" "$@" 2>/dev/null | grep -Ev "$exclude_regex" | sed 's/^/    /' >&2
    else
      rg -n --no-heading "$pattern" "$@" 2>/dev/null | sed 's/^/    /' >&2
    fi
    fail=1
  elif [ "$current" -lt "$baseline" ]; then
    echo "NOTE[$name]: $current occurrences (baseline $baseline). Lower the baseline in scripts/check-ssot.sh."
  else
    echo "OK[$name]: $current occurrences (baseline $baseline)."
  fi
}

# SSOT-R1 — .masc path concat bypasses Workspace_utils.masc_dir helper.
# Tracked: #8355 (37 files at filing; current ratchet from main).
# Excluded: the helper impl + backend setters where the literal IS the SSOT.
check_rule "R1-masc-path" 0 \
  "Workspace_utils.masc_dir <config>" \
  'Filename\.concat\s+[a-zA-Z_]+\s+"\.masc"' \
  'workspace_utils_paths_backend|workspace_utils_backend_setup|workspace_eio' \
  lib bin

# SSOT-R2 — loopback literal bypasses Masc_network_defaults.masc_http_default_host.
# Tracked: #8387.
# Excluded: helper definition + display-name mapping (server_auth) + URL prefix predicate.
check_rule "R2-loopback-literal" 1 \
  "Masc_network_defaults.masc_http_default_host" \
  '"127\.0\.0\.1"' \
  'masc_network_defaults|server_auth|graphql_endpoint' \
  lib

# SSOT-R4 — config filename literal.
# Tracked: #8414. Helper to be added (Config_filenames) in the fix.
# No exclusion — every site should eventually route through the helper.
check_rule "R4-config-filename" 0 \
  "Config_filenames.<name> (add helper per #8414)" \
  '"(runtime\.json|keeper_runtime\.toml|tool_policy\.toml)"' \
  '' \
  lib

# SSOT-R5 — health path literal bypasses Server_health_paths helper.
# Tracked: #8403. Helper already exists at lib/server/server_health_paths.ml.
# Baseline 0: new literals outside the helper module are immediate failures.
check_rule "R5-health-path" 0 \
  "Server_health_paths.liveness / .readiness" \
  '"/health/(live|ready)"' \
  'server_health_paths' \
  lib

# SSOT-R6 — no home-anchored MASC runtime root. Runtime state must resolve
# from an explicit base path and then append .masc.
#
# The baseline count of 3 is intentional: all matches are in docs that
# explicitly warn against bare home-anchored .masc roots (e.g. tilde or
# HOME env expansion). See KEEPER-USER-MANUAL.md and
# BOOT-ENV-STATE-INVENTORY.md. No code or script uses such a root.
check_rule "R6-home-masc-root" 3 \
  "<base-path>/.masc with explicit MASC_BASE_PATH or --base-path" \
  '(\$HOME|\$\{HOME[^}]*\}|~)/[^[:space:]`'\''"]*\.masc([/[:space:]`'\''".,)]|$)' \
  '' \
  bin lib scripts docs

# SSOT-R7 — OTel metric label key for keeper identity is "keeper".
# "keeper_name" in a metric label list splits the label vocabulary: Grafana
# template variables and panel group-bys query "keeper", so keeper_name-keyed
# series render as 0/No data (masc-keeper-full broke this way; the $keeper
# variable sourced label_values(masc_keeper_turns_total, keeper) and got an
# empty list). JSON codec fields named "keeper_name" are NOT affected — this
# rule only matches inside ~labels:[...] lists and let <name>labels = [...] bindings.
# Needs -U (multiline): label lists wrap across lines.
r7_pattern='(~labels:|let [a-z_]*labels\s*=\s*)\[[^\]]{0,400}"keeper_name"'
r7_count="$({ rg -U -c --no-heading "$r7_pattern" bin lib test 2>/dev/null || true; } \
  | awk -F: '{sum += $2} END {print sum+0}')"
if [ "$r7_count" -gt 0 ]; then
  echo "ERROR[R7-metric-label-keeper-name]: $r7_count occurrences (baseline 0)." >&2
  echo "  Replace with: \"keeper\" — the canonical metric label key (cf. Keeper_hooks_oas_types.label_keeper)." >&2
  echo "  Offending sites:" >&2
  rg -U -l "$r7_pattern" bin lib test 2>/dev/null | sed 's/^/    /' >&2
  fail=1
else
  echo "OK[R7-metric-label-keeper-name]: 0 occurrences (baseline 0)."
fi

# SSOT-R3 (tool-name literal) is intentionally deferred to #8448's landing:
# the raw `"masc_..."` match is too noisy without the Tool_name.Keeper variant
# refactor in place. Add to this script once #8448 introduces a narrow dispatch
# pattern we can grep for.

echo ""
echo "SSOT snapshot (baselines tracked inline; lower them as SSOT PRs land):"
echo "  Script: scripts/check-ssot.sh"
echo "  Related issues: #8355 #8387 #8403 #8414 #8448 #8455 #8462"

exit "$fail"
