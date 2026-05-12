# KTS R-9 — KeeperToolSurface.tla: ~16 `keeper_run_tools.ml:NNN` line-refs symbol-anchored (line-ref sweep cluster #2)

**Date**: 2026-05-12 · **Iteration**: 83 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (line-ref sweep, cluster #2)
**Spec**: `specs/keeper-state-machine/KeeperToolSurface.tla` (372 LOC, bug-model paired)
**OCaml**: `lib/keeper/keeper_run_tools.ml` — `compute_tool_surface` (the tool-surface construction pipeline, the function this spec models) · `lib/keeper/keeper_tool_disclosure.ml` — `contract_enforcement_filter`
**Verdict**: **~16 `keeper_run_tools.ml:NNN` line-range citations (lines 794-1011) all stale, symbol/stage-anchored comment-only**. `keeper_run_tools.ml` is ~1.7k LOC and the surface pipeline (`merged` → `required_tool_names` → `all_allowed` through fallback floor / last-turn safety / contract filter / max-tools truncation) all lives inside one function, `compute_tool_surface` (now at line 640). The spec cited the pipeline's *stages* by line range; those have drifted. Re-anchored each to `compute_tool_surface` + the stage's descriptive name (the convention for cases where the stage isn't a top-level `let`). Model body unchanged; TLC re-verified (clean = no error, 814 distinct states; buggy = `SafetyInvariant` violated).

## Why this cluster (line-ref sweep #2)

iter 81's corpus survey flagged KeeperToolSurface as the biggest remaining single-spec `\.ml:[0-9]` cluster (~16 hits vs. iter 82's 3-axis-trio at ~10 spread over 3 specs). This PR clears it.

## What drifted (sub-class 8: line-reference drift — single function, many stage refs)

The whole surface pipeline is the body of `compute_tool_surface` (`lib/keeper/keeper_run_tools.ml`, defined at line 640). The spec referenced stages by line range; here's the re-anchoring (line numbers were all in the 794-1011 band, the pipeline body):

| Spec stage | Old citation | New anchor |
|---|---|---|
| `pre_floor` (merged tools after overlay compose + validate) | `keeper_run_tools.ml:830-836` | `compute_tool_surface — merged-tools step (after overlay compose + validate)` |
| `floor_fired` (`tool_surface_fallback_used = true`) | `keeper_run_tools.ml:844-850` (×3, incl. inline) | `compute_tool_surface — fallback-floor conditional (sets tool_surface_fallback_used)` |
| `after_floor` (all_allowed post fallback floor) | `keeper_run_tools.ml:850` | `compute_tool_surface — all_allowed after the fallback floor` |
| `after_last_turn_safe` (`Intersect_with safe_last_turn_tools`) | `keeper_run_tools.ml:866-873` (×2) | `compute_tool_surface — Intersect_with safe_last_turn_tools step (when is_last_turn)` |
| `after_passive` (`contract_enforcement_filter` output) | `keeper_run_tools.ml:882-888` (×2) | `keeper_tool_disclosure.ml — contract_enforcement_filter (called from keeper_run_tools.ml's compute_tool_surface)` — *the filter is defined in `Keeper_tool_disclosure`, not `keeper_run_tools.ml`; the old `lib/keeper/keeper_run_tools.ml:882-888` cited the wrong file* |
| `emitted` / truncation (all_allowed final return) | `keeper_run_tools.ml:909-944` (×3) | `compute_tool_surface — max_tools-truncation step (essential / non_essential split)` |
| `required` (post-satisfaction required set) | `keeper_run_tools.ml:794-797` | `compute_tool_surface — outstanding_required_tool_names (post-satisfaction required set)` |
| classification near the return (tool_surface_class / lane / tool_requirement) | `keeper_run_tools.ml:949-973` | `compute_tool_surface — classification block near the return (tool_surface_class / lane / tool_requirement)` |
| validate gate + merged step | `keeper_run_tools.ml:805-806/830-836` | `compute_tool_surface — validate_allow_list gate + merged-tools step` |
| safe_last_turn_tools construction | `keeper_run_tools.ml:856-865` | `compute_tool_surface — safe_last_turn_tools construction` |
| returned tool_surface record (the "guard at the model-checking layer") | `keeper_run_tools.ml:998-1011` | `compute_tool_surface — returned tool_surface record` |

**Bonus correctness fix**: the `after_passive` rows cited `lib/keeper/keeper_run_tools.ml:882-888` for `contract_enforcement_filter` — but that function is in `Keeper_tool_disclosure` (`keeper_tool_disclosure.ml`); `keeper_run_tools.ml`'s `compute_tool_surface` only *calls* `Keeper_tool_disclosure.contract_enforcement_filter`. The new anchor names the right file.

Verification of current positions (`keeper_run_tools.ml`, 1725 LOC): `compute_tool_surface`@640; `merged`@792/825; `required_tool_names_raw`@799, `outstanding_required_tool_names`@807; `all_allowed`@842/856/878/894/915; `tool_surface_fallback_used` assignment@856-860; `safe_last_turn_tools`@877; `Keeper_tool_disclosure.contract_enforcement_filter` call@894-895; truncation `essential`/`non_essential`/`budget`@~945-953; `tool_surface_class`/`lane`/`tool_requirement`@~961-975; the returned record@~995-1010.

## Cross-checks (pass)

| Spec element | Runtime | Status |
|---|---|---|
| the surface pipeline (validate gate → fallback floor → last-turn safety → contract filter → max-tools cap) | `compute_tool_surface` in `keeper_run_tools.ml` (now line 640; stages at ~792-1010) | ✓ — symbol/stage anchors accurate |
| `contract_enforcement_filter` | `Keeper_tool_disclosure.contract_enforcement_filter` (defined in `keeper_tool_disclosure.ml`, called from `compute_tool_surface`) | ✓ — old citation pointed at the wrong file; fixed |
| `.cfg` / `-buggy.cfg` | both present | ✓ |
| Bug-Model contract | clean = no error (53580 states, 814 distinct); buggy = `SafetyInvariant` violated — re-verified this PR | ✓ |

## Sub-class placement & follow-up

- Drift = **sub-class 8 (line-reference drift)** — single-function variant: the pipeline is one big function (`compute_tool_surface`), so all ~16 refs anchor to it + a stage name. Convention for non-top-level stages (iter 64 N-2.a).
- **Remaining `\.ml:[0-9]` clusters** (from iter 81's survey): KeeperPostTurnOrchestration (`keeper_post_turn.ml:NNN`, ~8 hits — next), plus scattered singles (`keeper_unified_turn.ml:318/1640`, `keeper_state_machine.ml:402-408/754-758`, `keeper_social_model_magentic_ledger_v1.ml:204`, `keeper_composite_observer.ml:25-32`). After KeeperPostTurnOrchestration, only the scattered singles remain — at which point a `\.ml:[0-9]` zero-tolerance lint becomes a house-clean guard (iter 74 baseline-drain posture, not a "boost the classifier" workaround).
- No follow-up PR owed for *this* spec. Comment-only — model body byte-identical; `specs/INDEX.md` regenerated (KeeperToolSurface content-hash bump `0a1193720c81 → 16006c044ae8`). The spec is in the `make -C specs check-clean` runner; CI re-checks it.
