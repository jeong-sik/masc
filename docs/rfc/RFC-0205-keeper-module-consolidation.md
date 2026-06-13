---
title: Keeper Module Consolidation — Eliminate Facade Anti-Pattern
rfc: 0205
status: Draft
created: 2026-05-29
author: jeong-sik (with Claude Opus 4.8)
related:
  - RFC-0088 string-classifier-audit (anti-pattern precedent)
  - RFC-0133 keeper-phase-casing-SSOT (partial consolidation)
  - RFC-0204 dashboard-serving-isolation (module count as perf contributor)
---

# RFC-0205 — Keeper Module Consolidation: Eliminate the Facade Anti-Pattern

## 1. Problem

The keeper/ subsystem has **454 .ml files** and **439 .mli files**. This
over-fragmentation produces a secondary pathology: **facade modules** that
exist only to re-export types from other modules. The "SSOT facade" PR batch
(#19285, #19286, #19291, #19292, #19293 open; #19295, #19296, #19297 merged)
treats the symptom (manual type redeclaration) by replacing it with `include
module type of struct include X end` chains — but does not address *why*
types need re-exporting in the first place.

### 1.1 Measured Scope

| Metric | Value |
|--------|-------|
| keeper/ .ml files | 454 |
| keeper/ .mli files | 439 |
| `include module type of` in keeper/ .mli | 19 files |
| `include module type of` across all lib/ | 71 files |
| `type t` defined in multiple keeper .ml | 73 distinct modules |
| `keeper_registry_types*.mli` variants | 6 files |
| "SSOT facade" PRs (one batch) | 9 total (5 open, 4 merged) |
| `keeper_types.mli` re-declared types | 22 (16 via alias, 6 own) |
| `registry_types.mli` lines | 704 (proposed → 180) |

### 1.2 Root Cause: Over-Modularization

Each module in OCaml carries a `.ml`/`.mli` pair. When a subsystem is split
into 454 modules:

1. Types fragment across many small modules
2. Consumers need types from multiple modules simultaneously
3. Facade modules emerge as "convenience" aggregators
4. Facades must re-declare or `include` types from sub-modules
5. Include chains deepen (`A includes B which includes C...`)
6. Each facade PR begets more facade PRs — the user observed this as
   "무한정 같은 타입이 나올 거 같은데" (infinite same types)

**The "SSOT facade" PRs are the anti-pattern's immune response, not a cure.**

### 1.3 Concrete Harm

1. **Discoverability**: To find where `compaction_policy` is *actually*
   defined, one must trace `keeper_types.mli → Keeper_meta_contract → ???`.
   `include` chains obscure ownership.

2. **Compilation cost**: Each `include module type of struct include X end`
   forces the compiler to materialize the full signature of X inline. 71 such
   sites add measurable compilation overhead.

3. **Type t explosion**: 73 modules each define their own `type t`. This is
   the OCaml convention for "the main type of this module" — but when 73
   modules exist, the convention loses meaning. Every module is "main" for
   something trivial.

4. **PR sprawl**: 9 mechanical PRs to replace manual redeclarations with
   `include`. Review cost scales linearly. Each PR is correct in isolation
   but collectively they deepen the include tangle.

5. **Grep opacity**: `rg "type compaction_policy" lib/` returns hits in
   multiple .mli files (aliases) and one .ml file (owner). The aliases add
   noise and make type ownership unclear.

## 2. Proposed Solution

### 2.1 Principle: Qualified Access Over Re-Export

**Remove facade modules. Require qualified access.**

Instead of:
```ocaml
(* keeper_types.mli — facade that re-exports everything *)
type compaction_policy = Keeper_meta_contract.compaction_policy = { ... }
type keeper_meta = Keeper_meta_contract.keeper_meta = { ... }
```

Require consumers to write:
```ocaml
let policy : Keeper_meta_contract.compaction_policy = ...
let meta : Keeper_meta_contract.keeper_meta = ...
```

This is more verbose but makes ownership explicit at every use site.
The compiler still type-checks identically.

### 2.2 Consolidation Targets

#### Phase 1: Delete Facade .mli Files (Mechanical)

Delete or gut the following facade .mli files. Each currently contains
zero or near-zero own type definitions — pure re-export:

| File | Types re-exported | Own types | Action |
|------|-------------------|-----------|--------|
| `keeper_types.mli` | 16+ | 6 | Delete re-exports; keep own types in-place or move to owner |
| `registry_types.mli` | 40+ | ~7 | Same |
| `registry_types_runtime.mli` | ~17 | ~0 | Delete entirely |
| `registry_types_decision.mli` | ~8 | ~0 | Delete entirely |
| `registry_types_turn_phase.mli` | ~8 | ~0 | Delete entirely |
| `dashboard_goals_types.mli` | — | — | Same pattern (PR #19274) |

After deletion, any consumer that used unqualified `compaction_policy` must
use `Keeper_meta_contract.compaction_policy`. The compiler enforces this
migration — every broken reference is a compile error, zero silent failures.

**Migration method**: `dune build --root .` after each deletion. Every error
is a site that needs qualified access. Mechanical, verifiable, no guesswork.

#### Phase 2: Merge Micro-Modules (Architectural)

Many modules exist as single-type wrappers:

```
keeper_id.ml              → type t = string
keeper_container_name.ml  → type t = string
keeper_cwd_response.ml    → type t = ...
keeper_turn_terminal.ml   → type t = ...
...
```

73 such modules define nothing but `type t` and maybe 1-2 functions.
Consolidate related single-type modules into cohesive groups:

| New Module | Absorbs | Rationale |
|------------|---------|-----------|
| `keeper_identity` | `keeper_id`, `keeper_container_name`, `keeper_workspace_op` | Identity & workspace |
| `keeper_turn_types` | `keeper_turn_terminal`, `keeper_turn_terminal_code`, `keeper_turn_disposition` | Turn lifecycle types |
| `keeper_registry_types` | 6 `keeper_registry_types_*.ml` files | Undo the split that created 6 files for one namespace |
| `keeper_failure_types` | `keeper_*_failure_site.ml` (~12 files) | Failure classification variants |

Target: reduce keeper/ from **454** to **~300** modules. Still large, but
each file should have >50 lines of meaningful logic (not just `type t = ...`).

#### Phase 3: Enforce Module Size Floor (CI)

Add a CI check that rejects new files under 30 lines (excluding .mli) in
keeper/. This prevents re-fragmentation:

```bash
# scripts/check-module-min-size.sh
find lib/keeper -name '*.ml' | while read f; do
  lines=$(wc -l < "$f")
  if [ "$lines" -lt 30 ]; then
    echo "FAIL: $f has $lines lines (minimum 30)"
    exit 1
  fi
done
```

### 2.3 What About the 5 Open Facade PRs?

**Close them.** They implement the wrong solution (include chains) to the
right observation (type duplication). This RFC replaces them with a
fundamentally different approach (delete facades, require qualified access).

| PR | Action | Reason |
|----|--------|--------|
| #19285 | Close | `keeper_types.mli` facade deleted entirely |
| #19286 | Close | `registry_types.mli` facade deleted entirely |
| #19291 | Close | `keeper_state_machine.mli` facade deleted |
| #19292 | Close | `keeper_execution_receipt.mli` facade deleted |
| #19293 | Close | `keeper_failure_circuit_breaker.mli` merged into owner |

The 4 already-merged PRs (#19295, #19296, #19297, #19274) created include
chains. Phase 1 will remove those chains when the facade files are gutted.
No revert needed — we just delete the includes and their contents.

## 3. Implementation Plan

### Phase 1 — Delete Facades (Mechanical, ~2 hours)

```
1. Delete facade .mli files (or gut to empty)
2. dune build --root . — fix every compile error with qualified access
3. dune runtest — verify no test regressions
4. Single PR per logical group (keeper_types, registry_types, etc.)
```

Compile errors are the migration guide. Every broken reference is a call
site that needs `Module.type` qualification. OCaml's exhaustiveness checking
guarantees zero silent breakage.

### Phase 2 — Merge Micro-Modules (~4 hours)

```
1. Identify single-type modules via: find lib/keeper -name '*.ml' -exec sh -c 'lines=$(wc -l < "$1"); [ "$lines" -lt 50 ] && echo "$lines $1"' _ {} \;
2. Group by domain affinity
3. For each group: create merged module, move definitions, update all references
4. dune build + dune runtest after each group
5. One PR per group
```

### Phase 3 — CI Guard (~30 min)

```
1. Add scripts/check-module-min-size.sh
2. Wire into CI (dune build or separate step)
3. PR
```

### Total Estimated Effort

| Phase | Time | PRs | LoC Impact |
|-------|------|-----|------------|
| Phase 1 | 2h | 2-3 | -500 to -1000 (deleted facade .mli content) |
| Phase 2 | 4h | 3-5 | Net ~-2000 (merged files) |
| Phase 3 | 30m | 1 | +30 |

## 4. Alternatives Considered

### A. Keep Facades, Use `include` (Current PR Approach)

Rejected. Include chains deepen the tangle. Each new sub-module requires
updating the facade. The facade .mli is never the source of truth — it's
always derived, always stale-risk.

### B. Module Types (Signatures) as Interfaces

Define `.sig` files that describe interfaces, let each module implement them.
Rejected for OCaml: `.mli` already serves this role. Adding explicit
`.sig` duplicates the existing mechanism without solving the fragmentation.

### C. Qualified Access Only (This RFC)

Chosen. Forces explicit ownership at every use site. Compile errors guide
migration. No hidden include chains. Grep reveals true ownership.

## 5. Risks

| Risk | Mitigation |
|------|------------|
| Verbosity — longer qualified names | OCaml supports `open Keeper_meta_contract` locally; verbosity is the price of clarity |
| Large migration surface (many compile errors) | Compiler-guided: each error is one fix. No guesswork. |
| Merge conflicts with other PRs | Phase 1 is mechanical; rebase-friendly |
| Reduced "convenience" for dashboard/operators | These consumers can `open` the specific module they need |

## 6. Success Criteria

1. Zero `include module type of struct include ... end` patterns in keeper/
2. keeper/ module count < 320 (from 454)
3. Every type has exactly one definition site, visible via `rg "^type foo" lib/`
4. All existing tests pass without modification to assertions
5. CI build time does not increase (should decrease from fewer include expansions)

## 7. Open Questions

1. ** keeper_registry_types_*.ml split** — The 6-file split was intentional
   (separate concerns: runtime, decision, turn_phase). Should we merge all
   6 back into one `keeper_registry_types.ml`, or keep 2-3?

2. **`type t` convention** — 73 modules use `type t`. Should we enforce
   descriptive names (e.g., `type id` instead of `type t` in `keeper_id.ml`)?
   This would improve grep-ability but break OCaml convention.

3. **Other subsystems** — workspace/, types/, dashboard/ have similar patterns
   (71 total include sites). Should this RFC scope cover them, or follow up?
