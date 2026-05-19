---
rfc: "0136"
title: "Keeper Unified Turn — Phase 4: Retry Loop Body Decomposition"
status: Active
created: 2026-05-19
updated: 2026-05-19
author: vincent
supersedes: []
superseded_by: null
related: ["0051", "0056", "0085"]
extends: "0136"
implementation_prs: [16701, 16709, 16751]
---

# RFC-0136 Phase 4 — Retry Loop Body Decomposition

본 sub-doc 은 RFC-0136 main spec §4.2 PR-3 (deferred — *Retry loop body — separate RFC sub-doc 검토*) 의 구체 계획이다. PR-1/2/3 (Phase Gate / Cascade Resolution / Pre-Dispatch) 머지 후 `keeper_unified_turn.ml` 의 1742 LOC 중 가장 큰 잔여 stage 인 `rec retry_loop` (L604, ~1100 LOC) 를 5 sub-PR 로 분할한다.

본 sub-doc 은 *PR-4 single PR 불가* 의 정량 근거 + sub-PR boundary + context record signature 를 정의한다.

---

## 1. 현재 상태 측정 (post-PR-3, main `2a5ba29093`)

| 측정 | 값 |
|------|-----|
| `keeper_unified_turn.ml` | 1742 LOC |
| `let rec retry_loop` 위치 | L604 |
| retry_loop body 종료 | L1700 (추정 ±20) |
| retry_loop 본체 LOC | ~1100 |
| retry_loop 명시 args | 7 (`run_meta`, `execution`, `run_generation`, `attempt`, `is_retry`, `allow_degraded_wall_clock_retry_budget`, `attempted_cascades`) |
| outer closure deps | 15+ (config, meta, cycle_completed, keeper_turn_id, append_manifest, runtime_manifest_context, effective_cascade_name, profile_defaults, fail_open_rotation_cascades, initial_tool_requirement, clock, turn_started_at, turn_deadline, do_run, ...) |
| nested helpers | `do_run` (L478), `mark_terminal_error` (L616, **9 call sites**), `attempt_result` (L680), `max_turns` (L670), `execution_cascade_name` (L613), `attempt_timeout_budget` ref (L669) |

### 1.1 Single-PR 불가 정량 근거

- 새 file LOC ~1100 > `scripts/lint/godfile-size-regression.sh` *new_file_cap = 600*. `--fail` 게이트로 차단.
- `retry_loop` 의 nested helpers (`mark_terminal_error` 9 callsites, `do_run` 등) 가 *동시 추출* 필요 — 외부 호출자 없는 *self-contained 추출 단위*.
- closure deps 15+ 가 *typed context record* 없이는 *huge signature*; record 도입은 *별도 PR-4-a* 로 *baseline* 필요.

### 1.2 사용자 요구사항 정합 (CLAUDE.md §워크어라운드 거부)

| # | Pattern | Phase 4 적용 여부 |
|---|---------|------------------|
| 1 | Telemetry-as-fix | N/A — restructure |
| 2 | String classifier | N/A — typed record 도입 (반대 방향) |
| 3 | **N-of-M migration** | **부분 위험** — 5 sub-PR 분할 자체가 N-of-M 형태. 그러나 PR-1/2/3 이미 같은 패턴 (3 of 4 stages); Phase 4 는 *해당 RFC 의 자연 마무리* 이며 *전체 closure* 가 목표 |
| 4 | Catch-all `_ ->` | N/A — 5 typed sub-PR 모두 exhaustive |
| 5 | Cap/cooldown/dedup/repair | N/A |
| 6 | Test backdoor | N/A |
| 7 | N-site mechanical fix | N/A — 각 sub-PR 은 1 file 내부 stage 분리 |

§3 N-of-M 자체는 *워크어라운드 거부 시그니처 #3* 의 *경계선*. *해당 RFC closure 의 일부* 임이 *Sub-doc 명시* + *PR 별 boundary 정량* + *PR-4-final 마감 commit 필수* 로 *반복 패턴 누적 방지*.

---

## 2. Sub-PR 분할

### 2.1 PR-4-a: Outer Setup Block 추출

| 항목 | 값 |
|------|-----|
| Source | L436-602 (~167 LOC) |
| Scope | timeout_sec, turn_started_at, turn_deadline, remaining_turn_budget_s, retry_phase_started_at, elapsed_ms, current_turn_phase_elapsed_ms, keeper_profile, max_idle_turns, max_turns, initial_tool_requirement, do_run, fail_open_rotation_cascades |
| Target module | `keeper_unified_turn_retry_setup.{ml,mli}` |
| Closure deps | config, meta, channel, observation, clock, generation |
| 추정 LOC delta | `keeper_unified_turn.ml` 1742 → ~1575 (-167) |
| 위험도 | LOW (self-contained block, no recursion) |

#### 2.1.1 Setup return record

```ocaml
type retry_setup =
  { timeout_sec : float
  ; turn_started_at : float
  ; turn_deadline : float
  ; remaining_turn_budget_s : unit -> float
  ; retry_phase_started_at : float option ref
  ; elapsed_ms : float -> int
  ; current_turn_phase_elapsed_ms : unit -> int * int option
  ; keeper_profile : Keeper_types_profile.keeper_profile_defaults
  ; max_idle_turns : int
  ; max_turns : int
  ; initial_tool_requirement : Keeper_agent_tool_surface.tool_requirement
  ; do_run : ...  (* TBD — closure spec 후속 측정 *)
  ; fail_open_rotation_cascades : string list
  }
```

closure fields (`remaining_turn_budget_s`, `elapsed_ms`, `do_run`) 는 *factory pattern 회피* 위해 *순수 함수 fields* 또는 *primitive values* 로 변환 검토.

### 2.2 PR-4-b: `mark_terminal_error` 추출

| 항목 | 값 |
|------|-----|
| Source | L616-668 (~53 LOC, 추정) |
| Call sites | **9 in retry_loop body** |
| Target module | `keeper_unified_turn_retry_error_marker.{ml,mli}` |
| Closure deps | config (base_path), meta, attempt, attempted_cascades |
| 추정 LOC delta | -53 |
| 위험도 | LOW (typed helper, dedup value high) |

#### 2.2.1 Typed return

```ocaml
type terminal_error_outcome =
  | Cascade_exhausted of Agent_sdk.Error.sdk_error
  | Phase_set_to_failed of Keeper_state_machine.failure_reason
```

caller (retry_loop) 가 *exhausted vs single-error* 구분을 *typed* 로 dispatch — 현재는 inline if/then/else.

### 2.3 PR-4-c: retry_loop Recursive Core

| 항목 | 값 |
|------|-----|
| Source | L604-? (residual after a/b/d/e) |
| Scope | recursion + state + main control flow |
| Target module | `keeper_unified_turn_retry_loop.{ml,mli}` |
| Closure deps | typed `retry_context` record (PR-4-a 결과) |
| 추정 LOC delta | -400 (PR-4-d/e 머지 후 잔여) |
| 위험도 | MEDIUM (recursion state preservation) |

### 2.4 PR-4-d: attempt_result + Retry Decision Branches

| 항목 | 값 |
|------|-----|
| Source | L680-? (retry decision tree) |
| Scope | Agent_sdk error classification → degraded_retry_decision → rotation/continuation |
| Target module | `keeper_unified_turn_retry_decision.{ml,mli}` |
| Closure deps | execution, attempt, attempted_cascades, fail_open_rotation_cascades, allow_degraded_wall_clock_retry_budget |
| 추정 LOC delta | -300 |
| 위험도 | MEDIUM |

### 2.5 PR-4-e: Success/Error Final Dispatch

| 항목 | 값 |
|------|-----|
| Source | retry_loop 종단 분기 (Ok / Error) |
| Scope | finalize_trajectory_acc, Keeper_unified_turn_success.handle 호출, post_turn_complete_task |
| Target module | inline in `keeper_unified_turn.ml` 잔여 또는 별도 |
| Closure deps | cycle_completed, run_meta |
| 추정 LOC delta | -180 |
| 위험도 | LOW |

---

## 3. 누적 효과

### 3.1 원안 추정 (작성 시점, 부정확)

| Sub-PR | 시작 → 끝 | delta |
|--------|----------|-------|
| PR-4-a | 1742 → 1575 | -167 |
| PR-4-b | 1575 → 1522 | -53 |
| PR-4-c | 1522 → ~1100 | -400 |
| PR-4-d | ~1100 → ~800 | -300 |
| PR-4-e | ~800 → ~620 | -180 |

**원안 예상 최종**: ~620 LOC. 1943 → ~620 = **-1320 LOC (-68%)**.

### 3.2 실측 결과 (2026-05-19)

| Sub-PR | # | 시작 → 끝 | delta | 원안 대비 |
|--------|---|----------|-------|----------|
| PR-4-a Retry Setup | #16701 | 1742 → 1687 | **-55** | 33% (167 의 1/3) |
| PR-4-b Terminal Error | #16709 | 1687 → 1675 | **-25** | 47% (53 의 1/2) |
| PR-4-c Dispatch Watchdog | #16751 | 1675 → 1641 | **-33** | **8% (400 의 1/12)** |
| **누적 실측** | | 1742 → 1641 | **-101** | 22% (167+53+400 의 1/5) |

**실측 최종 (PR-4-c 머지 후)**: 1641 LOC. PR-1/2/3 기여 -201 LoC 포함 시 1943 → 1641 = **-302 LoC (-15.5%)**.

### 3.3 원안 오차 정량

PR-4-c 추정 -400 LoC 가 가장 큰 오차 (실측 -33, 12배 over-estimate). 원인:

- 원안은 `retry_loop` *전체 body* (~1100 LOC) 의 *recursive core* 추출 가정.
- 실측 PR-4-c 는 *dispatch_with_watchdog* (88 LoC subset) 만 추출 — `try ... Eio.Time.with_timeout_exn ... with Cancelled/Timeout` 부분.
- `attempt_result` (75 LoC) + `do_run` 통째 (122 LoC) 추출은 *closure capture 16-20+ deps 폭증*으로 *typed boundary 어려움* 확인.
- `match attempt_result with` dispatch (L688-L1191, 503 LoC) 는 *retry_loop self-reference + 큰 분기 매트릭스* 로 외부 추출 비용 큼.

### 3.4 PR-4-d / PR-4-e 보류 결정

다음 두 가지 path 중 하나로 진행:

- (a) 별도 측정 RFC sub-doc 작성 + retry_loop body 의 *typed-wrapper-가능 영역* 만 fine-grained 분할.
- (b) `run_keeper_cycle` mega-function 분해를 *다른 접근* (context record 도입, monomorphization, state-machine refactor) 으로 *별도 후속 RFC* 에서.

본 sub-doc 의 PR-4-c/d/e 원안 추정값은 *historical reference* 로 보존하되 *retry_loop body internal cohesion*에 의해 *원안 그대로 적용 불가* 가 확정.

---

## 4. Sequencing & Dependencies

```
PR-4-a (setup record) ─┐
                       ├─→ PR-4-c (retry core, depends on setup record + error marker)
PR-4-b (error marker) ─┘
                       ├─→ PR-4-d (retry decision, depends on retry core for typed signatures)
                       └─→ PR-4-e (final dispatch)
```

- PR-4-a 와 PR-4-b 는 *parallel* 가능 (서로 독립).
- PR-4-c 는 *PR-4-a + PR-4-b 머지 후*.
- PR-4-d 와 PR-4-e 는 *PR-4-c 머지 후*.

순차 권장 (stack PR 위험 회피 — memory `feedback_stack_pr_force_base_main_anti_pattern.md`).

---

## 5. Risks & Mitigations

### 5.1 Recursion state preservation (PR-4-c)

`rec retry_loop` 의 *self-call* 가 *typed context + named args* 로 변환 필수. *closure 누락 시 silent error*. *각 self-call site 의 argument 명시 검증*.

**Mitigation**: PR-4-c impl 시 *self-call 전수 grep* + *named args 비교 table* PR body 에 포함.

### 5.2 attempt_result branch 의 *Agent_sdk error variant matching* (PR-4-d)

`Agent_sdk.Error.sdk_error` 의 variant 가 11+ 종 (memory 의 RFC-0098/0105 closure 기준). retry_loop 내부 분기가 *exhaustive 인지* 검증.

**Mitigation**: PR-4-d impl 시 *exhaustive match* 또는 *RFC-0098 typed envelope* 활용. `_ -> ` catch-all 금지.

### 5.3 PR-4-c 의 새 file LOC 가 600 cap 위반 가능

`retry_loop` 잔여 ~400 LOC + boilerplate ~50 LOC + typed signatures ~50 LOC ≈ ~500 LOC. *600 cap 안전*하나 *추가 helper 추출 시 늘어남*.

**Mitigation**: PR-4-c body 에 *helper extraction 추가 안 함*; 단순 recursive control flow 만 유지.

### 5.4 stack PR force=main yield 7% (memory)

본 5 sub-PR 은 *stack PR 형태* 가 *자연스러움* — PR-4-c 는 PR-4-a + PR-4-b base. memory `feedback_stack_pr_force_base_main_anti_pattern.md` 는 *force=main* 거부.

**Mitigation**: sequential merge (PR-4-a/b merge → PR-4-c rebase main → push). *base=main 직접 force-set 금지*.

---

## 6. Validation per Sub-PR

각 sub-PR done criteria:
- [ ] `dune build --root . @check` clean.
- [ ] `scripts/lint/godfile-size-regression.sh` clean (cap 3350, new_file_cap 600).
- [ ] `scripts/lint/no-ocaml-comment-terminator-trap.sh` clean.
- [ ] `scripts/lint/no-yojson-3-dead-arms.sh` clean.
- [ ] `scripts/lint/no-inline-json-kind-name.sh` clean.
- [ ] PR body 에 *self-call site argument table* (PR-4-c only).
- [ ] PR body 에 *Anti-pattern self-check 7-row* (CLAUDE.md §워크어라운드 거부).
- [ ] CI green 후 사용자 ready 결정 대기.

---

## 7. References

- RFC-0136 main spec (`docs/rfc/RFC-0136-keeper-unified-turn-decomposition.md`).
- PR-1 #16604 MERGED — Phase Gate.
- PR-2 #16624 MERGED — Cascade Resolution.
- PR-3 #16643 MERGED — Pre-Dispatch.
- `lib/keeper/keeper_unified_turn.ml` post-PR-3 (1742 LOC).
- `scripts/lint/godfile-size-regression.sh` — new_file_cap 600.
- memory `feedback_stack_pr_force_base_main_anti_pattern.md` — stack PR sequencing.
