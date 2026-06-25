---
rfc: "0294"
title: "Keeper Proactive-Wake Actionability Invariant + Self-Cadence Tombstone Gate"
status: Draft
created: 2026-06-24
updated: 2026-06-24
author: vincent
supersedes: []
superseded_by: null
related: ["0246", "0220", "0233", "0239"]
implementation_prs: []
---

# RFC-0294 — Keeper Proactive-Wake Actionability Invariant + Self-Cadence Tombstone Gate

- Status: Draft
- Area: `lib/keeper/` (world observation, proactive scheduler, no-progress detector, wake tombstone), `lib/workspace/` (orphan surfacing)
- Evidence: live incident — keeper `executor` livelocked 2026-06-21T08:09Z → 2026-06-24T07:44Z (619 autonomous turns, ~100s cadence, all terminating `success`), reconstructed from the runtime base path's `keepers/executor.decisions.jsonl` (failed_task trigger on 400/400 recent turns, `claimable_task_count==0` on 327, `failed_task_count` 2–3 never 0) + `tasks/backlog.json` + `events/2026-06/` (GC `zombie_cleanup` absent 06-21/06-22). Design hardened against 5 independent adversarial critics (correctness, RFC-0246 alignment, workaround-bar, scope, test-harness).

## 1. Summary

keeper의 자율 스케줄러가 **자신이 clear할 수 없는 level-triggered 신호**(`failed_task`)에 깨어나 무한 no-op 턴을 도는 livelock을, **구조적 actionability 불변식**으로 막는다:

> *advisory-only affordance(task/world 상태를 변경하는 도구를 0개 가진 affordance)에 대응되는 신호는 어떤 proactive-wake 술어에도 기여할 수 없다.*

이 불변식(R1g)이 1차(source) 수정이다. 추가로, 미래의 다른 unclearable 신호에 대비한 backstop으로 (R2a) 무진행 판정의 잔존 blind spot을 닫고 (R2b) RFC-0246 wake-tombstone을 **self-cadence `should_run` 경로**까지 확장한다. R1g가 keeper가 orphan을 surface하던 유일한 경로를 제거하므로, keeper wake와 독립적인 **단일 소유 orphan surfacer**를 필수 보완으로 추가한다.

## 2. Motivation — the class bug

### 현상
`executor` keeper가 3일간 619턴을 동일 조건으로 반복했다:

```
trigger_signals:       ["failed_task"]      # 절대 안 꺼지는 level 신호
observed_affordances:  ["task_audit"]       # 상태를 못 바꾸는 read-only affordance
observation:           failed_task_count=2..3, claimable=0, idle≈100s
terminal_reason:       success              # 매 턴 "성공" → 어떤 실패 카운터도 안 올라감
```

keeper는 메타-자각 상태("I need to stop repeating", "Acknowledged. I was stuck in a severe loop")였으나 스케줄러가 ~100s마다 다시 깨워 멈출 수 없었다.

### 근본 (typed 관점)
`failed_task_count > 0`(orphan task: Claimed/InProgress/AwaitingVerification가 zombie/absent agent에 묶임)은 keeper의 4개 proactive-wake 술어 전부에 disjunct로 들어가 있다:

| 술어 | 위치 | failed_task 포함 |
|---|---|---|
| `durable_signal_present` | `keeper_world_observation.ml:845` | ✅ (heartbeat-loop:520이 `Skip_idle→Emit` 강제) |
| `actionable_signal_present` | `keeper_world_observation.ml:856` | ✅ |
| `proactive_work_signal_present` / `task_backlog_signal` | `keeper_world_observation.ml:865` | ✅ |
| `has_actionable_tasks` | `keeper_world_observation.ml:1010` | ✅ (`backlog_elapsed` ~100s 구동) |

그러나 이 신호가 keeper에게 부여하는 유일한 affordance는 `Task_audit`이고, 그 도구 셋(`keeper_agent_tool_surface.ml:79-80`: `keeper_tasks_audit; keeper_tasks_list; masc_tasks`)은 **전부 read-only**다. orphan 해소는 비-keeper(orchestrator zombie pulse `cleanup_zombies` + supervisor sweep)의 책임이다. 즉 **정책(무엇이 proactive 턴을 구동하는가)과 능력 분류(affordance가 신호원을 mutate할 수 있는가)가 코드 레벨에서 분리되어 있지 않아, illegal state("clear 불가 신호가 wake driver가 됨")가 표현 가능하다.**

### 왜 안전망이 안 잡았나
- 무에러 text 턴은 `terminal_reason: success`(`keeper_unified_metrics_decision.ml:105`)로 종료 → 실패 카운터/에스컬레이션 미발동.
- `is_noop_cycle = not has_text && ...`(`keeper_unified_metrics_support.ml:285`)은 cooldown multiplier 전용이며, text 턴마다 `consecutive_noop_count`를 0으로 리셋.
- 무진행 loop detector(`keeper_no_progress_loop_detector.ml`)는 streak 10에 latch하지만 — `classify_delivery`(`keeper_unified_turn_success.ml:110-118`)가 `tools=[] && has_visible_text=true → User_facing → delivery_requires_evidence=false → made_progress=true → streak 리셋`. 자율 no-op text 턴이 매번 진행으로 오분류돼 **영영 latch하지 못한다**.
- RFC-0246 wake-tombstone은 외부 wake 진입점(`keeper_registry.ml` `wakeup`/`board_wakeup_allowed`)만 게이트하고 **self-cadence `should_run` 경로는 게이트하지 않는다**(검증: `keeper_world_observation.ml`/`keeper_heartbeat_loop_scheduling.ml`에 tombstone 참조 0건).

## 3. Design

### R1g (PRIMARY, structural) — advisory-only affordance never drives proactive wake

특수 케이스(`failed_task`만 4곳에서 hand-delete)는 **거부**한다 — N-of-M 안티패턴(RFC-0233 거부 클래스, `COMMON-PITFALLS` sweep 위반)이며 미래 read-only 신호가 동일 livelock을 재도입할 때 컴파일 강제가 없다.

**SSOT 술어** (`keeper_agent_tool_surface.ml`, `turn_affordance` 닫힌 sum의 exhaustive match):

```ocaml
(** [affordance_can_mutate aff] = keeper가 이 affordance로 task/world 상태를
    변경(=신호원 clear)할 수 있는가. turn_affordance 닫힌 sum의 exhaustive match —
    새 affordance 추가 시 컴파일 타임에 결정 강제. Task_audit 만 advisory-only:
    그 도구(keeper_tasks_audit/list, masc_tasks)는 read-only 라 깨어난 신호를
    clear 할 수 없다. tools_for_affordance 와의 일관성은 T2 가 pin. *)
let affordance_can_mutate = function
  | Board_curation | Board_post_or_comment | Message_sweep
  | Task_claim | Task_verify -> true
  | Task_audit -> false
```

**왜 exhaustive match인가 (per-tool `effect_domain` 재사용을 거부한 이유):** `keeper_task_claim`/`keeper_task_done`/`masc_transition`은 전부 `effect_domain = Masc_workspace`인데, 기존 `is_mutating_tool`(`keeper_tool_progress.ml:75-77`)은 `Masc_workspace → false`(durable-evidence 축)로 분류한다. 그 oracle을 재사용하면 `Task_claim`/`Task_verify`가 advisory-only로 **오분류돼 정당한 wake driver가 죽는다(P0 회귀)**. "task-state mutation" 축과 "durable-evidence" 축은 다른 의미축이다 — 닫힌 affordance sum 위의 명시적 match가 정답이며, per-tool effect_domain의 `None`/`Masc_workspace` 모호성을 런타임에서 제거한다.

**적용** (`keeper_world_observation.ml`): 각 task-signal을 affordance로 게이팅한 named 헬퍼로 교체:

```ocaml
let claimable_drives o = o.claimable_task_count > 0 && affordance_can_mutate Task_claim
let failed_drives o    = o.failed_task_count > 0   && affordance_can_mutate Task_audit  (* = false *)
let verification_drives o = o.pending_verification_count > 0 && affordance_can_mutate Task_verify
```

4개 술어(845/856/865/1010)의 task-count 항을 위 헬퍼로 치환. `failed_drives`는 정적으로 false지만 **불변식을 통해 표현**되므로 (a) Task_audit가 mutating 도구를 얻으면 자동 재활성화되고 (b) reader가 게이트를 본다.

**845는 MANDATORY**: `keeper_heartbeat_loop.ml:520`이 `durable_signal_present`로 `Skip_idle→Emit`를 강제하는 2차 livelock 경로. 빠뜨리면 heartbeat-emit livelock 잔존.

**병렬 결정면**: `keeper_deliberation.ml:219/429/464`도 `failed_task_count>0`을 `FailedTask` 트리거로 사용 (dual-definition). 동일 불변식 적용 또는 `.mli`에 advisory/non-wiring 명시 + `test_keeper_deliberation.ml:98-104,145-156` 갱신 (PR-2).

**prompt-surface**: R1g 후 cadence는 ~100s→~900s(min_interval housekeeping)로 줄지만, `keeper_unified_prompt.ml:855/635/888`이 여전히 failed task를 프롬프트에 주입해 no-op audit text를 유도. `:888`을 "GC-owned telemetry, no keeper action"으로 relabel, `:855/635`에서 failed_task actionable 게이트 제거, `observed_affordances_of_observation`(`:480`)에서 failed_task 단독 시 `task_audit` drop (PR-3).

**`pending_verification`은 유지**: `Task_verify`는 `keeper_task_done`/`masc_transition`(mutating)을 가지므로 verify-구동 wake는 신호를 clear할 수 있다 — 같은 버그 클래스가 아니다. 명시적 회귀 테스트로 보호.

### R2a (defense-in-depth) — autonomous no-tool prose turn requires evidence

candidate의 "is_noop_cycle has_text blind spot 수정" 전제는 **반증됨**: (i) `is_noop_cycle`은 cooldown 전용이라 고치면 livelock을 늦출 뿐(금지 cap); (ii) loop detector의 `turn_made_progress`(`keeper_no_progress_loop_detector.ml:57`)는 has_text를 입력으로 받지 않아 이미 올바르다.

진짜 잔존 blind spot은 `classify_delivery`의 `User_facing` 면제다. **구조적 수정**: 닫힌 `turn_delivery` sum을 확장해 *자율(self-cadence, 외부 프롬프트 없는)* 무도구 prose 턴을 evidence-불요 면제에서 분리(예: `Autonomous_prose` variant). `delivery_requires_evidence`는 exhaustive match(no catch-all)라 새 variant가 분류를 컴파일 강제.

**False-positive 가드**: operator-mention에 대한 정당한 no-tool text 응답(`Reply_to_external`)은 면제 유지. 분기는 *외부 프롬프트 부재*에 게이팅.

### R2b (defense-in-depth, MANDATORY gap) — wire wake-tombstone into self-cadence should_run

RFC-0246 tombstone은 외부 wake 두 경로(`keeper_registry.ml:364 Heartbeat`, `:438 Board_reactive`)에만 배선됐고 self-cadence `should_run`엔 없다(`bypasses_tombstone = Operator_direct|Mention`). 수정: `keeper_heartbeat_loop_scheduling.ml:40`에서 `should_run` honor 직전(또는 `keeper_cycle_decision` 최종 게이트)에 `Keeper_wake_tombstone.decide`를 경유. self-cadence `wake_origin`을 추가하되 `bypasses_tombstone`에 넣지 않음. 닫힌 `wake_decision` sum의 `Suppressed` arm을 exhaustive match로 무시 불가하게.

**On-latch = terminal/escalation (cap 아님)**: latch → auto-wake 억제(self-clock 포함 STOP) → board/operator escalate → 진짜 진행(`Loop_reset`) 또는 operator-clear에서만 해제. `effective_scheduled_autonomous_cooldown` noop multiplier를 정지 메커니즘으로 쓰지 않음.

**latch latency 명시**: threshold=10(RFC-0246 Non-goal로 고정) → R2 작동 전 ~10턴(~17분) 낭비. **이것이 R1g가 PRIMARY인 이유** — R1g는 source에서 0턴 차단, R2는 backstop.

## 4. Workaround-bar self-check (CLAUDE.md)

| 레이어 | 구조적 근거 | 회피 클래스 |
|---|---|---|
| R1g | `affordance_can_mutate` exhaustive match SSOT + T2 일관성 pin | N-of-M ❌(4-라인 hand-delete 거부), string-classifier ❌(변수 set 아님) |
| R1g prompt-surface | 동일 불변식의 prompt 면 적용; failed_task를 "GC-owned" telemetry로 *relabel* | telemetry-as-fix ❌ |
| R2a | 닫힌 `turn_delivery` sum 확장 + exhaustive match | cap ❌(N개 text 후 latch 아님) |
| R2b | 닫힌 `wake_decision`/`wake_origin` 재사용, `Suppressed` exhaustive | cap/cooldown ❌(terminal tombstone, noop multiplier 미사용) |

**라벨드 WORKAROUND**: `is_noop_cycle` has_text reset과 noop cooldown multiplier는 본 수정 비포함. stale `8x` 주석(`keeper_world_observation.ml:890`, 실제 4x)은 별도 1-라인 doc 정정(PR-7).

## 5. Scope + mandatory complement

**범위**: keeper scheduler 불변식(R1g) + 무진행 판정(R2a) + self-cadence tombstone(R2b) + orphan 가시성 보완.

**필수 보완 — orphan surfacer**: R1g는 `audit_orphan_tasks`의 유일한 두 호출자(keeper wake-driver `keeper_world_observation_inputs.ml:74`, read-only audit handler `keeper_tool_task_runtime.ml:383`)를 wake에서 끊는다. `Dashboard_attention.collect`는 `audit_orphan_tasks`를 호출하지 않으므로(검증), 보완 없으면 orphan이 **silent invisible**(broken-but-visible → blind 회귀)이 된다. keeper wake와 독립적으로 `audit_orphan_tasks`를 읽는 **단일 소유 surfacer**(emitted gauge `masc_orphan_tasks_total`, status-class 라벨, orchestrator/zombie pulse가 갱신)를 추가. reaper 자체가 죽을 수 있으므로(06-21/22 실증) actor wake가 아닌 alertable metric. R1g가 *제거한* 가시성을 *대체*하므로 anti-telemetry-as-fix 바 위반 아님(R1g가 구조적 primary).

**S3 (AwaitingVerification orphan) 가시성 in-scope**: `cleanup_zombies` Phase 3(`workspace_gc.ml:184`)은 `AwaitingVerification`을 release하지 않고, 구 rescue `Verification_protocol.check_timeouts`는 dead no-op(`verification_protocol.ml:377-380`, RFC-0220 §5). 그러나 `audit_orphan_tasks`(`workspace_query.ml:158`)는 이를 orphan으로 카운트 → `failed_task_count`가 영영 0으로 안 돌아옴. R1g 단독이면 이 클래스는 permanently-nonzero-but-invisible → surfacer가 AwaitingVerification status-class를 **명시적으로 커버**.

**Non-goals (follow-up)**:
- GC liveness under fiber starvation (06-21/22 reaper 미실행 원인) → 별도 RFC (surfacer가 metric이면 정체 자체가 alertable).
- GC Phase 3에 dead-assignee AwaitingVerification *release* 추가 → S3-release follow-up (RFC-0220 §5 event-stream 의도와 정렬 필요).
- runtime ws-direct writer livelock → 무관.

## 6. Verification harness

### 단위 테스트

- **T1** `test/test_keeper_failed_task_not_proactive_driver.ml`
  - `test_failed_task_alone_does_not_drive_proactive_turn`: warm non-bootstrap meta, `failed_task_count=2, claimable=0, all else 0`, **`last_ts=now-200`(since_last ≥ task_reactive_cooldown), `backlog_updated_since_last_scheduled_autonomous=true`** → `should_run = false`. (revert-red: R1g 전엔 `has_actionable_tasks`/`backlog_elapsed`로 true. ⚠️ `since_last=30` clone은 pre-fix에 이미 green → 무효.)
  - `test_claimable_still_drives_after_cooldown`: `claimable=1, failed=0`, 동일 타이밍 → `should_run = true` (over-silence 방지).
  - `test_pending_verification_still_drives`: `pending_verification=1, all else 0` → `should_run = true`.
- **T2** `test/test_advisory_only_affordance_never_drives_wake.ml`: 모든 `turn_affordance` constructor 순회, `affordance_can_mutate aff = (tools_for_affordance aff에 task-state-mutating 도구 존재)` 일관성 + advisory-only affordance가 어떤 wake-driver 신호 셋에도 없음을 assert (axis-drift 가드 패턴).
- **T3** `test/test_keeper_failed_task_orphan_does_not_livelock.ml`: `keeper_cycle_decision`을 N회 루프(매 iter `last_ts`를 task_reactive_cooldown 너머 전진, `failed_task_count=2, claimable=0` 정적) → `should_run=true` verdict 수 == 0 (post-R1g). `test_keeper_turn_livelock_10121.ml`(turn-id reattempt 가드, forward advance에 리셋)과 구별 — 재사용 금지.
- **T4** (R2a, `test_no_progress_loop_detector.ml` 추가): `test_autonomous_textonly_noop_accrues_streak`(자율 무도구 prose → `made_progress=false`), `test_operator_mention_textonly_reply_exempt`(외부 mention 응답 → `made_progress=true`).
- **T5** (R2b): `test_tombstoned_keeper_self_cadence_suppressed`(latch×10 후 `should_run=false`), `test_read_heavy_then_write_keeper_not_paused`(threshold-1 무진행 + 1 made_progress → `is_latched=false ∧ should_run=true`).
- **T6** (surfacer): `test_orphan_surfacer_emits_for_awaiting_verification`.

### TLA+ Bug Model

신규 `specs/keeper-state-machine/KeeperProactiveWakeGuard.tla` + `.cfg` + `-buggy.cfg` (`KeeperDecisionPipeline.tla` 템플릿 미러; `KeeperOASAdvanced.tla` 재사용 금지 — OAS bridge 도메인).
- vars: `failed_count, claimable_count, mutating_affordance_for_failed(=FALSE), proactive_fired_for_failed, zero_progress_streak, tombstoned`.
- `BugAction WakeOnUnactionableSignal`: `failed_count>0 ∧ ¬mutating_affordance_for_failed ∧ proactive_fired_for_failed'=TRUE ∧ streak'=streak+1`.
- `SafetyInvariant NeverWakeWithoutMutatingAffordance == proactive_fired_for_failed => mutating_affordance_for_failed` (R1g).
- `SafetyInvariant NoUnboundedZeroProgressStreak == zero_progress_streak <= N` (R2b).
- clean cfg(`Spec`) PASS / buggy cfg(`SpecBuggy == Init ∧ [][Next ∨ BugAction]_vars`, `CHECK_DEADLOCK FALSE`) 두 invariant 위반. 두 cfg 동일 invariant 참조.

## 7. PR breakdown (ordered, 각 PR 독립 green)

| # | PR | RFC 면 | green |
|---|---|---|---|
| **PR-1 (버그 수정)** | `fix(keeper): advisory-only affordance never drives proactive wake (R1g)` — `affordance_can_mutate` SSOT + 4 술어(845/856/865/1010) 게이팅 + T1/T2/T3 + TLA | R1g | T1-T3 + TLA 양 cfg |
| PR-2 | `fix(keeper): remove failed_task from deliberation triage` — `keeper_deliberation.ml:219/429/464` + test 갱신 | R1g 일관성 | dual-def 제거 |
| PR-3 | `fix(keeper): relabel failed_task as GC-owned telemetry in prompt surface` | R1g prompt | prompt 스냅샷 |
| PR-4 | `feat(workspace): single-owner orphan surfacer gauge (covers AwaitingVerification)` + T6 | 보완 | T6 |
| PR-5 | `fix(keeper): autonomous no-tool prose turn requires evidence (R2a)` + T4 | R2a | T4 |
| PR-6 | `feat(keeper): wire wake-tombstone into self-cadence should_run (R2b)` + T5 | R2b | T5 |
| PR-7 | `docs(keeper): fix stale 8x noop cooldown comment` | — | 무빌드 |

**PR-1이 보고된 버그를 수정** — R1g가 source에서 failed_task wake driver를 끊어 619턴 livelock을 0턴 차단.

## 8. Open questions / residual risk

| 항목 | confidence |
|---|---|
| `affordance_can_mutate` exhaustive match가 `tools_for_affordance`와 drift할 위험 → T2가 pin | High |
| 845 미포함 시 heartbeat-loop:520 2차 livelock 잔존 | High |
| R2a `wake_origin`을 `classify_delivery`까지 전달하는 plumbing 비용 | Medium |
| orphan surfacer gauge vs Dashboard_attention 선택 | Medium |
| `turn_delivery` 분할이 다른 소비자에 미치는 영향(exhaustive match가 안전망) | Medium |
| latch latency ~17분(threshold 고정) — R1g primary라 수용 | High |
