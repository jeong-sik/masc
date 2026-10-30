# VM·세션 자원 레인 이벤트 생산자 (lane resource events)

- 날짜: 2026-09-11
- 상태: 구현 중 (MASC task-1518)
- 근거 스펙: `docs/design/lane-addon-v0.md` — instance마다 독립 Docker container, detach는
  정확한 container ID의 제거 확인, 제거를 확인하지 못하면 cleanup incomplete, container
  identity를 확보하지 못한 구간의 detach는 완료로 표시하지 않는다.

## 목적

Add-on instance의 컨테이너 수명주기를 이벤트로 남긴다. 이 행이 쌓이면 자원 점유·해제의
시계열이 생기고, 이후 혼잡 분석과 예측(스케줄 롤아웃)의 첫 입력이 된다. 이번 변경은
생산자와 durable 기록까지만 한다. 화면 표시는 범위 밖이다.

## 이벤트 4종

MASC 소유 event bus에 `Custom` 이벤트로 발행한다. 이름은 접두사 `masc.lane.resource.`.

| wire name | 발행 시점 | container_id |
|---|---|---|
| `masc.lane.resource.acquired` | `backend.start`의 `on_created` — 실제 container identity를 확보한 순간 | Some |
| `masc.lane.resource.acquire_failed` | `backend.start`가 Error를 반환 | 확보했으면 Some, 아니면 None |
| `masc.lane.resource.release_confirmed` | stop/recover_stop이 Ok — phase가 Detached로 전이할 때 | Some |
| `masc.lane.resource.release_incomplete` | stop/recover_stop이 Error, 또는 identity 없이 끝난 worker에 대한 detach | 있으면 Some, 없으면 None |

규칙:

- payload 필드는 `instance_id`, `run_id`, `package_id`, `package_revision`,
  `container_id`, `detail`. 시각은 envelope의 `event_time`이 담당하므로 payload에 별도
  timestamp를 넣지 않는다.
- envelope는 `correlation_id = instance_id`, `run_id = 관측 묶음 run_id`. `caused_by`는
  만들지 않는다. 스펙이 인접한 시각만으로 인과를 만들지 말라고 한다. 같은 instance의
  생애는 correlation_id로 묶인다.
- `release_confirmed`는 phase가 이미 Detached면 재발행하지 않는다. `start-hang` 경로에서
  stop이 두 번 호출될 수 있어 전이 시점 가드가 필요하다.
- 발행은 런타임 진행을 차단하지 않는다. bus가 없으면 WARN 한 줄로 끝낸다. 스펙의
  "Add-on 장애는 기존 활동을 축소하지 않는다"를 발행 경로에도 그대로 적용한다.
- 관측 실패(`observe` Error)는 자원 수명주기가 아니므로 발행하지 않는다.

## 전달 경로와 기록

`Event_bus_slots.get_masc ()` → `Runtime_event_bus.publish`. `Keeper_event_bridge`가
durable JSONL(`.masc/agent-core-events/`)과 SSE 릴레이를 자동으로 붙인다. 대시보드는 이
이벤트를 라우팅하지 않는다. 패리티 게이트는 FE가 라우팅하는 이벤트만 등록을 요구하고,
백엔드가 발행하고 FE가 다루지 않는 이벤트는 지금 범위 밖이다
(`masc.keeper.native_posture_degraded`가 같은 방식으로 배포됐다). 타임라인 표시는 다음
단계에서 SSEEventType 등록과 함께 한다.

## 검증

- `test/test_lane_addon_resource_events.ml` — 가짜 backend로 네 전이 각각이 올바른
  wire name과 payload를 발행하는지 단언. container identity가 없는 실패는 `container_id`
  가 null인지, envelope의 correlation_id가 instance_id인지 확인.
- wire name 4종은 문자열 그대로 고정 단언한다. 이름은 구독자가 믿는 계약이다.
- 로컬에서 해당 스위트를 실행해 초록을 확인한다. CI는 타입 검사만 하므로 로컬 실행이
  유일한 근거다.
