# Hardcoded / Heuristic Truth Audit - 2026-04-24

Scope: active `masc-mcp` source, tests, scripts, and CI surfaces. The goal is to
separate confirmed semantic debt from broad grep noise, then remove the most
dangerous hardcoded boundary.

## Current Findings

As of this branch, strict mode reports no confirmed active issue groups:

```bash
bash scripts/audit-hardcoding-truth.sh --fail-on-confirmed
# Confirmed active issue groups: 0
# Status: pass
```

Historical findings that shaped the audit are kept below so future changes can
avoid reintroducing the same stringly-typed or advisory truth paths.

### Fixed in this branch: main-worktree mutation boundary

`lib/keeper/keeper_tool_registry.ml` used to decide whether a mutating tool
should bypass the main-worktree boundary by matching concrete tool names. That
was a real drift risk: coordination aliases and keeper aliases could diverge
without compiler help.

This branch moves the decision to typed `Tool_catalog.effect_domain` metadata:

- `Read_only`
- `Masc_coordination`
- `Playground_write`
- `Main_worktree_write`

`Keeper_tool_registry.is_main_worktree_boundary_exempt_with_input` now delegates
to `Tool_catalog.is_main_worktree_boundary_exempt` after the existing input-aware
read-only checks.

### No longer confirmed by current audit: keeper agent affordance grouping

The previous `keeper_agent_run.ml` audit handles (`tool_required_affordances`,
`String.starts_with`, direct keeper/masc tool-name comparisons) no longer match
active source. Future affordance routing should keep using typed helpers and
catalog metadata instead of reintroducing local string grouping.

### No longer confirmed by current audit: provider label heuristics

The previous `provider_adapter.ml` audit handles (`prefix_classification_vocabulary`,
`bare_heuristic`, model-prefix provider guesses) no longer match active source.
Provider identity should remain metadata/capability-driven rather than inferred
from display labels.

### Fixed in this branch: advisory CI bug-class gates

`.github/workflows/ci.yml` now runs the meta bug-class gates as blocking checks:
the `Meta bug-class gates (SSOT, SIL, STR, BND)` step no longer has
`continue-on-error: true`, individual gate commands no longer use `|| true`, and
`scripts/audit-hardcoding-truth.sh` runs with `--fail-on-confirmed`.

`scripts/audit-hardcoding-truth.sh` now scopes this check to the meta gate block
instead of matching unrelated advisory summary steps elsewhere in CI.

### Improved: anti-fake detector noise

`scripts/anti-fake-audit.sh` now recognizes common Alcotest forms such as
unqualified `check bool` and classifies CLI/distributed harness files separately
from fake tests. This reduces false positives where real assertions were hidden
behind OCaml open/module style rather than the exact `Alcotest.` string.

## New Audit Surface

Run:

```bash
bash scripts/audit-hardcoding-truth.sh
```

Optional strict mode:

```bash
bash scripts/audit-hardcoding-truth.sh --fail-on-confirmed
```

The default mode is non-blocking for local exploration. CI uses strict mode so
confirmed hardcoding/truth debt blocks the meta gate.

## Verification

Executed for the current strict-gate branch:

```bash
bash scripts/ci/check-silent-failure-patterns.sh
# SIL gate: PASS (no critical silent failures detected)

bash scripts/ci/check-masc-oas-boundary.sh
# BND gate: PASS

bash scripts/audit-hardcoding-truth.sh --fail-on-confirmed
# Confirmed active issue groups: 0
# Status: pass

env MASC_DUNE_THROTTLE=0 DUNE_BUILD_DIR=... DUNE_JOBS=1 \
  scripts/dune-local.sh build ./test/test_board_dispatch.exe
# PASS

env -u MASC_BASE_PATH_INPUT MASC_BASE_PATH=/tmp/masc-hardcoding-gate-board-test \
  _build-hardcoding-gate/default/test/test_board_dispatch.exe
# PASS, 27 tests
```
