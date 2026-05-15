---
rfc: "0085"
title: "Keeper namespace bulk promotion to sub-library"
status: Draft
created: 2026-05-15
updated: 2026-05-15
author: vincent
supersedes: []
superseded_by: null
related: ["0056", "0042", "0050"]
implementation_prs: []
---

# RFC-0085 — Keeper namespace bulk promotion to sub-library

> Companion to RFC-0056. RFC-0056 enumerated *incremental* leaf extraction
> (1A trajectory → 1K compaction_trigger, 11 phases shipped). This RFC
> evaluates whether the **remaining ~244 modules in `lib/keeper/`** should
> be promoted to a single sub-library `masc_mcp.keeper` in one PR, instead
> of continuing leaf-by-leaf sweep. Recommendation: **Option B with
> prerequisite rename PR (Phase 2.A)** — bulk extraction is feasible but
> blocked by 38 collision-risk filenames that lack the `keeper_` prefix.

## 1. Why now

RFC-0056 Phase 1A–1K shipped 11 leaf sub-libraries, but `lib/keeper/`
still holds **250 `.ml` files / 98,483 LoC**, including all 6 top
godfiles (3034 → 2086 LoC). At the current leaf-sweep rate (~3 leaves /
week), full namespace extraction would take **>80 weeks**. Each leaf PR
also costs human review attention disproportionate to the LoC moved,
since each touches `lib/dune`, `test/deps/dune`, and a wrapped-pattern
sed.

Track A research (`knowledge/research/2026-05-15-ocaml-large-system-decomposition-patterns.md`)
identifies the **Tezos `lib_*/` pattern** as the gold standard for
per-subsystem partitioning at 200+ KLoC. Bulk promotion converts our
biggest namespace to that shape in one PR.

The strategic question this RFC answers: is bulk promotion safer than
leaf sweep, and what blocks it?

## 2. Measurements (2026-05-15)

All numbers are direct `rg` / `wc -l` against working tree at
`origin/main` (3ac70942af, after PR-0j #15463 / before PR-0k #15464
merge — measurements re-validated post-merge on this RFC's branch).

### 2.1 lib/keeper/ size

| Metric | Value |
|---|---|
| `.ml` files | 250 |
| `.mli` files | 249 |
| Total LoC (`.ml` only) | 98,483 |
| Top file: `keeper_registry.ml` | 3,034 |
| Top 6 godfiles combined | 14,547 |
| P50 LoC (estimated, sampled) | ≈400 |
| P95 LoC (estimated, sampled) | ≈1,900 |

### 2.2 External fan-in (callers of `Keeper_*` from outside `lib/keeper/`)

| Caller location | Files referencing `Keeper_*` |
|---|---|
| `lib/` (excluding `lib/keeper/`) | 248 |
| `bin/` + `test/` | 335 |
| **Total external callers** | **583** |

Most-referenced keeper modules (top 10, code + OCamldoc combined; counted
with `xargs rg -oI '\bKeeper_[a-z_]+'`):

| Count | Module | Notes |
|------:|---|---|
| 292 | `Keeper_types` | facade |
| 290 | `Keeper_metrics` | Prometheus metric names |
| 110 | `Keeper_cascade_profile` | cascade runtime name type |
| 105 | `Keeper_registry` | godfile, 3034 LoC |
| 98 | `Keeper_runtime_manifest` | per-keeper config |
| 44 | `Keeper_internal` | internal helpers |
| 37 | `Keeper_turn_driver` | turn lifecycle |
| 35 | `Keeper_state_machine` | FSM |
| 34 | `Keeper_id` | typed identifiers |
| 34 | `Keeper_approval_queue` | approval state |

Heavy code-vs-OCamldoc breakdown was not done at file granularity for
this RFC — sampling showed mixed usage (admission_queue: real code refs;
prometheus.ml: comment-only refs). For Option B feasibility the
distinction does not matter (see §3.B).

### 2.3 Filename prefix audit (collision risk for `(wrapped false)`)

The cdal / trajectory / host_config etc. precedent uses
`(wrapped false)`. Under that pattern, all .ml filenames become
top-level modules — `keeper_X.ml` ⇒ `Keeper_X` (visible everywhere).

Of 250 `.ml` files in `lib/keeper/`, **38 lack the `keeper_` prefix**:

```
alert_persist_kind.ml                    chat_store_operation.ml
approval_queue_failure_site.ml           checkpoint_failure_operation.ml
bookkeeping_failure_kind.ml              checkpoint_store_failure_site.ml
cascade_sync_failure_site.ml             compact_audit_failure_site.ml
crash_persistence_failure_site.ml        credential_provider.ml
docker_client.ml                         docker_client_mock.ml
docker_client_real.ml                    docker_response.ml
event_bus_drain_site.ml                  execution_receipt_failure_site.ml
fs_failure_site.ml                       generation_lineage_failure_site.ml
heartbeat_smart.ml                       host_config_provider.ml
in_container_login_provider.ml           metric_emit_dropped_site.ml
metrics_sse_failure_kind.ml              oas_execution_error_phase.ml
observation_query_operation.ml           operator_compact_result.ml
paused_state_persist_phase.ml            post_turn_wirein_failure_site.ml
profile_load_failure_site.ml             sandbox_executor.ml
sandbox_session_executor.ml              supervisor_cleanup_failure_site.ml
tool_policy_failure_site.ml              tool_resolution.ml
turn_cleanup_failure_site.ml             turn_metrics_snapshot_failure_site.ml
turn_up_update_failure_site.ml           write_meta_cycle_failure_site.ml
```

These files generate top-level modules like `Docker_client`,
`Credential_provider`, `Heartbeat_smart`, `Sandbox_executor`,
`Tool_resolution`, `Host_config_provider` — names that **plausibly
collide** with sibling sub-libraries (`Host_config` already exists as
its own sub-lib per PR-0c). Dune docs §library.html quoted in Track A
say: "Never use `(wrapped false)` when library has filenames likely to
collide (`Types`, `Utils`, `Error`, `Config`)."

Sub-classification of the 38:

| Group | Count | Pattern | Mitigation |
|---|---|---|---|
| `*_failure_site.ml` / `*_failure_kind.ml` | ~15 | typed closed-sum errors (RFC-0042 lineage) | Rename to `keeper_*_failure_site.ml` OR move to dedicated typed-error sub-lib |
| `docker_*.ml` (4 files) | 4 | Docker driver | Rename `keeper_docker_*` or move to `lib/keeper_sandbox_docker/` |
| `sandbox_*.ml`, `credential_*.ml`, `host_config_*.ml`, `in_container_login_provider.ml` | 5 | runtime providers | Rename with `keeper_` prefix |
| `heartbeat_smart.ml`, `tool_resolution.ml`, `operator_compact_result.ml` | 3 | keeper-internal helpers | Rename |
| `*_operation.ml`, `*_phase.ml` | ~5 | typed state/operation kinds | Rename |
| residue | ~6 | misc | Rename |

## 3. Option comparison

### 3.A. Continue leaf sweep (status quo)

**Mechanism**: Identify next safe leaf, extract one at a time per
RFC-0056 Phase 1A–1K pattern.

| Pros | Cons |
|---|---|
| Low blast radius per PR (~100-700 LoC moved) | At 3 leaves / week, 244 modules → 80+ weeks |
| Each PR independently revertible | Reviewer fatigue: 11 PRs already, value-per-PR declining |
| No filename rename needed | Stops short of solving godfile problem (top 6 are mesh-coupled, never appear as leaves) |
| Established pattern, low risk | Strategic outcome unclear — no clean `lib/keeper/` boundary at end |

**Verdict**: Mechanical safety, strategic dead end. Useful only as
warm-up for Options B/C.

### 3.B. Bulk promotion with `(wrapped false)`

**Mechanism**: Add `lib/keeper/dune` with a single `(library)` stanza
using `(wrapped false)`. Dune auto-excludes the subdir from parent
`lib/dune`'s `(include_subdirs unqualified)`. Parent adds
`masc_mcp.keeper` to its `(libraries …)` list. Tests add
`(re_export masc_mcp.keeper)` to `test/deps/dune`.

**Caller delta**: `Keeper_X` ⇒ `Keeper_X` (zero change, 248 + 335 = 583
files untouched). Because `(wrapped false)` keeps bare top-level module
names, all existing references resolve transitively through the new
library boundary.

**Internal cycle handling**: 247 modules inside keep all their internal
references unchanged (sub-lib internal cycles are dune-allowed; only
*inter-library* cycles are forbidden).

**Block 1 — Collision risk (38 files, §2.3)**: Top-level names like
`Docker_client`, `Credential_provider`, `Sandbox_executor` would leak
into the global namespace. Dune build *might* succeed depending on
whether any other library publishes those same module names today —
but the safety margin is zero. New sibling libraries (future
`lib/keeper_sandbox/`) would immediately collide.

**Block 2 — Boundary discipline**: Without `.mli` enforcement, the
247-module flat namespace inside the sub-library reproduces the same
"barrel of bricks" anti-pattern (Track A §3). LoC moves but cohesion
doesn't.

| Pros | Cons |
|---|---|
| Zero caller change (583 files untouched) | Collision risk for 38 non-prefix files (block 1) |
| Single PR, one human review session | Inside the sub-lib, mesh complexity unchanged |
| Establishes real `(library)` boundary | Doesn't address P95 godfile LoC at all |
| Prerequisite for Track A Strategy #1, #5 | Cannot use `(wrapped true)` retrofit later without 583-file rewrite |

**Phase 2.A prerequisite (required to unblock Option B)**: Rename 38
files to use `keeper_*` prefix. This is mechanical: `git mv old.ml
keeper_old.ml`, update internal `Old_module.X` references to
`Keeper_old_module.X` (these stay inside `lib/keeper/`, so the rename
is contained). External callers untouched only if any of the 38 are
referenced from outside lib/keeper/ — needs per-file audit before the
rename PR.

### 3.C. `(include_subdirs qualified)` namespace migration

**Mechanism**: Dune 3.7+ feature. Convert `lib/dune` from
`(include_subdirs unqualified)` to `(include_subdirs qualified)`.
Subdirectory names become module path prefixes. `lib/keeper/foo.ml`
becomes `Masc_mcp.Keeper.Foo` (qualified path) instead of bare `Foo`.

**Caller delta**: All 583 files referencing `Keeper_X` would resolve
*differently* — `Keeper_X` (a top-level module today) becomes
`Masc_mcp.Keeper.Keeper_X` or with `-open` `Keeper.Keeper_X`. The
existing keeper_ prefix would actually become *redundant*
(`Keeper.Keeper_X` is awkward).

**Block**: This pattern works best with **directory-named modules**
(i.e., `lib/keeper/foo.ml` → `Keeper.Foo` not `Keeper.Keeper_foo`).
Adopting requires renaming all 247 keeper_-prefixed files to drop the
prefix — same scale as Phase 2.A but inverse. Plus all 583 callers
must update.

| Pros | Cons |
|---|---|
| No new dune library; clean namespace | All 247 keeper files renamed AND 583 callers updated |
| Future-proof — `qualified` is the post-2023 norm | Massive PR, hard to review |
| Removes prefix redundancy (`Keeper.Foo` ⊃ `Keeper.Keeper_foo`) | No real sub-lib boundary — same monolith, just qualified |

**Verdict**: Costlier than Option B, less benefit (no sub-lib boundary).
Defer indefinitely; revisit only when ecosystem moves.

### 3.D. Tezos `lib_*/` with `(wrapped true) + -open`

**Mechanism**: `lib/keeper/dune` with `(library (name masc_mcp_keeper)
(wrapped true))`. Modules become `Masc_mcp_keeper.Keeper_X`. Parent
`lib/dune` adds `(flags (:standard -open Masc_mcp_keeper))` so internal
references resolve `Keeper_X` ⇒ `Masc_mcp_keeper.Keeper_X` transparently.
External `bin/` and `test/` need similar `-open` or qualified refs.

**Caller delta**: With `-open` everywhere, zero caller change like
Option B. Without `-open`, all 583 callers need qualified refs.

| Pros | Cons |
|---|---|
| Official Dune-recommended pattern (Track A §3) | `-open` proliferation has its own complaints (Tezos community) |
| No collision risk regardless of filenames | More dune knobs to maintain |
| Future-proof for opam packaging | `-open` masks where names come from (anti-readability) |

**Verdict**: Strictly better than Option B *if* we accept the
ergonomic cost of `-open`. **Track A §6 recommends this as Wave D
separately** — not bundled into bulk promotion. Reason: Tezos
migration (Phase 2.A rename + dune library + -open flag) compounds
risk in one PR.

### 3.E. Mesh decomposition (Track A §6 Strategy #5)

Out of scope here — covered separately as RFC-0056 follow-on phases.
Bulk namespace promotion (this RFC) is **orthogonal** to mesh
decomposition: it creates the library boundary; mesh work happens
*inside* the boundary, PR by PR, without further parent-lib coupling.

## 4. Recommendation

**Sequence the bulk move as two PRs**:

| PR | Phase | Scope | Approximate cost |
|---|---|---|---|
| **PR-A** | 2.A — rename | 38 `*.ml` files in `lib/keeper/` to `keeper_*` prefix; internal-only ref updates. **Skip files referenced from outside `lib/keeper/`** (per-file audit) — these get individual rename PRs or `(wrapped false)` exception list. | 38 git mv, ≤150 internal ref-sed lines |
| **PR-B** | 2.B — promote | `lib/keeper/dune` new `(library)` stanza with `(wrapped false)`; parent `lib/dune` removes implicit keeper inclusion + adds `masc_mcp.keeper` dep; `test/deps/dune` re_export | ~10 dune edits, 0 caller updates |

After both merge: `lib/keeper/` is a real sub-library. Mesh
decomposition (Strategies #1, #5, #6 from Track A) resumes as RFC-0056
Phase 3+ PRs, each scoped within the new boundary.

**Why not Option D (`(wrapped true)` + `-open`) right now**: defer to
Wave D RFC after Phase 2 stabilizes. Justifications:

1. Single change-set risk: combining filename renames, library
   creation, `-open` flag distribution, and 583-caller verification in
   one or two PRs maximizes blast radius. Phase 2 closes the **easy**
   half (boundary). Wave D closes the **typed half** (namespace).
2. `(wrapped false)` is internally consistent with cdal, trajectory,
   host_config, briefing_compactors, dashboard_eval_feed, memory_jsonl,
   chronicle_event, tool_call_quality_benchmark, keeper_event_queue,
   keeper_invariant, compaction_trigger — 11 precedent sub-libraries.
   Switching keeper alone to `(wrapped true)` introduces inconsistency.
3. Wave D RFC can then sweep **all 12** sub-libraries to `(wrapped true)
   + -open` consistently, with a single migration script and one
   reviewer round.

## 5. Why this isn't a workaround (CLAUDE.md `software-development.md` §워크어라운드 거부 기준)

PR pre-check against the 3 anti-pattern signatures:

| Signature | Applies? | Why not |
|---|---|---|
| Telemetry-as-fix | No | This RFC *moves boundary*, not "instruments failure". Library promotion is structural. |
| String/substring classifier reinforcement | No | No string matching involved; pure type/module boundary. |
| N-of-M patch | No | Phase 2.B is *one* PR for the whole sub-lib — opposite of N-of-M. Phase 2.A renames are mechanical, *not* the same as RFC-0050 §6 anti-pattern (multiple PRs each shipping a small batch). |

PR rejection checklist (7 items): all pass.

The 38-file rename PR is **prerequisite root-fix**, not a Phase 2.B
deferral. Per `feedback_hardcoding_and_legacy_zero_tolerance` (2026-05-14):
"root-fix PR 같은 머지에서 legacy 함께 삭제" — Phase 2.A *is* the
root-fix for filename inconsistency. Phase 2.B builds on top.

## 6. Open questions

| # | Question | Resolution path |
|---|---|---|
| 1 | Are any of the 38 non-prefix files referenced from *outside* `lib/keeper/`? | Audit `rg -l 'Docker_client\\|Credential_provider\\|Sandbox_executor\\|…'  lib/ bin/ test/` per filename. If yes, that file becomes its own mini-PR (Phase 2.A.i, …) before bulk rename. |
| 2 | Are there internal cycles in `lib/keeper/` that *only* break under `(wrapped false)` sub-library boundary? | `dune build @check` is the oracle. If cycle, revert Phase 2.B and isolate the cyclic cluster as separate sub-lib (Track A §2 closure bundle). |
| 3 | Should `*_failure_site.ml` / `*_failure_kind.ml` (~15 files) be moved to dedicated `lib/keeper_typed_errors/` sub-lib instead of renamed in place? | Defer to RFC-0042 follow-on. Phase 2.A renames them with `keeper_` prefix as the conservative move — future RFC can extract. |
| 4 | Filename consistency invariant for new keeper_* files: enforce via lint? | Out of scope; consider in Wave D after `(wrapped true)` migration makes prefix redundant. |
| 5 | Wave D timing (Tezos `(wrapped true) + -open` for all 12 sub-libraries)? | After Phase 2 stabilizes 2+ weeks. Wave D RFC tracks the 12-sub-lib uniform migration. |

## 7. Evidence Record

| # | Claim | Evidence | Confidence | Delta |
|---|---|---|---|---|
| 1 | 250 `.ml` files in `lib/keeper/`, 98,483 LoC total | `find lib/keeper -name '*.ml' \| wc -l` and `xargs wc -l` (executed 2026-05-15) | High | Direct measurement |
| 2 | 248 lib/ files outside lib/keeper/ reference `Keeper_*` | `rg -l 'Keeper_' lib/ \| grep -v '^lib/keeper/' \| wc -l` (executed 2026-05-15) | High | Includes both code refs and OCamldoc — both block / are unaffected uniformly under Option B |
| 3 | 335 bin/ + test/ files reference `Keeper_*` | `rg -l 'Keeper_' bin/ test/ \| wc -l` (executed 2026-05-15) | High | Same as #2 |
| 4 | 38 of 250 files lack `keeper_` prefix | `find lib/keeper -name '*.ml' -exec basename {} \; \| grep -v '^keeper_' \| wc -l` (executed 2026-05-15) | High | Enumerated in §2.3 |
| 5 | Tezos uses per-subsystem `lib_*` partitioning at 200+ KLoC | `https://github.com/tezos/tezos/tree/master/src` (25 lib_*/ directories) — Track A §1.5 | High | Same source as RFC-0056 Phase 0 |
| 6 | `(wrapped false)` officially discouraged for >50-module libs | `https://dune.readthedocs.io/en/stable/reference/dune/library.html` — Track A §3 | High | Mitigated by §2.3 prefix audit + Phase 2.A rename |
| 7 | Async_kernel `Types` module is the canonical mesh-decoupling tool | `https://discuss.ocaml.org/t/cyclic-dependencies-and-modular-design/3670` — Track A claim #10 | Medium | Cited as reference, not used in this RFC (mesh decomposition is RFC-0056 Phase 3+) |
| 8 | `(include_subdirs qualified)` introduced in Dune 3.7+ | `https://dune.readthedocs.io/en/stable/reference/dune/include_subdirs.html` — Track A §5 #4 | Medium | Option C path; rejected here as costlier than Option B |
| 9 | Workaround rejection checklist 7 items pass | `~/me/instructions/software-development.md` §워크어라운드 거부 기준 — manual check §5 | High | Self-audit; no AI-agent override needed |

## 8. Implementation plan (Phase 2.A first)

When this RFC reaches Active status (user-approved direction), a separate
PR will implement Phase 2.A:

1. Per-file audit of the 38 non-keeper_ files: `rg -l '\bDocker_client\b' lib/ bin/ test/` for each. Group into:
   - **Internal only** (callers all inside lib/keeper/): batch rename in one commit.
   - **External callers** (≥1 file outside lib/keeper/): individual PR with caller updates.
2. `git mv` + `sed -i` for internal Module name updates within lib/keeper/.
3. `dune build @check` + `dune runtest` green locally.
4. Single commit per logical group (e.g., "rename: `*_failure_site` → `keeper_*_failure_site` (15 files)").
5. Self-review against RFC-0056 G1–G5 gates.
6. Draft PR → CI green → `human-approved-ready` → Ready.

Phase 2.B (this RFC's main deliverable) follows after Phase 2.A merges
and main is verified green.

## 9. Non-goals

- Mesh decomposition of `keeper_registry.ml` (3034 LoC), `keeper_unified_turn.ml` (3020), `keeper_hooks_oas.ml` (2762), `keeper_supervisor.ml` (2645): RFC-0056 Phase 3+, requires `_intf.ml` triangulation per Track A §2.
- Tezos `(wrapped true) + -open` migration: Wave D RFC, follow-up after Phase 2.B stabilizes.
- LoC cap CI enforcement: RFC-0050 §2 rejected this; consistent rejection here.
- `keeper_typed_errors/` sub-extraction: deferred to RFC-0042 follow-on.

## 10. Related work

- **RFC-0056**: Incremental sub-library extraction (Phase 0 cdal + Phase 1A–1K leaves). This RFC is the strategic successor for the keeper namespace specifically.
- **RFC-0042**: Closed sum type for keeper turn terminal code. The `*_failure_site` / `*_failure_kind` modules under Phase 2.A audit are RFC-0042 lineage.
- **RFC-0050**: Dashboard component ownership decomposition. Same anti-LoC-cap stance; same workaround rejection bar.
- **Track A research**: `knowledge/research/2026-05-15-ocaml-large-system-decomposition-patterns.md` (worktree-resident; merge-bound).
- **MEMORY**: `feedback_hardcoding_and_legacy_zero_tolerance` (2026-05-14), `feedback_extraction_audit_must_grep_both_bare_and_wrapped`.
