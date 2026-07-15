#!/usr/bin/env bash
# RFC-0135 §9 — dashboard keeper-state SSOT guard.
#
# Block patterns that re-introduce the dual-path normalization fixed
# across PR-1 ~ PR-7. Each pattern below either:
#   (a) bypasses `KeeperOperationalState` (lib/keeper-operational-state.ts)
#   (b) re-creates a primitive predicate already exported from
#       `lib/keeper-predicates.ts`
#   (c) re-introduces a Korean label that collides between state-noun
#       and action-verb contexts.
#
# Reference RFC: docs/rfc/RFC-0135-dashboard-keeper-operational-ssot.md
#
# Signals checked:
#   §9-1  Flat `keeper.runtime_blocker_*` read outside the SSOT module
#         (caller must go through deriveKeeperOperationalState).
#   §9-2  New paused-predicate OR chain using (paused | phase | status |
#         pipeline_stage) — must call `isKeeperPaused` instead.
#   §9-3  Local `normalizePhase` declaration in dashboard/src — phase
#         casing SSOT lives in `toKeeperPhase` (keeper-store-normalize).
#   §9-4  `default:` arm added to deriveKeeperOperationalState `switch`
#         on state.kind — RFC-0135 §9 forbids catch-all.
#   §9-5  Same Korean word emitted as both a state noun (badge/chip) and
#         an action verb (button label) in the same file — append `하기`
#         to the verb form per PR-7.
#   §9-6  Status-only offline classifier (audit B5, 2026-05-19) — local
#         `keeper.status !== 'offline'` filters undercount presence.
#         Must route through `isKeeperOffline` SSOT (catches the full
#         off-token set: `offline | inactive | unbooted`).
#
# Allowlist: scripts/lint/dashboard-ssot-keeper-state.allowlist
#   path:line — line-anchored debt entry
#
# Exit codes:
#   0 — clean
#   1 — new violations (not in allowlist)
#   2 — stale allowlist entries (entry no longer maps to a violation)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

ALLOWLIST_FILE="scripts/lint/dashboard-ssot-keeper-state.allowlist"
if [[ ! -f "$ALLOWLIST_FILE" ]]; then
  touch "$ALLOWLIST_FILE"
fi

# `rg` returns exit 1 when there are zero matches — that is a clean
# pass for this script. Wrap each search so the script does not abort
# under `set -e`.
violations=()

# §9-1 — Blocker class branched on a literal enum string outside SSOT.
#
# Narrower than `keeper.runtime_blocker_(class|summary)` — only catches
# `keeper.runtime_blocker_class === '<literal>'` direct comparisons,
# the actual SSOT bypass pattern (visibility decision keyed on a
# hardcoded blocker class). Existence checks
# (`Boolean(keeper.runtime_blocker_class)`, `?? null`, `?.trim()`) and
# passthrough wire-export
# (`runtime_blocker_class: keeper.runtime_blocker_class`) stay
# legitimate.
#
# Exempt files (canonical readers — comparison is their job):
#   - lib/keeper-operational-state.ts        : typed SSOT
#   - lib/keeper-predicates.ts               : WAKEUP_RECOVERABLE_BLOCKERS set
#   - lib/keeper-runtime-display.ts          : display-label / hint mapper
#   - components/agent-roster.ts             : routes via SSOT
#   - components/keeper-detail-runtime.ts    : same
#   - components/keeper-detail-alert-strip.ts: same
#   - components/keeper-action-panel.ts      : uses SSOT predicates
#   - components/fleet-telemetry-utils.ts    : telemetry passthrough
#                                              (wire→export, no decision)
#
# New components must route through the SSOT or join this exempt list
# with a PR-body rationale.
flat_blocker_matches=$(
  rg -n \
    --type ts \
    -g '!dashboard/src/lib/keeper-operational-state.ts' \
    -g '!dashboard/src/lib/keeper-operational-state.test.ts' \
    -g '!dashboard/src/lib/keeper-predicates.ts' \
    -g '!dashboard/src/lib/keeper-predicates.test.ts' \
    -g '!dashboard/src/lib/keeper-runtime-display.ts' \
    -g '!dashboard/src/lib/keeper-runtime-display.test.ts' \
    -g '!dashboard/src/components/fleet-telemetry-utils.ts' \
    -g '!dashboard/src/components/fleet-telemetry-utils.test.ts' \
    -g '!dashboard/src/components/agent-roster.ts' \
    -g '!dashboard/src/components/agent-roster.test.ts' \
    -g '!dashboard/src/components/keeper-detail-runtime.ts' \
    -g '!dashboard/src/components/keeper-detail-runtime.test.ts' \
    -g '!dashboard/src/components/keeper-detail-alert-strip.ts' \
    -g '!dashboard/src/components/keeper-detail-alert-strip.test.ts' \
    -g '!dashboard/src/components/keeper-action-panel.ts' \
    'keeper\.runtime_blocker_class\s*===\s*[\x27"][a-z_]+[\x27"]' \
    dashboard/src 2>/dev/null || true
)
if [[ -n "$flat_blocker_matches" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && violations+=("§9-1 flat blocker read:$line")
  done <<< "$flat_blocker_matches"
fi

# §9-2 — Paused predicate OR chain.
# Detect a new OR chain combining at least two of (paused, phase
# 'Paused', pipeline_stage 'paused', status 'paused') outside the SSOT.
# Signal: `\.paused === true` adjacent to `phase ===` or `status ===`
# or `pipeline_stage ===` literal-paused comparison, on consecutive lines.
paused_chain_matches=$(
  rg -n \
    --type ts \
    --multiline \
    -g '!dashboard/src/lib/keeper-predicates.ts' \
    -g '!dashboard/src/lib/keeper-predicates.test.ts' \
    -g '!dashboard/src/lib/keeper-operational-state.ts' \
    'keeper\.paused === true\s*\|\|\s*.*?===\s*.[Pp]aused.|phase === .[Pp]aused.\s*\|\|\s*.*paused' \
    dashboard/src 2>/dev/null || true
)
if [[ -n "$paused_chain_matches" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && violations+=("§9-2 paused OR chain:$line")
  done <<< "$paused_chain_matches"
fi

# §9-3 — Local normalizePhase declaration outside the SSOT.
# `toKeeperPhase` in keeper-store-normalize.ts is canonical (PR-2).
# Allow ide-persistence-panel.ts (a different persistence domain outside
# RFC-0135 scope).
local_normalize_phase=$(
  rg -n \
    --type ts \
    -g '!dashboard/src/components/ide/ide-persistence-panel.ts' \
    -g '!dashboard/src/keeper-store-normalize.ts' \
    '^(export\s+)?function normalizePhase\(' \
    dashboard/src 2>/dev/null || true
)
if [[ -n "$local_normalize_phase" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && violations+=("§9-3 local normalizePhase:$line")
  done <<< "$local_normalize_phase"
fi

# §9-4 — catch-all default in derive function.
# Detect a `default:` arm inside a `switch` over `state.kind` in any
# file consuming KeeperOperationalState — RFC-0135 §9 demands
# exhaustive matching so a new variant is a compile error.
catch_all_default=$(
  rg -n -B1 \
    --type ts \
    'switch\s*\(\s*state\.kind\s*\)' \
    dashboard/src 2>/dev/null | grep -E "default:" | head -20 || true
)
if [[ -n "$catch_all_default" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && violations+=("§9-4 catch-all default on state.kind:$line")
  done <<< "$catch_all_default"
fi

# §9-5 — Noun/verb Korean label collision.
# For each known collision keyword, flag a file that contains a button
# label without 하기 suffix at the verb site. Two button-shape patterns
# are checked because the codebase uses both:
#   - htm/preact `<${ActionButton}>...<//>` (template close)
#   - native `<button ...>...</button>` (explicit close)
# PR-7 converted action-panel/alert-strip to `${kw}하기`. PR-10 extends
# the sweep to keeper-detail-lifecycle, keeper-config-panel, tool-executor.
# The list of keywords grows when noun/verb usage diverges in practice;
# `편집`, `실행`, `초기화` were added after the 2026-05-19 audit.
collision_keywords=("일시정지" "재개" "기동" "종료" "편집" "실행" "초기화")
for kw in "${collision_keywords[@]}"; do
  # Files containing a button-like pattern that is not the 하기-suffixed
  # verb form. Captures both `<//>` and `</button>` close shapes.
  bad_button=$(
    rg -n --type ts \
      ">${kw}<(//|/button)>" \
      dashboard/src 2>/dev/null \
    | grep -v "${kw}하기" || true
  )
  if [[ -n "$bad_button" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && violations+=("§9-5 noun/verb collision (${kw} as bare button):$line")
    done <<< "$bad_button"
  fi
done

# §9-6 — Status-only offline classifier (audit B5, 2026-05-19).
# Detect `<anything>(keeper.status) !== 'offline'` or `(.status) === 'offline'`
# style guards. The SSOT `isKeeperOffline(keeper)` catches all three
# off-tokens (`offline | inactive | unbooted`) — local helpers that
# only literal-match `'offline'` undercount presence (PR-B migrated
# the three sites originally affected: composer-v2, keeper-utilities,
# quick-intervene).
#
# Exempt: lib/keeper-predicates.ts (canonical reader).
status_offline_classifier=$(
  rg -n \
    --type ts \
    -g '!dashboard/src/lib/keeper-predicates.ts' \
    -g '!dashboard/src/lib/keeper-predicates.test.ts' \
    '\([a-zA-Z_]+\.status\s*\)?\s*!==\s*[\x27"]offline[\x27"]' \
    dashboard/src 2>/dev/null || true
)
if [[ -n "$status_offline_classifier" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && violations+=("§9-6 status-only offline classifier:$line")
  done <<< "$status_offline_classifier"
fi

# Allowlist filter.
allowlist_lines=$(grep -vE '^\s*(#|$)' "$ALLOWLIST_FILE" || true)
unmatched_violations=()
# `${violations[@]:-}` guards against `set -u` failing when no signal
# matched (clean run) — bash treats an empty array as unbound otherwise.
for v in "${violations[@]:-}"; do
  [[ -z "$v" ]] && continue
  path_line=$(echo "$v" | sed -E 's/^§9-[0-9]+ [^:]+://' | cut -d: -f1,2)
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
      path_line=$(echo "$v" | sed -E 's/^§9-[0-9]+ [^:]+://' | cut -d: -f1,2)
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
  echo "RFC-0135 §9 SSOT guard — ${#unmatched_violations[@]} new violation(s):"
  for v in "${unmatched_violations[@]}"; do
    echo "  $v"
  done
  echo
  echo "If a violation is intentional and approved (rare), add the"
  echo "path:line to $ALLOWLIST_FILE with a comment explaining why."
  exit 1
fi

if (( ${#stale_allowlist[@]} > 0 )); then
  echo "RFC-0135 §9 SSOT guard — ${#stale_allowlist[@]} stale allowlist entry/entries:"
  for entry in "${stale_allowlist[@]}"; do
    echo "  $entry"
  done
  exit 2
fi

violations_count=${#violations[@]}
echo "RFC-0135 §9 SSOT guard: clean (${violations_count} allowlisted violation(s))"
exit 0
