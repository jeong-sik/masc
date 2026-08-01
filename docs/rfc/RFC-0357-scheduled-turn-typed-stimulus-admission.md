# RFC-0357 — Scheduled-autonomous 턴은 heartbeat가 아니라 typed stimulus의 변화로 admit한다

- Status: Draft
- Created: 2026-08-02
- Fixes: #26018
- Companion: #26487 (claimability 진실성 — 본 RFC와 직교, 아래 §6)
- Supersedes: RFC-0303의 무조건 admission 절 (한 절만 — §5)
- Related: RFC-0297 (lifecycle gate), RFC-0234 (scheduled automation), #26400 (idle 발화 coalesce), `docs/audit/2026-07-30-keeper-runtime-truth-adversarial-audit.md` §2.4·Phase 4

## 1. 실측 (2026-08-01, build `82396e6af7`)

활성 4 keeper의 metrics JSONL 하루 집계:

| keeper | model 턴 | tool 있는 턴 | tool 0회 턴 | cost_usd |
|---|---|---|---|---|
| sangsu | 1,487 | 29 | 1,458 (98%) | $19.16 |
| rondo | 1,078 | 79 | 999 (93%) | $12.42 |
| code-reviewer | 1,415 | 592 | 823 (58%) | $20.03 |
| kidsnote | 1,475 | 49 | 1,426 (97%) | $27.17 |
| 합계 | 5,455 | 749 | 4,706 (86%) | **$78.77** |

- 입력 토큰 합계 269M/일 (cache hit ~97% 포함 후의 비용이 위 값).
- transition-audit 동일 날짜: FSM 완주 5,463, provider error 16, organic overflow 0 — **에러 루프가 아니라 설계대로 admit된 루프**다.
- 07-30 감사 §2.4는 같은 현상을 kidsnote 단독 221 빈 턴/$2.50로 측정했다. 5일 사이 fleet 기준 31배.

## 2. 원인 (head-pinned)

1. `lib/config/env_config_keeper.ml:460` — heartbeat cycle 기본 30초.
2. `lib/keeper/keeper_heartbeat_loop_scheduling.ml:31` — admission은 `(not stop) && decision.should_run`이 전부. 간격·조건 없음.
3. `lib/keeper/keeper_world_observation.ml:1244-1274` — scheduled 채널은 proactive gate가 켜져 있으면 **무조건 `should_run = true`**. 코드 주석이 독트린을 명시한다: *"A scheduled heartbeat is itself the wake signal … fixed local thresholds never suppress a Keeper cycle."*
4. 같은 파일 1160행 `actionable_signal_present`가 typed stimulus를 이미 열거하지만 admission에 쓰이지 않는다. run_reasons(`Task_backlog`, `Scheduled_automation_due`)는 주석(annotation)일 뿐 게이트가 아니다.
5. `since_last_scheduled_autonomous`는 로그 포맷(`keeper_heartbeat_loop.ml:641`)에만 소비된다.

결과: 30초마다 "일이 없음을 확인하기 위해" provider를 호출한다.

## 3. 결정

### 3.1 Admission 술어

scheduled-autonomous 채널의 admission을 다음으로 교체한다 (전부 기존 typed 필드):

```
should_run =
     Never_started                                      (bootstrap, generation당 1회)
  ∨ pending_messages ≠ []
  ∨ pending_board_events ≠ []
  ∨ backlog_updated_since_last_scheduled_autonomous     (task 백로그 변화의 edge)
  ∨ scheduled_automation.due_ready_count > 0
```

전부 거짓이면 `Skip { reasons = No_actionable_stimulus }` (신규 typed skip reason). Reactive 채널, `Manual_compaction_pending`, lifecycle gate(RFC-0297)는 불변. presence heartbeat·snapshot·board scan은 지금처럼 30초 cadence로 계속 돌되 **provider 턴을 열지 않는다** (heartbeat metrics row는 유지).

### 3.2 Level이 아니라 edge인 이유

`claimable_task_count > 0`·`failed_task_count > 0` 같은 **pool 수치(level)는 admission 입력에서 제외**한다 (모델에게 주는 관측으로는 유지). level로 admit하면 모델이 "할 일 아님"이라고 판단해도 pool이 비지 않는 한 30초마다 재소집된다 — 오늘의 낭비가 정확히 이 형태고, #26487(96개 고착 claimable)이 극단 사례다. `backlog_updated_since_last_scheduled_autonomous`는 이미 존재하는 durable edge다(`keeper_world_observation_inputs.ml:8` — `backlog.last_updated > proactive_rt.last_ts`): 백로그 **변화당 1턴**만 소집하고, 정적 백로그는 0턴이다.

같은 파일의 self-authored-todo 제외(taskmaster가 자기가 만든 367개 태스크로 자기 루프를 돈 실증에 대한 수리)가 이 방향의 선례다: 신호는 수치가 아니라 사건이다.

### 3.3 `proactive_rt.last_ts`를 턴 시작 시점으로

현재 last_ts는 턴 종료 시 기록된다(`keeper_unified_metrics_result.ml:71`). 그대로 두면 자기 턴 중의 task 변경(claim, 전이, 진행 기록)이 `last_updated < last_ts`가 되어 다음 턴을 재소집하지 못한다 — 여러 턴짜리 작업의 연속성이 끊긴다. last_ts를 **턴 시작 시점**에 기록하면: 턴 중 자기 durable 변경 → edge 유지 → 다음 턴 admit. 턴이 아무 durable 변경도 남기지 않으면 → edge 소멸 → 침묵. 즉 **연속은 durable 진척이 있는 동안만** 이어진다(자기제한). 크래시 시에도 edge가 남아 at-least-once로 재개된다.

대안(fallback): `own_in_progress_task_count > 0` level 항 추가. 자기 소유 작업은 자기에게 전이 권한이 있어 hot이 bounded지만, "진척 없는 자기 태스크"의 재소집을 허용하므로 1차 채택하지 않는다. 라이브에서 연속성 stall이 실측되면 그때 검토한다.

## 4. 무엇이 아닌가 (RFC-0303이 기각한 것들의 유지)

RFC-0303이 기각한 것은 **출력 품질 휴리스틱**이다: `made_progress` 점수, no-progress counter, 자동 pause, wake tombstone. 본 RFC는 그중 무엇도 추가하지 않는다. admission이 소비하는 것은 **입력 사실의 존재/변화**(pending 목록, durable timestamp 비교, due 카운트)뿐이며, 전부 이미 typed로 계산되는 값이다. 문자열 매칭·카운터·cap·cooldown·적응형 간격 없음.

## 5. RFC-0303과의 관계

- 유지: "LLM이 무엇을 할지 판단한다" — wake 이후의 판단은 계속 모델 소관이다.
- 대체: "heartbeat 자체가 wake signal이다" — 시간의 경과는 사실의 변화가 아니다. 주기적 자율 점검을 원하면 그 cadence는 운영자가 소유한 **Schedule entry**(`scheduled_automation`, RFC-0234)로 명시한다. 그 due가 admission 술어의 disjunct이므로 표현력 손실이 없다.
- RFC-0303 문서에는 이 절의 supersession 주석 한 줄을 남긴다.

## 6. Companion — #26487 (claimability 진실성)

본 RFC는 "언제 소집하는가"를 고친다. #26487은 "claimable이 참인가"를 고친다(sandbox capability 교차검증). edge admission 하에서 #26487 미해결이어도 정적 오염 백로그의 비용은 변화당 1턴으로 떨어지지만, 백로그가 **자주 변하는** fleet에서는 오염된 claimable이 여전히 턴마다 모델의 판단 비용을 소모한다. 완전한 해소는 두 슬라이스의 교집합이다. 본 RFC는 claimability의 정의를 건드리지 않는다.

## 7. Blast radius

- `lib/keeper/keeper_world_observation.ml` — scheduled_autonomous_decision 교체, `No_actionable_stimulus` skip reason 추가(verdict reason variant + to_string), `actionable_signal_present`와 admission의 단일화.
- `lib/keeper/keeper_unified_metrics_result.ml` — last_ts 기록 시점 이동(§3.3).
- 소비자: verdict reason 문자열은 로그·decision ledger로 흐른다. dashboard/src에 skip reason 문자열 union 소비자는 rg로 0건 확인(#26557류 zod 파괴 없음) — 구현 시 재확인.
- 테스트: `test_keeper_raw_task_signal_wake.ml`, `test_keeper_wake_turn_context.ml`, `test_heartbeat_integration.ml` 확장.
- 문서: RFC-0303 supersession 주석, `docs/product/KEEPER-FULL-LIFECYCLE-BEHAVIOR.md` B10(bounded cadence)와 정합 — B10의 기대가 이 RFC로 충족된다.

## 8. 검증

- 단위: 빈 observation + gate on → `Skip No_actionable_stimulus`. 각 disjunct 단독 → `Run`. bootstrap은 generation당 1회. last_ts 시작-시점 기록 하에서 "턴 중 자기 backlog 변경 → 다음 턴 admit, 무변경 → skip" 양방향.
- 라이브 (감사 Phase 4 완료 기준 그대로): 신호 없는 10분간 provider call 0, heartbeat row는 계속 기록. direct message는 즉시 reactive 턴. 정적 백로그 keeper(#26487의 full-cycle-probe 형태)는 부트 후 autonomous 턴 1회 이하.
- 비용: 신호 없는 날의 scheduled 채널 provider 비용 ≈ $0 (오늘 $78.77의 대조 실측을 병합 후 기록).

## 9. 비제안

- no-op counter / cooldown / cap / 적응형 간격 — RFC-0303 기각 유지.
- 턴 전 LLM 사전판단(judge-before-turn) — 판단 비용을 없애려고 판단을 추가하는 순환.
- claimability 재정의 — #26487 소관.
- reactive 채널·gate 의미 변경 — 불변.
- per-keeper backlog 관련성 필터 — 공유 backlog.last_updated의 거친 granularity(한 keeper의 변경이 전 keeper를 1회 깨움)는 인지하되, 변화-bounded이므로 v1에서 수용. 필터는 관련성 판단(비결정)을 요구하므로 별도 논의.
