# KAL K-1 — KeeperAdmissionLiveness spec ↔ OCaml mapping (audit)

**Iteration**: /loop iter 56 — first entry to Phase K (`KeeperAdmissionLiveness.tla`).
**Date**: 2026-05-12.
**Scope**: audit-only. No spec or OCaml mutation in this PR. Findings catalogued for downstream `K-2`/`K-3` fix-PR candidates.
**RFC reference**: RFC-0026 Work-Conserving Keeper Admission (admission spec is the design ground for the dormant runtime).

## Why this audit exists

Six iterations into the loop the FSM-side specs (KSM, KTC, KCR, KCAF, KCL, KCtxL, KMC) have been worked over; admission has been deferred because the matching OCaml is *dormant*. Memory note (`reference_masc_mcp_integrated_improvement_design_audit.md`, 2026-05-05) explicitly flags `RFC-0026 PR-E-1.6 wiring pending` — admission modules sit in `main` but `keeper_heartbeat_loop.ml` only takes the new code path when `MASC_ADMISSION_USE_NEW=1` is set in the process environment. Without this audit, future contributors to admission would re-derive the spec/OCaml correspondence from scratch every time the dormancy was lifted.

This memo is the snapshot before any activation. It does two things:
1. Catalogues which spec action maps to which OCaml function so the *next* PR that lifts dormancy has a checklist.
2. Calls out the four drift risks visible at the boundary today, with recommended follow-up RFC names.

## Spec surface

`specs/keeper-state-machine/KeeperAdmissionLiveness.tla` (387 LOC):

| Element | Count | Where |
|---------|-------|-------|
| State enum | 5 | `keeper_state ∈ {"Idle", "Waiting", "Dispatched", "Working", "Done"}` |
| Actions | 7 | `StartTurn`, `TryDispatch(k,p)`, `EnqueueOverflow`, `RefillToken(p)`, `WakeFromQueue`, `StartWork`, `CompleteWork` |
| Safety invariants | 5 | `TypeOK`, `RateRespect` (I3), `TokensInRange`, `QueueWellFormed`, `WorkConserving` (I2 step form) |
| Liveness | 1 | `LivenessInvariant` (I1) under strong fairness on `TryDispatch` |
| Bug models | 2 | `KeeperAdmissionLiveness-buggy.cfg`, `…-buggy-2.cfg` (counter-example fixtures) |

## OCaml surface

`lib/keeper/` (845 LOC across 7 modules):

| Module | LOC | Role |
|--------|-----|------|
| `keeper_provider_token_bucket.ml` | 103 | Per-provider token bucket; `try_acquire`, `release`, `refill_locked` (lazy), `add_on_refill`/`fire_on_refill_callbacks` |
| `keeper_wfq_overflow.ml` | 94 | Weighted-fair-queueing overflow heap; `enqueue`, `wake_one`, deficit accounting |
| `keeper_admission_policy.ml` | 139 | Decision logic — picks among candidate providers, computes outcome |
| `keeper_admission_router.ml` | 123 | Public entry point; orchestrates policy + bucket + queue |
| `keeper_admission_registry.ml` | 51 | Per-provider bucket lookup / lifecycle |
| `keeper_admission_runtime.ml` | 280 | Runtime adapter (shadow + active paths); reads `MASC_ADMISSION_USE_NEW` |
| `keeper_admission_glue.ml` | 55 | Heartbeat-loop integration shim |

External callers (5 sites): `keeper_heartbeat_loop.ml` (primary integration), `prometheus.ml` (metrics), `cascade/cascade_toml_materializer.ml` + `cascade_attempt_liveness_config.{ml,mli}` (config), and one cross-reference in `keeper_admission_glue.{ml,mli}`.

## Mapping table (spec action → OCaml call site)

| Spec action | OCaml entry point | Wired today? |
|-------------|------------------|--------------|
| `StartTurn(k)` | heartbeat tick that produces an admission request | yes (heartbeat loop always calls) |
| `TryDispatch(k, p)` | `Keeper_admission_runtime.run_admission_*` → `Keeper_admission_policy.choose` → `Keeper_provider_token_bucket.try_acquire` | shadow only unless `MASC_ADMISSION_USE_NEW=1` |
| `EnqueueOverflow(k)` | `Keeper_wfq_overflow.enqueue` (via runtime) | dormant (flag-gated) |
| `RefillToken(p)` | `Keeper_provider_token_bucket.refill_locked` (lazy — called inside `try_acquire`/`tokens_available` when `elapsed_sec > 0`; no separate timer). `add_on_refill` registers post-refill callbacks; `fire_on_refill_callbacks` drains them. | dormant (refill computation runs but admission flow disabled when flag off) |
| `WakeFromQueue` | `Keeper_wfq_overflow.wake_one` invoked on refill | dormant |
| `StartWork(k)` | (implicit; not a distinct OCaml function — the heartbeat-loop hands off to the cascade dispatch which the spec abstracts as `Working`) | always wired (cascade dispatch) |
| `CompleteWork(k)` | `Keeper_provider_token_bucket.release` in the cascade completion callback | dormant (release call only on `USE_NEW` path) |

## Drift risks visible today

These are call-outs for follow-up PRs, **not** fixes in this audit.

1. **Two-state observability gap (HIGH, drift class candidate)**
   The spec models `StartWork → Working → CompleteWork` as three discrete transitions. The OCaml dormant path inlines them: `try_acquire` returns, then the cascade dispatch runs synchronously, then `release` is called from the completion callback. If `MASC_ADMISSION_USE_NEW` is ever flipped on while the cascade completion callback is unreliable (panic, fiber cancel before release), `in_flight[p]` will leak. Spec's `RateRespect` invariant assumes `CompleteWork` always fires; OCaml has no equivalent of `Switch.on_release` wrapping the bucket lifetime.
   *Suggested fix-PR*: `K-2.a` — wrap admission acquire/release in `Eio.Switch.on_release` so cancellation releases the bucket. Cross-references RFC-0026 §4.2 "fault recovery".

2. **Strong-fairness expectation has no OCaml emulation (MED)**
   The spec comment around `Fairness` notes that `TryDispatch` must be *strongly* fair (not just weakly): "TLC 6243-state counter-example confirmed this 2026-05-05". OCaml side has no retry-with-bounded-backoff loop matching SF. Today this is invisible because the dormant path doesn't admit; on activation, a hostile burst of `Refill`/`Complete` interleaving could starve a keeper indefinitely.
   *Suggested fix-PR*: `K-2.b` — define and test a bounded-retry policy in `keeper_admission_router.ml`. Cross-reference TLC counter-example referenced in the spec comment for the test fixture.

3. **5-element spec state set vs 3-variant OCaml `decision` (LOW)**

   > **Correction (iter 66, K-2.c.1)** — the original wording of this item
   > said the OCaml result type was a 4-variant enum
   > `{ Dispatch_immediate p; Enqueue_overflow; Bypass_admission; Capacity_exhausted }`.
   > That was speculative and wrong: `rg 'Dispatch_immediate|Enqueue_overflow|Bypass_admission' lib/`
   > returns 0 matches. The actual type is
   > `lib/keeper/keeper_admission_router.mli` `type decision = Dispatch of {…} | Wait | Surface of surface_reason`
   > — **three** variants. (`Capacity_exhausted` exists, but as a Prometheus
   > *event* name in `keeper_admission_policy.mli`, not a decision constructor.)
   > Discovered while implementing K-2.c in iter 60 #14906; this paragraph
   > is the K-2.c.1 follow-up that fixes the audit memo's record. The
   > corrected mapping was already written into the `.mli` by #14906.

   The spec's `keeper_state` is a 5-element set `{"Idle", "Waiting", "Dispatched", "Working", "Done"}` modelling the keeper's lifecycle *position*. The OCaml `type decision` is a different kind of thing — the result of one `schedule` call — with 3 variants `Dispatch | Wait | Surface`. The mapping is one-to-many in time (one `Dispatch` covers the spec's `TryDispatch` *and* `StartWork` transitions) and was implicit until #14906 added the `.mli` block. This is acceptable as an abstraction but needed documenting because the relationship was reconstructed only by reading both files in parallel.
   *Fix-PR (DONE)*: `K-2.c` — `.mli` comment block citing this spec's mapping table, merged as #14906 (iter 60). 6th drift class precedent — same shape as `iter 47 KCtxL doc-layer drift`.

4. **Dormancy not visible from the spec (LOW)**
   The spec preamble lists invariants I1–I5 with no acknowledgement that the runtime does not yet apply them. A new contributor reading only the spec would assume `MASC_ADMISSION_USE_NEW` is on. Spec comment should add a "Status: design ground, runtime dormant pending `MASC_ADMISSION_USE_NEW=1` activation; see RFC-0026 PR-E-1.6" line.
   *Suggested fix-PR*: `K-2.d` — comment-only spec preamble note. RFC-WAIVED, same shape as iter 27/48/53 honest-doc.

## Out-of-scope observations

- `K-3` (TLC verification refresh) — `KeeperAdmissionLiveness.cfg` and the two `-buggy.cfg` fixtures have not been run inside this loop. A future iter should re-execute them after each `K-2.*` fix to confirm no regression. ~10–60 seconds per cfg per memory's "8-datapoint honest-doc precedent" but admission-spec changes do affect behaviour (unlike pure comment edits), so this should not be skipped.
- `K-4` (bug-model invariant pairing) — only safety invariants are exercised by the existing buggy cfgs; the liveness property `LivenessInvariant` has no buggy counterpart that demonstrates it would catch the starvation scenario. Adding a `BugAction_StarveKeeper` action that consumes/refills tokens around the target keeper without admitting it would close the bug-model symmetry the rest of the spec corpus enjoys.

## Verification (this audit)

- `wc -l specs/keeper-state-machine/KeeperAdmissionLiveness.tla` → 387 LOC.
- `wc -l lib/keeper/keeper_admission_*.ml lib/keeper/keeper_provider_token_bucket.ml lib/keeper/keeper_wfq_overflow.ml` → 845 LOC total.
- `rg -l 'Keeper_admission_(router|policy|glue|registry|runtime)\.' lib/ bin/` → 10 files, 5 unique callers outside admission itself.
- `rg -n 'MASC_ADMISSION_USE_NEW' lib/` → 5 references, all in admission modules. Confirms dormancy boundary is centralized.

No spec, OCaml, or .cfg modified by this PR.

## RFC trail

RFC-WAIVED — audit-only memo. Recommended follow-up RFCs:
- K-2.a (Switch.on_release for bucket lifetime)
- K-2.b (bounded retry → SF emulation)
- K-2.c (spec mapping in .mli, 6th drift class shape)
- K-2.d (spec preamble dormancy note)
- K-3 (TLC verification refresh after K-2)
- K-4 (BugAction_StarveKeeper paired buggy cfg)

Picked up by iter 57+ when admission becomes active scope (or as opportunistic finds in the FSM queue).
