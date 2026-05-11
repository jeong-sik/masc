# KSM `derive_phase` Priority Chain Audit (2026-05-12)

**Spec**: `specs/keeper-state-machine/KeeperStateMachine.tla` (lines 52-73, `DerivePhase`)
**OCaml**: `lib/keeper/keeper_state_machine.ml` (lines 403-463, `derive_phase`)
**Iteration**: 3 (Phase A-3, `/loop` plan)
**Cross-ref**: Iteration 1 #14694 audit (Gap-3 superset condition); Iteration 2 #14698 entry_actions refactor

## TL;DR

Line-by-line cross-check of OCaml `derive_phase` priority chain vs TLA+ `DerivePhase` finds **15 of 16 priorities are 1:1 isomorphic**. The 16th (OCaml priority 0, `credential_archived ∨ zombie_timeout_reached → Dead`) is *not* drift but **defense-in-depth** against flag persistence. TLA+ doesn't model the defense; the resulting refinement gap is filed as RFC backlog R-A-1.b (priority chain branch — TLA+ should verify the defense).

No code or spec change in this iteration. Audit-only.

## Priority chain side-by-side

| Pri | OCaml condition | TLA+ condition | Phase | Match |
|----:|-----------------|----------------|-------|:-----:|
| **0** | `credential_archived ∨ zombie_timeout_reached` | (absent) | Dead | OCaml-only |
| 1 | `stop_requested ∧ drain_complete ∧ ¬compaction_active ∧ ¬handoff_active` | identical | Stopped | ✅ |
| 2 | `launch_pending ∧ ¬fiber_alive` | identical | Offline | ✅ |
| 3 | `terminal_failure_latched` | identical | Zombie | ✅ |
| 4 | `¬fiber_alive ∧ ¬restart_budget_remaining` | identical | Dead | ✅ |
| 5 | `¬fiber_alive ∧ restart_budget_remaining ∧ backoff_elapsed` | identical | Restarting | ✅ |
| 6 | `¬fiber_alive ∧ restart_budget_remaining` | identical | Crashed | ✅ |
| 7 | `stop_requested` | identical | Draining | ✅ |
| 8 | `guardrail_triggered` | identical | Failing | ✅ |
| 9 | `operator_paused ∨ (context_overflow ∧ compact_retry_exhausted)` | identical | Paused | ✅ |
| 10 | `handoff_active` | identical | HandingOff | ✅ |
| 11 | `compaction_active` | identical | Compacting | ✅ |
| 12 | `context_overflow` | identical | Overflowed | ✅ |
| 13 | `¬heartbeat_healthy ∨ ¬turn_healthy` | identical | Failing | ✅ |
| 14 | `fiber_alive` | identical | Running | ✅ |
| 15 | (else) | (else) | Offline | ✅ |

## Why priority 0 is defense-in-depth (not drift)

**Layer 1** (apply_event guard, line 754-758):
```ocaml
match current_phase with
| Stopped | Dead | Zombie ->
  Error (Terminal_state {...})
| _ -> ... (* proceed *)
```
Events on terminal phases are rejected → flags can't be set on Dead/Stopped/Zombie via the event path.

**Layer 2** (priority 0):
```ocaml
if c.credential_archived || c.zombie_timeout_reached then Dead
```
If a `Credential_archived` or `Zombie_timeout` event is dispatched on a **non-terminal** phase (e.g., Restarting), `update_conditions` (lines 576-579) sets the corresponding flag. The flag *persists* across subsequent events because `Fiber_started`'s reset list (lines 555-569) does **not** clear `credential_archived` or `zombie_timeout_reached`. Priority 0 then keeps the keeper at Dead even after Fiber_started.

**Why this matters**: a "resurrection" bug would otherwise be possible — credential archived → forced to Dead → supervisor sees a restart opportunity (`Fiber_started`) → conditions reset *most* flags but the credential flag persists → priority 0 wins → still Dead. Without priority 0, the same Fiber_started would restore Running with credential still archived (semantic contradiction: keeper running against archived credentials).

## Flag-persistence corroboration

Test `test_keeper_state_machine.ml:1372-1397` directly sets `credential_archived=true; zombie_timeout_reached=true` then dispatches `Fiber_started` from `Restarting` and asserts conditions reset. The test currently *doesn't* check that these two flags are reset — it only checks `fiber_alive`, `heartbeat_healthy`, `turn_healthy`, etc. Persistence is implicit and undocumented in test assertions.

```mermaid
flowchart TD
  E1[Credential_archived event\non Restarting] --> U1[update_conditions\nsets flag=true,\nfiber_alive=false,\nbudget=false]
  U1 --> D1[derive_phase\npriority 0 OR 4\n=> Dead]
  D1 --> NF[Fiber_started event\non Dead]
  NF --> Reject[apply_event rejects\nLayer 1 guard]
  D1 -.->|"hypothetical leak\npast Layer 1"| LF[Layer 2 / priority 0]
  LF --> StayDead[stays Dead\nflag persists]

  Z1[Zombie_timeout event\non Running] --> U2[update_conditions\nsets flag=true,\nbudget=false\n(fiber_alive unchanged)]
  U2 --> D2["derive_phase\nWITHOUT priority 0\n→ priority 14 Running (BUG!)"]
  U2 --> D2b["derive_phase\nWITH priority 0\n→ Dead"]
  D2 -.->|"defense gap"| GAP[without priority 0,\nZombie_timeout silent on Running]
```

## Findings (Iteration 3)

### F-3.1 (MID risk, doc/spec gap — not behavior bug)
TLA+ DerivePhase doesn't model `credential_archived` / `zombie_timeout_reached` (Gap-3 of iter 1 was the *variable* absence; here we see the *priority chain* absence). The defensive intent of priority 0 is invisible to TLC.

**Counter-example detected by analysis** (but not by TLC since spec doesn't have these flags):
- `Zombie_timeout` event on Running keeper.
- `update_conditions` sets `zombie_timeout_reached=true; restart_budget_remaining=false`. `fiber_alive` is **unchanged** (remains true).
- Without priority 0: priority 14 (`fiber_alive`) matches → Running. Event semantically silent.
- With priority 0: → Dead. Correct.

So priority 0 is *load-bearing*. Removing it would create a real bug for `Zombie_timeout` on `Running`. RFC R-A-1.b should not propose removal — it should propose **TLA+ spec extension to add the two flags and the priority 0 branch, then re-run TLC to verify**:
- `DeadIsForever` invariant holds.
- `BudgetNeverRevives` holds.
- Fiber_started reset's *omission* of the two flags is intentional (not a missed reset).

### F-3.2 (LOW risk, test assertion gap)
`test_keeper_state_machine.ml:1380-1397` exercises Fiber_started reset behavior but never asserts `credential_archived` / `zombie_timeout_reached` are preserved (or reset). The implicit invariant — *these flags must persist across Fiber_started so priority 0 stays load-bearing* — is undocumented.

**Suggested follow-up PR** (next iteration candidate, ~10 LOC):
```ocaml
(* Test line ~1397: add explicit persistence assertion *)
check bool "credential_archived persisted" true updated.credential_archived;
check bool "zombie_timeout_reached persisted" true updated.zombie_timeout_reached;
```

### F-3.3 (LOW risk, design comment clarity)
OCaml line 422 inline comment ("Forced terminal state — external cleanup/credential signals.") describes WHAT priority 0 does but not WHY (the defense-in-depth intent). A future reader removing priority 0 in pursuit of "spec alignment" could introduce the bug described in F-3.1.

Per CLAUDE.md `<tone>` "Don't explain WHAT" rule, *the comment shouldn't grow* — but the audit memo (this file) is the right place for the WHY documentation.

## Verification (this iteration)

- [x] Line-by-line priority chain cross-check (16 OCaml ↔ 15 TLA+).
- [x] Counter-example for `Zombie_timeout` on `Running` derived analytically.
- [x] `update_conditions` for both events inspected (lines 576-579).
- [x] `Fiber_started` reset list inspected (lines 555-569) — confirms flag persistence.
- [x] Existing test (`test_keeper_state_machine.ml:1372-1397`) inspected for implicit invariant.

## Trade-off

본 iteration은 code/spec 변경 0건. *defense 의도가 분명하므로 priority 0 제거 금지*가 핵심 결론. 진짜 fix (TLA+ extension)은 R-A-1.b로 적재됨. 10분 budget 안에서 TLA+ VARIABLES 확장 + DerivePhase priority 0 추가 + 모든 temporal property 재검증 (TLC 5-15분)은 불가능.

## RFC 참조

`RFC-WAIVED: audit-only memo, no code surface modification. Existing RFC backlog entry R-A-1.b updated with new finding F-3.1 (priority 0 is defense-in-depth, not drift).`

## 진행 추적

- 다음 iteration: **Phase A-4** — `apply_event` Terminal phases (Stopped/Dead/Zombie) reject 일치성 verify. spec의 terminal property (DeadIsForever, StoppedIsForever 등) ↔ OCaml line 754-758 cross-check.
- F-3.2 (test 추가) 와 R-A-1.b 확장은 별도 iteration queue로.
