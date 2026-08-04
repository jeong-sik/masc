# RFC-0357 — Scheduled-autonomous 턴은 heartbeat가 아니라 typed stimulus의 변화로 admit한다

- Status: Withdrawn (2026-08-04)
- Withdrawal: owner 판정 — keeper는 매 턴 task/board/goal 리스트를 직접 관측해 스스로 판단하고, 판이 비어 있으면 각자 능력 범위의 일을 생성한다. 서버측 revision 비교 admission은 그 모델에서 불필요하며, 구현 과정의 실측(consumption cursor 저장 위치를 둘러싼 PR #26690의 13 리뷰 라운드와 close)이 비용이 가치를 초과함을 보였다. PR-0(#26675)의 commit-point 스탬핑은 데이터 위생으로 존치하고, 관측 필드 `backlog_updated_since_last_scheduled_autonomous`는 제거한다. 남는 방향은 admission이 아니라 공급 — keeper instruction의 구체적 상시 목표.
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

`claimable_task_count > 0`·`failed_task_count > 0` 같은 **pool 수치(level)는 admission 입력에서 제외**한다 (모델에게 주는 관측으로는 유지). level로 admit하면 모델이 "할 일 아님"이라고 판단해도 pool이 비지 않는 한 30초마다 재소집된다 — 오늘의 낭비가 정확히 이 형태고, #26487(96개 고착 claimable)이 극단 사례다. `backlog_updated_since_last_scheduled_autonomous`는 이미 존재하는 durable edge다(`lib/keeper/keeper_world_observation_inputs.ml:8` — `backlog.last_updated > proactive_rt.last_ts`): 백로그 **변화당 1턴**만 소집하고, 정적 백로그는 0턴이다.

같은 파일의 self-authored-todo 제외(taskmaster가 자기가 만든 367개 태스크로 자기 루프를 돈 실증에 대한 수리)가 이 방향의 선례다: 신호는 수치가 아니라 사건이다.

**edge의 비교 축은 시각이 아니라 revision이다.** 현행 비교(`lib/keeper/keeper_world_observation_inputs.ml:8-20`)는 `backlog.last_updated`(string)를 ISO8601 **파싱해 얻은** float를 벽시계 `last_ts`와 엄격 부등호로 비교한다. 이를 admission에 승격하지 않는다 — 결함 넷:

1. **동률 붕괴**: stamp는 턴 시작, durable 변경은 턴 중이라 두 값이 구조적으로 가깝다. 초 단위 눈금에서 빠른 턴(claim 후 즉시 전이)의 변경이 stamp와 같은 눈금에 들어가면 엄격 `>`가 거짓 — 이 RFC가 지키려는 멀티턴 연속성이 정확히 빠른 턴에서 깨진다.
2. **시계 역행**: NTP 보정으로 벽시계가 뒤로 가면 edge가 소실되거나 영구 생존한다.
3. **영점의 level 강등**: `last_ts <= 0.0` arm은 `backlog.tasks <> []`로 판정한다 — 기준점 없는 keeper(최초 기동·리셋)는 백로그가 비지 않는 한 매 주기 admit되는, 정확히 본 RFC가 없애려는 level admission이다. revision 비교에선 이 특수 arm이 자연 소멸한다(`0 < current_revision`은 최초 1회 참, 소비 후 거짓).
4. **파싱 Silent Failure**: `parse_iso8601_opt` 실패 시 `| None -> false` — 그 keeper는 백로그 변경으로 영원히 깨어나지 않고 진단도 남지 않는다. revision 비교에선 파싱 단계 자체가 없다.

저장소 선례: board cursor는 float 단독이 아니라 타이브레이커를 동반하고(`lib/board/board_core.mli:321` `float * string option`), event queue는 단조 int64 revision을 노출한다(`lib/keeper_runtime/keeper_event_queue_state.mli:88`) — float 한 눈금이 유일하지 않음을 이 코드베이스가 이미 인정하고 해결했다.

계약: **backlog 저장소는 커밋마다 단조 증가하는 int64 revision을 노출**하고(벽시계 파생 금지), edge 판정은 `backlog_revision > last_consumed_revision`이다. 동률·해상도·역행 문제가 정의상 소멸한다. 기존 bool 필드명(`backlog_updated_since_last_scheduled_autonomous`)은 유지하되 계산이 revision 비교로 바뀐다. `proactive_rt.last_ts`는 텔레메트리로 존속하고, admission 소비 기록은 `last_consumed_backlog_revision`(int64)이 맡는다.

**구현 반경의 정직한 기술 — revision은 선행 슬라이스다.** 실측: backlog 관련 파일에 revision 0건, `last_updated` 타입이 두 모듈에서 갈림(`lib/types_core.mli:291` string vs `lib/workspace/workspace_eio.mli:31` float). 따라서 revision 도입은 durable 커밋 경로·직렬화·스키마에 닿는 독립 작업이며, **admission 교체보다 앞서는 별도 슬라이스(PR-0)로 분리**한다. PR-0은 `last_updated` 타입 이원화 정리를 함께 수행하고, revision 부재 파일의 처리 정책(fail-closed 원칙 하의 스키마 승격)을 자체 설계로 명시한다 — 본 RFC는 그 계약("커밋당 단조 int64")만 고정한다.

### 3.3 edge 소비 기록 — 시점과 주체의 재정의

현재 시각 기반 기준점(last_ts)은 **턴 종료 시**, scheduled 턴뿐 아니라 **meaningful한 board/mention reactive 턴에서도** 기록된다(`lib/keeper/keeper_unified_metrics_result.ml:111-117`). edge admission 하에서 두 성질이 각각 문제다:

1. **종료 기록**: 자기 턴 중의 durable 변경(claim·전이·진행 기록)이 소비 기준점보다 앞서게 되어 다음 턴을 재소집하지 못한다 — 멀티턴 작업의 연속성 단절.
2. **reactive 겸용 기록**(`lib/keeper/keeper_unified_metrics_result.ml:114-115`): 메시지 응답 턴이 그 backlog를 처리했다는 보장 없이 backlog edge를 소비한다 — typed 신호의 침묵 소거.

결정 두 가지:

- **소비 기록 주체는 scheduled-autonomous 턴뿐이다.** reactive arm은 edge 시계에서 제거한다(ProactiveOutcome 카운터 등 텔레메트리는 불변). reactive 턴이 backlog를 변경하면 그 변경이 revision을 올려 edge를 재무장하므로 autonomous 후속 정찰 1턴이 자연히 따라온다.
- **2단계 기록**: admission 시점에 관측한 `backlog_revision`을 `last_consumed_backlog_revision`으로 in-memory 기록, durable 영속은 기존 post-turn meta 쓰기 경로 그대로. 실패 매트릭스:

| 시나리오 | 결과 |
|---|---|
| 정상 완료, 턴 중 durable 변경 있음 | 변경 revision > 소비 revision → 다음 턴 admit (연속) |
| 정상 완료, 무변경 | edge 소멸 → 침묵 (자기제한) |
| 프로세스 크래시 (post-turn 영속 전) | durable 소비 revision = 이전 값 → 재기동 시 edge 생존 → 재소집 (at-least-once) |
| 턴 실패, 프로세스 생존 | in-memory 소비 revision 유지 → 같은 edge로 재소집 없음 |

마지막 행은 의도된 결정이다: 실패 턴의 stamp를 롤백하면 지속 실패(429 등)가 30초마다 같은 edge로 재admit되는 무한 재시도가 된다 — 2026-07-31 컴팩션 807회 루프와 같은 형태다. transient 실패의 재시도는 턴 내부 runtime 슬롯 failover 소관이며, admission은 재시도 기관이 아니다. 소비된 edge의 일은 다음 durable 변화 또는 message/schedule disjunct가 다시 연다.

대안(fallback): `own_in_progress_task_count > 0` level 항 추가. 자기 소유 작업은 자기에게 전이 권한이 있어 hot이 bounded지만, "진척 없는 자기 태스크"의 재소집을 허용하므로 1차 채택하지 않는다. 라이브에서 연속성 stall이 실측되면 그때 검토한다.

### 3.4 침묵의 관측성

skip은 부재가 아니라 레코드다. `No_actionable_stimulus`는 다른 skip reason과 동일하게 keeper decision ledger(`<keeper>.decisions.jsonl`)와 keepalive 로그 verdict로 남고, heartbeat metrics row(`record_kind=heartbeat`)는 계속 기록된다. 운영자는 "설계된 침묵"(Skip 레코드 존재 + heartbeat 지속)과 "고장 침묵"(레코드 자체의 부재)을 레코드 유무로 구분한다.

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
- `lib/keeper/keeper_unified_metrics_result.ml:111-117` — reactive arm을 edge 소비에서 제거, 소비 기록을 admission 시점 in-memory `last_consumed_backlog_revision`(int64)으로 이동(§3.3). `last_ts`와 카운터(count_total, visible_count_total, ProactiveOutcome)는 텔레메트리로 불변.
- backlog 저장소 — 커밋당 단조 int64 revision 노출은 **선행 슬라이스 PR-0**(§3.2: durable 스키마·직렬화·`last_updated` string/float 이원화 정리 포함). admission 슬라이스는 그 위에서 `keeper_world_observation_inputs.ml:8-20`의 시각 비교(영점 level arm·파싱 None arm 포함)를 revision 비교로 교체.
- 소비자: verdict reason 문자열은 로그·decision ledger로 흐른다. dashboard/src에 skip reason 문자열 union 소비자는 rg로 0건 확인(#26557류 zod 파괴 없음) — 구현 시 재확인.
- 테스트: `test_keeper_raw_task_signal_wake.ml`, `test_keeper_wake_turn_context.ml`, `test_heartbeat_integration.ml` 확장.
- 문서: RFC-0303 supersession 주석, `docs/product/KEEPER-FULL-LIFECYCLE-BEHAVIOR.md` B10(bounded cadence)와 정합 — B10의 기대가 이 RFC로 충족된다.

## 8. 검증

- 단위: 빈 observation + gate on → `Skip No_actionable_stimulus`. 각 disjunct 단독 → `Run`. bootstrap은 generation당 1회. §3.3 매트릭스 4행 각각: 연속(변경→재admit)·자기제한(무변경→skip)·크래시 재기동 재소집(durable 소비 revision 이전 값 유지 확인)·실패 턴 비재소집. reactive 턴이 backlog edge를 소비하지 않음(mention 턴 후 미처리 backlog 변경 → scheduled 채널 admit 유지). **빠른 턴 연속성**: admission과 같은 눈금(동일 시각)에 일어난 변경도 revision 증가만으로 재admit — 시각 동률에 의존하는 테스트 금지.
- 라이브: 신호 없는 10분간 provider call 0, heartbeat row는 계속 기록. direct message는 즉시 reactive 턴. Keeper를 기동하지 않는 격리 MCP session/Task lifecycle smoke는 protocol admission만 검증하며, 제품 Full Lifecycle 증거는 `docs/product/KEEPER-FULL-LIFECYCLE-BEHAVIOR.md` §5의 uninterrupted 15단계 계약을 따른다.
- 비용: 신호 없는 날의 scheduled 채널 provider 비용 ≈ $0 (오늘 $78.77의 대조 실측을 병합 후 기록).

## 9. 비제안

- no-op counter / cooldown / cap / 적응형 간격 — RFC-0303 기각 유지.
- 턴 전 LLM 사전판단(judge-before-turn) — 판단 비용을 없애려고 판단을 추가하는 순환.
- claimability 재정의 — #26487 소관.
- reactive 채널·gate 의미 변경 — 불변.
- per-keeper backlog 관련성 필터 — 공유 backlog.last_updated의 거친 granularity(한 keeper의 변경이 전 keeper를 1회 깨움)는 인지하되, 변화-bounded이므로 v1에서 수용. 필터는 관련성 판단(비결정)을 요구하므로 별도 논의.
