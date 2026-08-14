---
rfc: "0380"
title: "대기 나이는 홀더의 사이클을 알아야 한다 — work liveness 축 정정과 transient 실패의 큐 위치 보존"
status: Draft
created: 2026-08-14
updated: 2026-08-14
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0377", "0373"]
implementation_prs: []
---

# RFC-0380: 대기 나이는 홀더의 사이클을 알아야 한다

## 0. Summary

durable 이벤트는 사이클 입구에서만 턴에 투입되고, 사이클 벽시계 시간에는 상한이 없다. 그래서 keeper가 30분짜리 정상 tool 루프를 도는 동안 도착한 이벤트는 반드시 600초 stale 임계를 넘고, health는 `runnable_backlog_stale`/`operator_action_required=true`를 켠다 — 아무것도 고장나지 않았는데. 이 RFC는 두 가지를 바꾼다.

1. **work liveness의 판정 축 정정**: 이벤트 나이만 보던 stale 판정을 "홀더(keeper)가 그 시간 동안 무엇을 하고 있었나"와 함께 투영한다. 진행 중인 사이클이 있으면 그 시작 시각과 wake class를 projection에 싣고, `operator_action_required`는 홀더가 idle인데 이벤트가 방치될 때만 켠다. 새 게이트도, 새 임계값도 없다 — 판정의 축만 사실에 맞춘다.
2. **transient 실패의 큐 위치 보존**: provider의 일시 실패(`Retry_after_observed` / `Rotate_now`)가 나면 지금은 `Defer_to_queue_tail`이 이벤트를 큐 꼬리로 보낸다. 실패 1회가 이벤트 나이를 배로 불린다. 도착 순서는 이미 durable한 사실이므로, transient 실패는 그 순서를 잃지 않는다.

## 1. 원칙 → 설계 강제

| 원칙 | 이 RFC에서의 강제 |
|---|---|
| 7. 게이트 | 신규 게이트 0. 사이클 길이에 cap/timeout을 만들지 않는다 — rondo의 32분짜리 진짜 작업(빌드·파일 편집)은 제품이 원하는 바로 그 행동이다. admission 계약(`keeper_unified_turn.ml:259-285`)은 건드리지 않는다 |
| 9. 매직넘버 | 신규 임계값 0. 기존 `durable_queue_stale_sec`(600s)을 재사용하되 적용 축을 "홀더 idle 구간의 이벤트 방치"로 정정한다 |
| 11. 관측성 | 거짓 경보 억제가 아니라 projection 확장이다. 이벤트 나이는 사실이므로 계속 싣고, `holder_cycle`(시작 시각·wake class)을 추가해 (a) provider 실패로 태운 사이클과 (b) 정상 장기 루프를 운영자가 구분할 수 있게 한다 |
| 8. 레거시 | `work_liveness` 스키마는 v1을 hard cut하고 v2로 교체한다. 호환 reader·이중 발행 없음. requeue 의미 변경도 컷 — 옛 꼬리-이동 행 마이그레이션 없음 |
| MASC autonomy | 과거 evidence를 scheduling gate로 쓰지 않는다: A는 순수 projection이고, B는 이미 존재하는 도착 순서(durable fact)의 보존이지 새 정책이 아니다 |
| 20. 테스트 | acceptance는 feature 왕복(§5)이다: 장기 사이클 시나리오와 transient 실패 시나리오를 큐 상태로 검증하며, 헬퍼 단위 테스트를 늘리지 않는다 |

## 2. 문제 — 실측 (2026-08-14, `~/.masc/logs/system_log_2026-08-14.jsonl`)

같은 헬스 증상(`runnable_backlog_stale`)이 서로 다른 두 경로에서 났다.

**(a) provider 실패가 사이클을 태움** — sangsu 이벤트 `51398c19`(06:14:09Z 도착): 06:25:45Z 사이클 입구에서 소비 → 19분 뒤 `Network error: Broken pipe`로 turn terminal → `source moved to queue tail reason=transient_turn_failure` → 06:49:48Z 재투입 → 06:53:45Z ack. **총 39분 36초**, 그중 꼬리 이동이 나이를 배로 불렸다. kidsnote `1ef615b1`도 동형(34분 07초).

**(b) 정상 장기 tool 루프** — rondo 06:50:22Z `idle -> phase_gating action=StartTurn` 후 23회 provider turn으로 실제 빌드·파일 편집을 수행, 32분+ 동안 실패 0건. 그 뒤에 도착한 이벤트 3건은 그냥 줄 서 있을 뿐인데 oldest age 1,953s로 `operator_action_required=true`가 켜졌다.

정체는 keeper 속성이 아니라 "지금 긴 사이클 안에 있는 keeper"를 따라 **회전**했다(sangsu → kidsnote → rondo → taskmaster). RFC-0373류 lane 굶김(`holder_lane=chat_operation`)은 이 구간에 0건 — 별개 결함이다. 소비 코드는 계약대로 동작했다: kidsnote의 autonomous 사이클은 06:22:20Z에 `autonomous turn yields to durable stimulus`로 정상 양보했다.

사이클 중앙값은 16초지만 장기 사이클은 30분+다. 600초 임계는 이벤트 나이 축에서는 두 세계를 구분할 수 없다.

## 3. 설계 A — work liveness v2

현재: `server_routes_http_runtime_health_fleet.ml:274`가 `runnable_oldest_age_seconds >= stale_after_sec`만으로 stale을 판정하고 :367-380에서 `masc.keeper_event_queue.work_liveness.v1`로 발행한다.

변경 (`masc.keeper_event_queue.work_liveness.v2`):

- keeper별 runnable 행에 홀더 상태를 함께 투영한다:
  - `holder_cycle`: 진행 중 사이클이 있으면 `{ started_at, wake_class }` (registry가 이미 아는 사실의 투영), 없으면 `null`
- stale 판정: `oldest_age >= stale_after_sec` **이고** 그 구간에 홀더의 진행 중 사이클이 없을 때만 keeper 행이 stale이다. 진행 중 사이클이 있으면 행 상태는 `busy_holder`로 투영하고 `operator_action_required`에 기여하지 않는다.
- fleet 수준 `runnable_backlog_stale` 사유와 `keeper_reaction_ledger:durable_event_queue_stale`도 같은 축을 쓴다.
- 이벤트 나이·개수는 그대로 싣는다. 사실은 지우지 않는다 — 판정만 옮긴다.

idle 홀더 + 방치 이벤트(진짜 liveness 문제)는 지금과 동일하게 degraded를 켠다. 이건 경보 완화가 아니라 경보의 참/거짓 정정이다.

## 4. 설계 B — transient 실패는 도착 순서를 잃지 않는다

현재: `keeper_heartbeat_loop.ml:335-341`에서 `Retry_after_observed | Rotate_now -> Defer_to_queue_tail`, :816-828의 `defer_selection_to_queue_tail`이 소스를 꼬리로 보낸다.

변경: transient 경로의 재투입은 도착 시각 순서를 보존한다(`Defer_to_queue_tail` → `Defer_preserving_arrival`). 큐의 정렬 권위는 이미 durable한 도착 시각이므로 새 필드가 필요 없다. `Exhausted_visible_alive -> Quarantine_source` 경로는 그대로다. 재시도 카운터·백오프·상한은 추가하지 않는다 — 그건 이 RFC 소관이 아니고, 필요해지면 별도 RFC로 근거를 갖고 온다.

## 5. Acceptance (feature 왕복)

1. **장기 사이클 무경보**: 사이클 진행 중인 keeper에 이벤트를 도착시키고 600s를 넘겨도 `operator_action_required=false`, 행 상태 `busy_holder`, `holder_cycle.started_at`이 실제 StartTurn 시각과 일치한다.
2. **idle 방치 경보 유지**: 사이클 없는 keeper의 이벤트가 600s를 넘으면 지금과 동일하게 stale/degraded가 켜진다.
3. **순서 보존**: 이벤트 2건 도착 후 첫 소비가 transient 실패하면, 재투입된 이벤트가 두 번째 이벤트보다 먼저 소비된다(도착 순서 재현).
4. Dashboard Monitor/health가 v2 스키마만 읽는다. v1 잔재(발행·reader·테스트) 0건.

## 6. 고려한 대안

- **임계값 상향**: 신호를 죽이는 워크어라운드. 축이 틀렸는데 눈금을 늘리는 것 — 기각.
- **사이클 시간 cap/timeout**: rondo의 진짜 작업을 죽인다. 원칙 7/11 위반 — 기각.
- **사이클 중간 admission**: 턴 경계 계약(`keeper_unified_turn.ml`)의 대형 변경이고, 이번 실측은 그걸 요구하지 않는다. 필요가 실측되면 별도 RFC — 보류.

## 7. 구현 사다리 (각 ≤20k output tokens, 인접 단계 적대 리뷰 병렬)

1. work_liveness v2 projection (server fleet/health 발행 + v1 컷)
2. Dashboard Monitor/health 소비면 v2 전환
3. `Defer_preserving_arrival` + 순서 보존 feature test
