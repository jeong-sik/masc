# `-buggy.cfg` `CHECK_DEADLOCK` pattern catalog — non-KSM corpus (iter 99 extension of iter 98)

**Date**: 2026-05-12 · **Iteration**: 99 · **Phase**: meta-audit (extends iter 98 catalog — see PR #15011 — from `specs/keeper-state-machine/` to the remaining 9 spec dirs)

## What this is

iter 98 #15011 catalogued 32 `-buggy.cfg` files in `specs/keeper-state-machine/` (one source of OPB R-12.a's Class E fix). The catalog explicitly deferred non-KSM dirs as a follow-up. This memo closes that follow-up: 35 `-buggy.cfg` files across 9 non-KSM dirs, classified by the same 5-class taxonomy, *and* TLC-verified for the 7 missing-`CHECK_DEADLOCK` instances.

## Method (extends iter 98)

Same procedure: extract `NextBuggy` shape, cross-check `CHECK_DEADLOCK` directive. Then *additionally* run TLC on each missing-CD instance to empirically confirm the buggy run exits via invariant/property violation (`Invariant ... is violated` diagnostic) and **not** deadlock (`Deadlock reached` diagnostic) — closing iter 98's deferred Class D verification by analog.

## Non-KSM inventory (35 cfgs across 9 dirs)

| Dir | Total | `CHECK_DEADLOCK FALSE` present | Missing CD |
|---|---:|---:|---:|
| `specs/cascade/` | 1 | 1 | 0 |
| `specs/multimodal/` | 2 | 2 | 0 |
| `specs/bug-models/` | 25 | 23 | 2 |
| `specs/server-state/` | 1 | 0 | 1 |
| `specs/state-product/` | 2 | 2 | 0 |
| `specs/admission-queue/` | 1 | 0 | 1 |
| `specs/auth/` | 1 | 0 | 1 |
| `specs/task-lifecycle/` | 1 | 0 | 1 |
| `specs/keeper-turn-fsm/` | 1 | 0 | 1 |
| **Total** | **35** | **28** | **7** |

7 missing-CD candidates → all run through TLC.

## Empirical TLC results for the 7 missing-CD cfgs

| File | `NextBuggy` shape | Class | TLC buggy exit | Outcome |
|---|---|---|---:|---|
| `specs/bug-models/AmbiguousPartialCommitBug-buggy.cfg` | `StartTurn ∨ ReadOnlyToolCall ∨ MutatingToolCall ∨ TurnSuccess ∨ BugProviderError ∨ Done` (no `Next`) | **D′ (enumerated-replace)** | **12** | `Invariant Safety is violated` — 87 distinct states, 27 left on queue. NOT deadlock. |
| `specs/bug-models/AuthIdentityFSM-buggy.cfg` | `Next ∨ SilentRewrite` | D (add-bug) | **12** | `Invariant SafetyInvariant is violated`. |
| `specs/server-state/ServerState-buggy.cfg` | `Next ∨ BugAction` | D | **12** | `Invariant InvariantViolated is violated`. |
| `specs/admission-queue/AdmissionQueue-buggy.cfg` | `Next ∨ FdGuardSkip ∨ ReleaseSkipped` | D | **12** | `Invariant CascadeNameCanonical is violated`. |
| `specs/auth/AuthIdentityFSM-buggy.cfg` | `Next ∨ SilentRewrite` (duplicate of `specs/bug-models/`) | D | **12** | `Invariant SafetyInvariant is violated`. |
| `specs/task-lifecycle/TaskLifecycle-buggy.cfg` | `NextClean ∨ BugSkipVerification ∨ BugSkipClaim` (`NextClean` is the clean transition disjunction) | **D** (effective add-bug — `NextClean` ≈ `Next` rename) | **12** | `Invariant InProgressRequiresClaim is violated`. |
| `specs/keeper-turn-fsm/KeeperTurnFSM-buggy.cfg` | `Next ∨ StopSignalSwallowedAsDone ∨ SilentReceiptDrop` | D | **12** | `Invariant StopSignalRespected is violated`. |

All 7 exit with **TLC exit code 12** = invariant violation. **No deadlock**.

## Findings

1. **`AmbiguousPartialCommitBug-buggy.cfg` is *effective* add-bug despite literally being replace-bug.** The `NextBuggy` definition enumerates every clean action by name plus the single bug substitution (`ProviderError` → `BugProviderError`); no clean action is *dropped*, only one is *replaced* with a buggy variant. The system can always advance, so no stuck phase forms. This identifies a sub-shape of Class E that iter 98 did not anticipate: **enumerated-replace** (writes out all of `Next`'s disjuncts by hand). Functionally Class D, structurally Class E.
2. **`TaskLifecycle-buggy.cfg` uses a renamed clean transition (`NextClean`)**, then `NextBuggy == NextClean \/ Bug...`. Functionally add-bug. The rename appears to be stylistic (the spec uses `NextClean`/`NextBuggy` rather than `Next`/`NextBuggy`).
3. **Genuine Class E is `replace-bug WITH dropped clean actions`** — both forms above keep all clean transitions available. The OPB pre-iter-97 pattern was the only known instance where *the bug model drops clean actions that would otherwise prevent stuck phases* (`WatchdogEmit` + `Recycle` were both removed). With OPB closed and these 7 non-KSM cfgs empirically clear, **the masc-mcp corpus has no remaining Class E instances at this commit**.
4. **iter 98's Class D 6 KSM specs (deferred-as-likely-safe) gain a *parallel-corpus* empirical foothold.** All 7 non-KSM add-bug-shape cfgs exited cleanly via invariant violation. This does not *prove* iter 98's KSM Class D 6 are safe — each spec's deadlock-freeness is its own theorem — but it confirms the shape-class hypothesis holds across 7 independent specs without exception. Per-spec verification of the KSM Class D 6 remains valuable but lower priority.

## Combined corpus picture (67 cfgs, 14 spec dirs)

| Class | Setting | Shape | KSM (iter 98) | Non-KSM (this PR) | Total |
|---|---|---|---:|---:|---:|
| A | `FALSE` | add-bug | 8 | TBD | TBD |
| B | `FALSE` | replace-bug | 10 | TBD | TBD |
| C | `FALSE` | no separate `NextBuggy` | 8 | TBD | TBD |
| D | missing | add-bug | 6 | 6 (verified ✅) | 12 |
| D′ | missing | enumerated-replace (effective add-bug) | 0 | 1 (verified ✅) | 1 |
| E | missing | replace-bug with dropped clean actions | 0 (was 1, OPB) | 0 | 0 |
| **Total missing-CD** | | | **6** | **7** | **13** |

(Non-KSM Classes A/B/C exact counts deferred — the missing-CD bucket is what carries risk; this audit closed the residual gap there.)

## Why this is not a workaround

Same reasoning as iter 98: pre-emptive `CHECK_DEADLOCK FALSE` widening to the 13 missing-CD cfgs across the whole corpus would be defensive infrastructure without an observed failure mode. With 7 empirical confirmations added on top of iter 98's structural argument, the rejection of pre-emptive widening is now *empirically grounded*, not just principled.

## What this PR does

- Adds `docs/tla-audit/buggy-cfg-check-deadlock-pattern-catalog-non-ksm-2026-05-12.md` (this memo, ~90 LOC).
- **No spec, cfg, or `INDEX.md` edits.** All 7 missing-CD cfgs continue to be `CHECK_DEADLOCK`-absent and each buggy run correctly surfaces its intended invariant violation (as verified above). The corpus is unchanged.

## Trade-offs

- **No cfg changes** — 7 specs verified safe-as-is, no defensive widening.
- **Class A/B/C exact non-KSM counts deferred** — the missing-CD bucket carries the actionable risk; A/B/C is bookkeeping.
- **Per-spec deadlock-freeness theorems not proved** — empirical confirmation only; future TLC regressions on these specs would re-trigger this question.

## Follow-up

- **iter 98 KSM Class D 6 per-spec TLC verification**: still deferred (parallel corpus result lends second-hand confidence). Run when budget permits or when a deadlock is reported on any of: `KeeperApprovalQueue-buggy`, `KeeperEventQueue-buggy`, `KeeperHeartbeat-buggy`, `KeeperLaunchPending-buggy`, `KeeperOASAdvanced-buggy`, `KeeperTaskAcquisition-buggy`.
- **Class D′ identification**: enumerated-replace shape (Class E literally, Class D functionally) was discovered here. If new bug models use this shape, they should be classified D′ and require empirical verification (not the structural inference that protects D).
- **`AuthIdentityFSM` duplicated under `specs/bug-models/` and `specs/auth/`**: `diff` shows the two cfgs are byte-identical. The two `.tla` files are also likely duplicates (not investigated here). Future cleanup candidate — one location should be authoritative.

## Verification

- Corpus enumeration: `for d in specs/cascade specs/multimodal specs/bug-models specs/server-state specs/state-product specs/admission-queue specs/auth specs/task-lifecycle specs/keeper-turn-fsm; do ls $d/*-buggy.cfg; done | wc -l` → 35.
- Missing-CD detection: `for d in specs/cascade specs/multimodal specs/bug-models specs/server-state specs/state-product specs/admission-queue specs/auth specs/task-lifecycle specs/keeper-turn-fsm; do for f in "$d"/*-buggy.cfg; do grep -q CHECK_DEADLOCK "$f" || echo "$f"; done; done` → 7 paths.
- TLC runs: 7 invocations of `tlc -config <spec>-buggy.cfg <spec>.tla`, each `exit 12` with invariant-violation diagnostic. Total wall time ~30s.
- Base: `162f89631` (iter 97 #15008 in base; iter 98 #15011 — this memo extends #15011's argument).
