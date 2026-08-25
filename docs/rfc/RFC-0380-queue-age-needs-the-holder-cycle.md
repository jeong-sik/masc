---
rfc: "0380"
title: "대기 나이는 홀더의 사이클을 알아야 한다 — work liveness 판정 축 정정"
status: Draft
created: 2026-08-14
updated: 2026-08-14
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0377", "0373", "27349"]
---

# RFC-0380: 대기 나이는 홀더의 사이클을 알아야 한다

## 0. Summary

durable 이벤트는 사이클 입구에서만 턴에 투입되고, 사이클 벽시계 시간에는 상한이 없다. 그래서 keeper가 30분짜리 정상 tool 루프를 도는 동안 도착한 이벤트는 반드시 600초 stale 임계를 넘고, health는 `runnable_backlog_stale`/`operator_action_required=true`를 켠다 — 아무것도 고장나지 않았는데.

이 RFC는 work liveness의 **판정 축 하나**를 정정한다: stale 판정을 이벤트 나이 단독에서 "그 시간 동안 홀더(keeper)가 진행하고 있었나"로 옮긴다. 홀더의 진행 신호는 registry가 이미 갖고 있다 — `turn_observation.last_progress_at`(#27349 in-turn liveness pulse가 정확히 이 목적으로 노출하는 게이지)을 projection에 실어, 정상 장기 루프(진행 신호가 계속 갱신됨)와 진짜 hang(사이클은 있는데 진행이 침묵)을 같은 임계값 하나로 구분한다. 새 게이트도, 새 임계값도, 새 필드 발명도 없다.

초안에 있던 "transient 실패의 큐 위치 보존"(Design B)은 적대 리뷰에서 head-of-line blocking을 만드는 것으로 반증되어 **철회**했다 (§6).

## 1. 원칙 → 설계 강제

| 원칙 | 이 RFC에서의 강제 |
|---|---|
| 7. 게이트 | 신규 게이트 0. 사이클 길이에 cap/timeout을 만들지 않는다 — rondo의 32분짜리 진짜 작업(빌드·파일 편집)은 제품이 원하는 바로 그 행동이다. admission 계약(`keeper_unified_turn.ml:259-285`)은 건드리지 않는다 |
| 9. 매직넘버 | 신규 임계값 0. 기존 `durable_queue_stale_sec`(600s) 하나를 두 경우 모두에 재사용한다: idle 홀더의 이벤트 방치, busy 홀더의 진행 침묵 |
| 11. 관측성 | 거짓 경보 억제가 아니라 projection 확장이다. 이벤트 나이·개수는 사실이므로 계속 싣고, `holder_cycle`(시작 시각·wake·마지막 진행 시각)을 추가한다. #27349가 raw fact를 threshold-free로 노출하는 방식을 그대로 따른다 |
| 8. 레거시 | `work_liveness` 스키마는 v1을 hard cut하고 v2로 교체한다. 호환 reader·이중 발행 없음. v1 emitter는 두 곳이다(§3) — 둘 다 같은 PR에서 컷 |
| 19. 재사용 | 진행 신호를 재발명하지 않는다. `turn_observation.last_progress_at`(`keeper_registry_types.mli:488-491`, `stamp_turn_progress`)과 #27349 pulse가 이미 있다 |
| MASC autonomy | 과거 evidence를 scheduling gate로 쓰지 않는다: 이 RFC는 순수 projection 정정이며 스케줄링·admission·큐 순서를 일절 바꾸지 않는다 |
| 20. 테스트 | acceptance는 feature 왕복(§5)이다: busy/idle/hang 세 시나리오를 헬스 출력으로 검증하며, 헬퍼 단위 테스트를 늘리지 않는다 |

## 2. 문제 — 실측 (2026-08-14, `~/.masc/logs/system_log_2026-08-14.jsonl`)

같은 헬스 증상(`runnable_backlog_stale`)이 서로 다른 두 경로에서 났다.

**(a) provider 실패가 사이클을 태움** — sangsu 이벤트 `51398c19`(06:14:09Z 도착): 06:25:45Z 사이클 입구에서 소비 → 19분 뒤 `Network error: Broken pipe`로 turn terminal → `source moved to queue tail reason=transient_turn_failure` → 06:49:48Z 재투입 → 06:53:45Z ack. **총 39분 36초**. kidsnote `1ef615b1`도 동형(34분 07초).

**(b) 정상 장기 tool 루프** — rondo 06:50:22Z `idle -> phase_gating action=StartTurn` 후 23회 provider turn으로 실제 빌드·파일 편집을 수행, 32분+ 동안 실패 0건. 그 뒤에 도착한 이벤트 3건은 그냥 줄 서 있을 뿐인데 oldest age 1,953s로 `operator_action_required=true`가 켜졌다.

정체는 keeper 속성이 아니라 "지금 긴 사이클 안에 있는 keeper"를 따라 **회전**했다(sangsu → kidsnote → rondo → taskmaster). RFC-0373류 lane 굶김(`holder_lane=chat_operation`)은 이 구간에 0건 — 별개 결함이다. 소비 코드는 계약대로 동작했다: kidsnote의 autonomous 사이클은 06:22:20Z에 `autonomous turn yields to durable stimulus`로 정상 양보했다.

사이클 중앙값은 16초지만 장기 사이클은 30분+다. 600초 임계는 이벤트 나이 축에서는 두 세계를 구분할 수 없다.

## 3. 설계 — work liveness v2

현재: `server_routes_http_runtime_health_fleet.ml:274`가 `runnable_oldest_age_seconds >= stale_after_sec`만으로 stale을 판정하고 :367-380에서 `masc.keeper_event_queue.work_liveness.v1`을 발행한다. **v1 emitter는 한 곳 더 있다**: `server_routes_http_runtime.ml:877-887`의 헬스 컴포넌트 timeout/placeholder 폴백이 같은 스키마 리터럴을 별도로 발행한다. 두 곳 모두 이 RFC의 컷 대상이다.

변경 (`masc.keeper_event_queue.work_liveness.v2`):

- keeper별 runnable 행에 홀더 상태를 함께 투영한다:
  - `holder_cycle`: 진행 중 사이클이 있으면 `{ started_at, wake, last_progress_at }` — 전부 registry의 기존 사실(`turn_observation`의 `started_at`·`wake : wake_reason`·`last_progress_at`)의 투영이며 새 필드 발명이 없다. 없으면 `null`.
- stale 판정은 "홀더의 침묵"으로 통일한다. keeper 행이 stale인 조건:
  - 진행 중 사이클이 **없고** `oldest_age >= stale_after_sec` (idle 방치 — 기존과 동일), 또는
  - 진행 중 사이클이 **있고** `now - last_progress_at >= stale_after_sec` (busy인데 진행 침묵 = hang)
- 진행 신호가 살아 있는 busy 홀더의 행은 `busy_holder`로 투영하고 `operator_action_required`에 기여하지 않는다.
- fleet 수준 `runnable_backlog_stale` 사유와 `keeper_reaction_ledger:durable_event_queue_stale`도 같은 축을 쓴다.
- 행 상태(stale / busy_holder / …)와 판정은 stringly if/else 체인이 아니라 **exhaustive variant match**로 모델링한다 (CLAUDE.md FSM sparse-match 경고. 현행 `work_status`/`work_state` 계산 `server_routes_http_runtime_health_fleet.ml:277-296`은 if/else 체인이다 — v2 전환 시 함께 정리).
- 이벤트 나이·개수는 그대로 싣는다. 사실은 지우지 않는다 — 판정만 옮긴다.

hang(사이클은 등록됐는데 `last_progress_at`이 침묵)은 이 설계에서 **경보가 유지**된다. 정상 장기 루프는 progress가 계속 갱신되므로(#27349 주석: "a long-running turn that keeps progressing stays near zero; a stalled provider call grows unbounded") 경보에서 빠진다.

Known limitation: 반복적이지만 무의미한 progress(예: 동일 실패 도구 호출을 계속 재시도하며 매번 phase가 넘어가는 루프)는 이 설계로 감지되지 않는다. `stamp_turn_progress` 호출부는 전부 "FSM이 다음 단계로 넘어갔다"는 신호이지 "그 결과가 유의미했다"는 신호가 아니다 — `last_progress_at`은 죽음/삶을 구분하고, 생산/공회전 구분은 완전히 다른 메커니즘이 필요한 별도 RFC 영역이다.

## 4. 소비자

`rg -l work_liveness` 전수(2026-08-14): 발행 2곳(§3), 소비 `dashboard/src/api/dashboard-tools-prompts.ts`, `dashboard/src/components/overview/overview.ts`(현재 `workState: string` + `?? 'unknown'` 폴백 — v2 전환 시 고정 union으로), 테스트 `dashboard/src/api/dashboard.test.ts`, `test/test_keeper_terminal_reason_typed.ml`. 전부 §7 사다리 안에서 전환하고 v1 잔재를 남기지 않는다.

## 5. Acceptance (feature 왕복)

1. **장기 사이클 무경보**: 진행 신호가 갱신되는 사이클 중인 keeper에 이벤트를 도착시키고 600s를 넘겨도 `operator_action_required=false`, 행 상태 `busy_holder`, `holder_cycle.started_at`이 실제 StartTurn 시각과 일치한다.
2. **idle 방치 경보 유지**: 사이클 없는 keeper의 이벤트가 600s를 넘으면 지금과 동일하게 stale/degraded가 켜진다.
3. **hang 경보 신설 확인**: 사이클이 등록됐지만 `last_progress_at`이 600s 이상 침묵하면 stale이 켜진다 — busy가 경보를 영구히 숨기지 못함을 증명한다.
4. Dashboard Monitor/health가 v2 스키마만 읽는다. v1 잔재(발행 2곳·reader·테스트) 0건 — placeholder 폴백 경로(`server_routes_http_runtime.ml:877-887`) 포함.

## 6. 고려하고 기각한 대안

- **임계값 상향**: 신호를 죽이는 워크어라운드. 축이 틀렸는데 눈금을 늘리는 것 — 기각.
- **사이클 시간 cap/timeout**: rondo의 진짜 작업을 죽인다. 원칙 7/11 위반 — 기각.
- **사이클 중간 admission**: 턴 경계 계약(`keeper_unified_turn.ml`)의 대형 변경이고, 이번 실측은 그걸 요구하지 않는다 — 보류.
- **(초안의 Design B) transient 실패의 큐 위치 보존**: 적대 리뷰(2026-08-14)가 코드로 반증했다. 선택은 도착 순서의 첫 ready 항목이고(`keeper_event_queue_state.ml:250-262`), 현행 `defer_pending`(:356-374)은 실패 항목을 "같은 urgency의 꼬리, 다른 urgency 앞"에 재삽입하는 **의도된 라운드로빈**이다("preserves arrival order among same-urgency entries" 주석). `Exhausted_visible_alive`는 재시도 횟수가 아니라 에러 타입 분류라(`keeper_runtime_failure_route.mli:97-110`) 반복 transient 이벤트는 영원히 quarantine되지 않는데, 도착 순서를 보존하면 그 이벤트가 head를 점유해 뒤 이벤트 전부를 굶긴다. 실측의 "나이 배증"에서 지연 자체는 v2에서도 그대로다(`defer_pending`은 `arrived_at`을 건드리지 않는다) — 바뀌는 것은 그 지연이 case (a)의 진짜 대기로서 **참 신호로 경보된다**는 점이다. case (a)는 애초에 false positive가 아니었으므로 스케줄링을 바꿀 근거가 없다 — 기각.

## 7. 구현 사다리 (각 ≤20k output tokens, 인접 단계 적대 리뷰 병렬)

1. work_liveness v2 projection: fleet/health 본선(`server_routes_http_runtime_health_fleet.ml`)과 placeholder 폴백(`server_routes_http_runtime.ml:877-887`) 두 emitter 동시 컷, `holder_cycle` 투영, exhaustive variant 판정, OCaml 테스트 전환
2. Dashboard 소비면 v2 전환(`overview.ts` 고정 union, `dashboard-tools-prompts.ts`, dashboard 테스트), busy/idle/hang 3-시나리오 feature test
