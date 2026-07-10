---
rfc: "0315"
title: "Wake-turn self-description & self-directed work lane"
status: Draft
created: 2026-07-07
updated: 2026-07-07
author: vincent
supersedes: []
superseded_by: null
related: ["0303", "0310", "0313", "keeper-proactive-wake-actionability-invariant"]
implementation_prs: []
---

# RFC-0315: Wake-turn self-description & self-directed work lane

깨어난 keeper가 (1) 왜 깨어났는지, (2) 무엇을 쥐고 있는지, (3) 상시 목표가 무엇인지 아는 턴을 만든다.

## 1. Problem

운영자 관측: keeper가 턴을 마치고 ~2분 뒤 다시 깨어나면 "길을 잃은 것처럼" 아무것도 하지 않는다. 기대 동작은 (a) 진행하던 작업 재개, (b) 그 사이 쌓인 큐/메시지 소비, (c) 다른 작업 인수, (d) 이 모두가 없을 때 Soul/instructions 기준의 자기 주도 작업이었다.

2026-07-07 6-렌즈 조사(코드 5렌즈 + 런타임 24h 실측, 근본원인 후보 14건 적대 검증 — 반박 0건)로 확인된 결함은 5개 군이다.

### D1. Dispatch amnesia — 턴은 자기가 왜 깨어났는지 모른다

- 스케줄러의 typed verdict는 dispatch에서 소멸: `keeper_heartbeat_loop_cycle.ml:58-63`이 `turn_decision` 전체를 받고도 `~channel:turn_decision.channel`만 전달. `run_keeper_cycle`(keeper_unified_turn.mli)에 verdict 파라미터가 없다.
- `build_prompt`는 cycle decision을 `reactive_wake=false`, `event_queue_triggers=[]` 기본값으로 **재계산**(`keeper_unified_prompt.ml:794-796`). 실제 발화 결정과 diverge.
- 결과: event-queue stimulus(Bootstrap / No_progress_recovery / Schedule_due / Connector_attention)로 발화한 턴은 wake-reason 섹션이 **아예 렌더되지 않는다**. Bootstrap/No_progress/HITL stimulus는 intake에서 pending event도 0개 주입 — 모델 입력 어디에도 깨어난 이유의 흔적이 없다.

### D2. Task blindness — 턴을 admit한 작업이 프롬프트에 없다

- `proactive_work_signal_present`(keeper_world_observation.ml:1221-1234)는 `Option.is_some meta.current_task_id`를 기회 신호로 인정한다. 즉 claim된 task가 cadence 턴을 admit한다.
- 그러나 user message의 11개 레이어(Active_goals … Board_activity) 어디에도 current task를 렌더하는 레이어가 없다. `current_task_id`는 claim/task-create guidance를 **끄는 데만** 사용(keeper_unified_prompt.ml:692,700).
- 결과: "claim한 task 때문에 깨어났지만, 그 task가 무엇인지는 듣지 못하는" 턴.

### D3. Erased past — 실패한 턴일수록 흔적이 지워진다

- Replay-suffix prune: completion-contract `requires_attention`(Violated / Surface_mismatch / No_capable_provider / Claim_only_after_owned_task / Needs_execution_progress) 또는 synthetic-[STATE]+빈 응답으로 끝난 턴은 체크포인트가 **턴 이전 prefix로 되돌려 저장**된다. 막혀서 고생한 턴일수록 다음 턴에 그 기록이 없다.
- synthetic-[STATE] 턴은 memory-bank note 0건 + progress snapshot 미갱신 — 메모리 경로로도 생존하지 않는다.
- working_state sidecar 복원 경로는 write-only(다음 sidecar 파일에만 merge, 프롬프트에 미도달, `keeper_agent_run_sidecar.ml:117-136`).
- Continuity 레이어는 backward 필드(Done/Progress/Decisions)와 "inert next" 라인을 의도적으로 strip(keeper_unified_prompt.ml, echo-loop 방지) — 이전 턴이 "대기" 결론이었으면 다음 턴 continuity는 사실상 빈 값.

### D4. Standing objectives empty — Soul 기준으로 일할 근거가 배선돼 있지 않다

- goals는 wake 신호가 아니다(`proactive_work_signal_present`에 goal 항 부재).
- 함대 실측: 관측된 전 턴(~896턴)에서 `active_goals=0`. keeper별 `active_goal_ids`가 사실상 전원 빈 배열(goal store에는 active goal 79개 존재 — 배정 흐름 부재).
- goal이 렌더될 때도 bare ID뿐(user message `format_goals`), 자기주도 지시는 **goal 없는 keeper에게만** 존재("You have no active goal. … Do not stay silent"). goal 있는 keeper는 "Nothing genuinely actionable? End with [STATE]"만 받는다.
- goal-directed idle 트리거(IdleTimeout/StrategicReview/SelfDirectedExplore)를 가진 `keeper_deliberation.ml`은 호출부 0의 dead code. RFC-0310의 goal loop는 supervisor-side Python 스케줄러로 keeper 턴에 미주입.

### D5. Inverted idle economics — 침묵은 설계이고, 공회전은 비싸다

- 신호 없는 keeper: RFC-0303 Phase 2 게이트(`should_run`, keeper_world_observation.ml:1459-1465)로 **영원히 Skip{No_signal}** — Soul-fallback 트리거가 설계상 없다.
- 신호가 상수인 keeper: `current_task_id`(claim된 채 blocked)가 기회를 상시 true로 만들어 cadence 턴이 계속 열린다. 24h 실측(5 keeper, 893턴): zero-tool 턴 48%, read-only poll 23%, 실질 write 25%; 입력 토큰 46.9M 중 67%가 무실질 턴. executor는 69연속 zero-tool 턴(7.6h, 동일 문구 59회, $0.56) — 과거 operator 선호("막히면 zero tool calls")가 메모리로 재주입되며 무행동을 교리화.
- claim 깔때기: claimable 제시 337턴 중 실제 claim 48건(5.4%) — 메모리 학습 제약("re-claim 금지" 등)으로 자기 거부.
- 부가 증폭기: noop backoff 2^n(정직한 defer를 벌), 배포 config `min_interval_sec=3600`(코드 기본 900의 4배), visibility gate(관찰자 0이면 idle dispatch 900s 백오프), `MASC_KEEPER_MAX_SILENCE_SEC`(120)는 `_max_silence` 미사용 바인딩의 dead knob — 사용자가 인지한 "120초"의 실체는 `default_proactive_idle_sec=120`.

### 비교 기준선 (openclaw / Claude Code)

| 메커니즘 | openclaw | Claude Code | MASC 현재 |
|---|---|---|---|
| 타이머 wake의 표준 payload | HEARTBEAT.md 지시 + 명시적 no-op 토큰 | /loop·schedule이 프롬프트 재전달 | 없음 (D1) |
| wake 턴의 대화 연속성 | 메인 세션 히스토리 공유 | 세션 체크포인트 | 있으나 실패 턴 소거 (D3) |
| 상시 지침 재로드 | AGENTS.md/SOUL.md 매 세션 | CLAUDE.md 매 세션 | instructions 단일 필드 (RFC-0282 이후) |
| idle의 비용 | 체크리스트 비면 API 호출 skip, no-op 토큰 드랍 | — | 풀 LLM 턴 또는 영원한 침묵 (D5) |
| wake cadence | 30m 기본 | 사용자 지정 | 실효 100-120s 급 knob들 |

## 2. Principles (제약)

1. **RFC-0303 유지**: per-turn progress boolean 부활 금지, blind cadence 부활 금지. "턴은 정의상 활동"이라는 관점을 유지한다.
2. **판단은 LLM 경계**: 코드는 사실(깨어난 이유, 쥔 작업, 목표, 인박스)을 배달하고, 무엇을 할지는 모델이 결정한다. defer도 유효한 결정이다.
3. **존재 불변(RFC-0313)**: 실패는 존재를 바꾸지 않는다 — 턴 **기록**에도 같은 불변식을 적용한다(막힌 턴의 역사 소거 금지, Phase 2).
4. **Additive-first**: admission 의미론 변경 없는 프롬프트/배선 개선을 먼저, wake 의미론 변경은 후속 phase로 분리.

## 3. Design

### Phase 1 — Turn self-description (본 RFC의 구현 PR)

admission 의미론 불변. 프롬프트 입력만 바로잡는다.

- **P1a Decision threading**: `run_keeper_cycle`에 `?turn_decision` 추가, heartbeat loop가 스케줄러의 실제 decision을 전달, `build_prompt`는 제공 시 재계산 대신 사용. Reactive 채널도 wake reason을 렌더(기존: Scheduled_autonomous만).
- **P1b Current Task layer**: `Keeper_context_layers.Current_task` 신설(Active_goals 직후). `meta.current_task_id` → backlog 레코드 해석(`read_current_task`, 실패 시 None + 계측). 렌더: id/title/status/handoff summary/next step + "이어서 하거나, 막혔으면 blocker를 명시하고 handoff와 함께 release하라" 지시.
- **P1c Goal titles**: turn runner가 `Goal_store.get_goal`로 (id,title) 해석, user message Active Goals 레이어가 title 렌더(legacy bare-id는 fallback 유지).
- **P1d Self-direction parity**: goal 보유 keeper에게도 무자극 턴 지시 추가(goal 분해→task 생성/claim, 진행 업데이트 게시, blocker 명시). defer 유효성 명문화("이유를 [STATE]에").
- **P1e Open Loops layer**: working-state ledger(`keeper_working_state`, TLA `KeeperWorkingStateLifecycle`)의 active loop을 `Working_state` 레이어로 렌더. ledger는 sidecar로 영속·resume-merge까지 되면서 프롬프트로는 한 번도 읽히지 않았다(.mli 선언대로 "checkpoint injection은 후속 배선"이었으나 미착지 — write-only theater의 배선 완성). latest 경로는 `Keeper_agent_run_sidecar.latest_working_state_path` SSOT.

### Phase 2 — Continuity that survives failure

- **P2a (구현: no-[STATE] interruption note)**: prune 자체는 유지하되(오염 replay 방역은 정당) 손실을 continuity 파이프로 복구 — no-snapshot 턴에서 progress.md를 제자리 증강(기존 forward 필드 보존 + "이전 턴이 상태를 남기지 못함, 재검증 후 행동/사유 defer" open question 1개, 상수 텍스트로 dedupe). 다음 턴 Continuity 읽기 체인 1순위가 이를 렌더.
- 잔여: replay prune reason의 typed 관통(현재 manifest 텔레메트리에서 소멸)과 reason별 노트 구체화, generation bump 시 short-term snapshot 드랍 정책 재검토, corrupt checkpoint의 silent fresh-context를 관측 가능한 이벤트로. (working_state sidecar 배선은 P1e로 이동 완료.)

### Phase 3 — Standing-objective lane (자기 주도 턴)

- goal을 **edge-gated** 기회 신호로 승격: goal 배정/갱신/stagnation-wake(RFC-0310 §3.3) 이벤트가 신호를 만들고, 상수 레벨 신호로는 cadence를 admit하지 않는다(D5의 executor-spin 재발 방지 — level→edge 원칙은 current_task_id에도 적용 검토).
  - **W0 (구현 PR #23563)**: `Keeper_event_queue.Goal_assigned` — keeper_up의 `active_goal_ids` 변경 커밋 직후 old/new diff의 **추가분만** 1회 wake(typed lane, `Goal_verification_failed` 선례). identity는 display 필드 strip으로 goal 단위 dedupe. TOML reconcile 경로는 의도적 제외(overlay ids는 영속되지 않아 매 ensure마다 재발화하는 level 신호가 됨 — TOML 목표는 상시 구성이지 배정 이벤트가 아님).
  - **W1 (구현: Goal_stagnation edge = RFC-0310 §3.3)**: 초기 W1은 `should_run`에 자기주도 *타이머* disjunct를 넣는 안이었으나, 적대 검증(2026-07-08)이 두 P1을 확정 — ①phase-blind(완료/드롭 goal에도 영원히 발화) ②noop backoff 우회. 이는 본 §3 리드 불릿("상수 레벨 신호로는 cadence를 admit하지 않는다")과 정면 충돌하는 blind cadence 부활이었다. **폐기하고 순수 edge로 재설계**: live(Executing) goal의 `updated_at`이 threshold(기본 3600s, `keeper.goal.stagnation_threshold_sec`)를 넘으면 `Keeper_event_queue.Goal_stagnation`을 1회 발화. 타이머를 `should_run`에 추가하지 않아 RFC-0303의 "no blind clock" 불변식이 문자 그대로 유지된다. episode 키 = (goal_id, `gs_stale_since`=updated_at): goal이 진행되면(updated_at bump) 새 episode, 미진행이면 동일 episode가 live-queue identity dedup + reaction-ledger `turn_started_seen` 가드로 **episode당 1회만** 발화(consume 후 재발화 없음). detector는 heartbeat tick의 producer 스캔(`Keeper_goal_stagnation_wake`), W0의 intake lane 재사용. phase 게이트=`Goal_phase.admits_self_directed_progress`(Executing만; terminal/paused/blocked/awaiting는 깨워도 진행 불가라 제외). 무행동 방지 payload는 P1의 goal title/지시 패리티가 담당.
- goal 배정 흐름: operator/supervisor가 `active_goal_ids`를 실제로 채우는 표면(대시보드/도구) — 현재 함대 전원 빈 배열인 근본 원인 해소. 배정 표면 자체는 존재(keeper_up args + TOML); W0로 배정이 keeper에게 **들리게** 됨.
- `keeper_deliberation.ml` dead code 정리: 삭제하고 SelfDirectedExplore 의미론은 본 lane으로 흡수.
- **Cheap-defer 계약**: 무자극 자기주도 턴에서 모델이 typed defer로 응답하면 낮은 비용 terminal로 처리하고 noop backoff로 벌하지 않는다(openclaw HEARTBEAT_OK 등가). 이는 cap/cooldown 추가가 아니라 기존 backoff의 오발동 제거다.

### Phase 4 — Amplifier cleanup

- `MASC_KEEPER_MAX_SILENCE_SEC` dead knob 제거 또는 실사용 배선(현재 `_max_silence` 미사용).
- `effective_scheduled_autonomous_cooldown`의 "prevents permanent silence" 주석은 Phase 2 게이트 이후 거짓 — 문서/코드 화해.
- 배포 config `min_interval_sec=3600` vs 코드 기본 900 drift, visibility gate 기본값: **운영자 결정** 항목으로 표면화.
- librarian 무행동 교리 플라이휠(durable 태그의 Self_observation 에코필터 우회)은 별도 RFC로 봉합.

## 4. Non-goals

- blind cadence(무자극 자동 턴) 부활 — Phase 3의 자기주도 턴도 standing objective라는 실체 있는 자극에 gate된다.
- per-turn progress/no-progress 판정 부활 (RFC-0303 존중).
- 신규 cap/cooldown/dedup 도입.
- memory OS 소비/증류 정책 변경 (별도 RFC).

## 5. Verification

Phase 1 (구현 PR):

- `test_keeper_context_layers`: Current_task 레이어의 순서/전단사 불변식.
- `test_keeper_wake_turn_context`(신규):
  - current task 렌더(상태/handoff/지시), 부재 시 미렌더.
  - threaded decision: 빈 world + Bootstrap_stimulus decision → wake-reason 렌더; legacy 재계산 경로는 동일 world에서 blind (전후 대비를 테스트로 고정).
  - goal title 렌더 + legacy bare-id fallback.
  - goal 보유/무goal 각각의 자기주도 지시 존재/부재.

프로덕션 관측 (착지 판정):

- `keepers/<n>.decisions.jsonl`의 zero-tool 턴 비율(현 48%)과 "재확인 완료—변동 없음"류 반복 런 길이(현 최장 69).
- claim_was_available→claim_executed 전환율(현 5.4%).
- ContinuitySummarySource 카운터의 meta_fallback 비중.

## 6. Rollout / Removal targets

- Phase 1: behavior-additive, flag 불요. 즉시.
- Phase 2-3: 각각 별도 PR + 본 RFC 갱신. Phase 3의 wake 의미론 변경은 RFC-0303/0313과 교차 리뷰 필수.
- Removal: `keeper_deliberation.ml`(Phase 3), `_max_silence` dead 바인딩(Phase 4), `build_prompt` 내부 재계산 경로(모든 호출자가 decision을 전달하게 되면).
