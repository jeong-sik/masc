---
rfc: "0114"
title: "KSM event precondition enforcement at apply_event boundary"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0002", "0042", "0072", "0113"]
implementation_prs: []
---

# RFC-0114: KSM event precondition enforcement at apply_event boundary

## §1 Problem (caller-context)

`specs/keeper-state-machine/KeeperStateMachine.tla` (KSM) 는 keeper 11-state FSM 의 *각 event* 가 *발화 가능한 precondition* 을 명시함. 5 condition-setter event 중 4개가 OCaml `lib/keeper/keeper_state_machine.ml` (`apply_event` line 752-799, `update_conditions` line 540-674) 에서 **enforce 되지 않음** — `apply_event` 가 *terminal phase reject* 만 통합 enforce, 그 외 precondition 은 silent 통과.

`docs/tla-audit/ksm-precondition-enforcement-gap-2026-05-12.md` 의 gap matrix:

| Event | TLA+ precondition | OCaml precondition |
|---|---|---|
| `Auto_compact_triggered` | `NotTerminal ∧ fiber_alive ∧ context_overflow ∧ ¬compaction_active ∧ ¬handoff_active ∧ ¬compact_retry_exhausted` | terminal reject only |
| `Operator_compact_requested` | `NotTerminal ∧ fiber_alive ∧ ¬compaction_active ∧ ¬handoff_active` | terminal reject only |
| `Compact_retry_exhausted` | `NotTerminal ∧ fiber_alive ∧ context_overflow ∧ ¬compaction_active ∧ ¬compact_retry_exhausted` | terminal reject only |
| `Context_overflow_detected` | `NotTerminal ∧ fiber_alive ∧ ¬compaction_active` | terminal reject only |
| `Operator_clear_requested` | `NotTerminal` | terminal reject (✅ 1:1) |

**4 / 5 event** 에서 precondition 누락. 각 누락이 *silent state corruption* 시나리오 유발:

### Documented silent-corruption scenarios

(audit doc §"시나리오" 인용)

- **Scenario A** (`Auto_compact_triggered` w/o overflow): caller 가 `context_overflow=false` 상태에서 dispatch → `compaction_active=true` 설정 → derive_phase → Compacting → 빈 compaction → `CompactionFailed` / `NoSavings` path.
- **Scenario B** (`Compact_retry_exhausted` stale): stale event 로 영구 latch `compact_retry_exhausted=true` → 다음 overflow 시 priority 7 Paused 강제 → operator 개입 필요.
- **Scenario C** (`Operator_compact_requested` during HandingOff): UI race condition 시 `compaction_active=true` + `handoff_active=true` 동시 set → handoff 완료 후 unexpected Compacting parasitic state.

### Why this needs an RFC

1. **Audit doc 가 명시적으로 RFC 추천**: F-9.1 (HIGH risk strategic) 항목이 "R-A-9 RFC 후보" 로 적시. iter 6-9 누적 4 iteration 동안 fix 시점 미정.
2. **Class gap, not single-event**: 5 events 모두 같은 *enforcement boundary 부재* 의 변형. 개별 fix 5건은 N-of-M, 통합 `apply_event` 보강이 root fix.
3. **TLA+ Bug Model 패턴 적용 미수**: CLAUDE.md `software-development.md` §"TLA+ Bug Model" 가 spec invariant + buggy.cfg 양쪽 통과를 mutation testing 패턴으로 요구하지만, 본 spec 의 *precondition* 측면은 그 패턴 적용 안됨 — KSM-buggy.cfg 가 precondition 위반 mutate 시 OCaml 가 silent 통과하면 spec 정합성 깨짐.
4. **RFC-0113 KRL family 와 연속**: KRL 이 *liveness* (L1-L5 leads-to), KSM 이 *safety preconditions*. Spec-runtime contract family.

근본 원인: **`apply_event` 가 *event variant 별 precondition* 을 `Result.t` 로 typed 검사 안 함**. 단일 *terminal-only* guard 가 5 events 모두 cover 한다고 가정.

## §2 Approach

3 layer:

**Layer A — Typed precondition checker**

`Keeper_state_machine.Event_precondition` 모듈:

```ocaml
module Event_precondition : sig
  type mismatch =
    | Missing_condition of { event : event; required : string }
    | Forbidden_condition of { event : event; forbidden : string }
    | Multi_mismatch of mismatch list
  val to_string : mismatch -> string

  val check : event -> conditions -> (unit, mismatch) Result.t
  (* event-variant 별 pattern match → required/forbidden enumerate *)
end
```

각 event variant 가 pattern arm 에서 자신의 precondition 을 명시. closed-sum 이므로 새 event 추가 시 컴파일러가 누락 catch (RFC-0042 패턴).

**Layer B — `apply_event` 보강**

```ocaml
let apply_event ~current_phase ~conditions ~event ~now =
  match current_phase with
  | Stopped | Dead | Zombie -> Error (Terminal_state {...})
  | _ ->
    match Event_precondition.check event conditions with
    | Error mismatch -> Error (Precondition_violation { event; mismatch })
    | Ok () ->
      let updated_conditions = update_conditions conditions event in
      ...
```

기존 caller 가 *unwrap* 또는 *log + skip* 패턴을 선택. 두 정책 모두 silent corruption 보다 낫다.

**Layer C — TLA+ Bug Model wiring**

`KeeperStateMachine-buggy.cfg` (이미 존재) 에 precondition mutation 추가. `BuggyApplyEvent` action 이 precondition 무시. spec invariant 위반 확인. → CI 가 spec PR 시 clean.cfg PASS + buggy.cfg FAIL 양쪽 검증.

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | `Event_precondition` 모듈 + `check` 함수 + 5 unit test (each event ✗ violation surface) | dune build PASS, alcotest PASS |
| P3 | `apply_event` 보강 (precondition gate). Caller policy: 기존 caller 4개 inventory + `Result.bind` chain 또는 명시적 `log+skip`. | PBT (`test_pbt_apply_event_preconditions.ml`) PASS — 5 scenarios (A/B/C + 2 추가 edge case) violation 시 `Error` 반환 |
| P4 | KSM TLA+ spec 의 buggy.cfg 에 `BuggyApplyEvent` action 추가 | TLC: KSM.cfg PASS, KSM-buggy.cfg invariant violation |
| P5 | Caller migration sweep. 4 caller 가 모두 `Result.t` 처리. Silent unwrap 0. | `rg "apply_event" lib/ \| grep -v Result" = 0` 또는 모두 명시적 ignore |
| P6 | metrics: `keeper_apply_event_precondition_violation_total{event=...}` Prometheus counter | dashboard 가 0 violation 4주 monitoring 후 P5 caller 정책 default-on |

P3 가 핵심 — 첫 spec-runtime invariant 정합. P6 는 telemetry-as-validator (counter 가 0 이어야 spec 정합) — **이번에는 Counter-as-Fix 가 아닌 Counter-as-Validator**. CLAUDE.md §"Counter-as-Fix" 구분: data loss 가 *이미 막혔다는 증거* 로 counter 사용 OK.

## §4 Open questions

1. **Q1**: 4 existing caller (`keeper_unified_turn`, `keeper_event_queue`, `keeper_world_observation`, `keeper_compact_policy`) 가 silent unwrap vs propagation 선호? **잠정**: P3 의 caller migration sprint 에서 case-by-case — `keeper_unified_turn` 가 turn 안 일 가능성 (propagation), `keeper_world_observation` 가 read-only 일 가능성 (log+skip).

2. **Q2**: `Operator_compact_requested` during HandingOff (Scenario C) 가 *operator 의도 적 race* 일 가능성? UI 가 operator 에게 *handoff 중 compact 불가* 표시? **잠정**: P3 에서 `Error (Precondition_violation _)` 가 dashboard 에 operator action item 으로 surface — UI 에 "handoff completes first" 메시지.

3. **Q3**: TLA+ spec 의 `~compact_retry_exhausted` precondition 이 *실제로 latched* 면 어떤 event 가 reset? spec 본문 확인 필요. **잠정**: spec 본문 grep + P2 의 unit test 가 reset 행동 정의.

4. **Q4**: `Event_precondition.check` 가 multi-condition `Error (Multi_mismatch _)` 반환 시 caller 의 처리? 첫 mismatch 만 표시 vs 전부 표시? **잠정**: 전부 표시 (operator debugging 도움).

## §5 Non-goals

- **Spec 외 새 precondition 추가**: 본 RFC 는 *spec ↔ runtime 정합*. 새 precondition 은 spec PR 가 선행.
- **다른 spec (KAQ, KCR, KTC 등) 의 precondition enforcement**: 별도 RFC. KSM 만 first principle 확인 후 family 확장.
- **runtime → spec 역방향 enforcement** (OCaml 의 추가 invariant 를 spec 가 모델 안함): 별도 spec PR.

## §6 Risk & rollback

- **Risk 1**: Caller migration (P5) 가 *test fixture* 의 stale event 시뮬레이션을 break. → P2 의 unit test 에 `Allow_test_bypass` env flag 추가 (production 코드 0 이지만 fixture 만 사용).
- **Risk 2**: `Precondition_violation` 가 *false positive* (spec 가 OCaml 의 실 caller-pattern 을 모델 안함) → P4 의 buggy.cfg 가 정확한 mutation 만 capture, false positive 시 spec PR 가 precondition 완화.
- **Risk 3**: `Event_precondition.check` 의 pattern match 가 OCaml exhaustive 강제 — 새 event variant 추가 시 컴파일 fail. *이게 정확히 원하는 행동* (RFC-0042). 단 *spec ↔ runtime 동기 PR* 강제.
- **Risk 4**: P6 의 dashboard wiring 이 P3 의 wrong-precondition 표시 시 operator alert fatigue. → 첫 4주 dashboard-only, alert 는 disabled.

Rollback: 각 Phase 별 PR. P3 의 `apply_event` 변경은 backward-compat (Result.t 가 새 error variant 만 추가). P5 caller migration 은 revert 시 silent unwrap 으로 복구 — 받아들이지 못할 정도는 아님.

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: `Event_precondition.check` + 5 unit test PASS.
- [ ] P3: `apply_event` 보강. 5 scenarios PBT PASS.
- [ ] P4: KSM-buggy.cfg 에 `BuggyApplyEvent` action 추가. TLC PASS clean + FAIL buggy.
- [ ] P5: 4 caller 모두 typed Result 처리. silent unwrap = 0.
- [ ] P6: `keeper_apply_event_precondition_violation_total` Prometheus counter. 4주 dashboard monitoring 후 default-on.

## §8 Number allocation note

Allocated as RFC-0114. Ledger advanced 0109 → 0115 (skip 0109-0113 due to inflight #15902 RFC-0109 CDAL × GOAL + #15924 RFC-0110 tool-pair atomicity (iter-2) + #15927 RFC-0111 goal mint atomicity (iter-3) + #15933 RFC-0112 typed JSON parse boundary (iter-4) + #15937 RFC-0113 KeeperReactionLiveness runtime (iter-5)). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."
