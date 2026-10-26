# 예약 Job 실제 API 행동 감사 — 2026-10-26

예약 Job 전체를 행동 기준으로 대조한 결과는 **전체 PASS가 아니다**. 일곱 도구의
순차 사용·두 사용자 권한·병렬 메모·페이지 조회는 설치 바이너리에서 실행했다.
반면 **paused A의 미시작 발생을 B로 retarget한 뒤 취소하면 A의 pending이 남는 F1**을
실제 서버에서 재현했다. 취소 뒤 실행 재개나 외부 효과 발생까지 시험한 것은 아니다.

전체 범위는 [기존 행동별 대조표](../audits/2026-10-26-scheduled-job-behavior-audit.md)와
같다. 이 보고서는 그 표 중 새 실행으로 판정이 달라진 부분과 남은 검증을 기록한다.
관련 기존 이슈는 [#25692](https://github.com/jeong-sik/masc/issues/25692)이며,
새 misfire 정책이나 임의 backlog/age 제한을 제안하는 보고서가 아니다.

## 실행 대상과 증거

- 실제 실행한 설치 바이너리: `bc3038a22374705db648bebd7f556223b3e84727`, version `0.64.0`.
- 실행 파일 SHA-256: `833298c99525205f929bab74ee6d45a53601c340bd1b084a2473e183c7663a57`.
- 각 임시 서버의 `/health?full=1`에서 실행 파일 해시·embedded commit·effective base를 확인했다.
  체크아웃 head와 실행 바이너리 head를 혼동하지 않는다.
- 비교한 체크아웃: `9d451a840ff006e70a684cb36d2c1eb69be3f8aa`.
  F1 담당 cancel/store/tool/queue/inventory/consumer 일곱 파일은 실행 커밋과 바이트 동일했다.
  [manifest](../evidence/2026-10-26-schedule-runtime-behavior/manifest.json)에 파일별 해시가 있다.
  새 main 전체를 빌드·실행했다는 뜻은 아니다.
- 격리된 임시 base와 loopback 포트를 사용했다. provider endpoint는 연결되지 않는
  `127.0.0.1:9`이며 운영 workspace의 예약·Keeper·runtime 설정은 변경하지 않았다.
- [입력·응답·검사·재현 스크립트](../evidence/2026-10-26-schedule-runtime-behavior/README.md)를 보존했다.
  각 서버는 해당 실행이 끝난 뒤 정상 종료됐고 임시 base는 제거됐다.

## 새로 실행한 행동

`api-extended-1`은 실제 MCP 세션 두 개로 다음을 실행해 **33개 check PASS**였다.
33은 아래 기능의 호출·결정 검사 수이며 독립적인 33개 전체 시나리오라는 뜻은 아니다.

| 행동 | 실제 관측 |
|---|---|
| create → update → list → get | public id 유지, instance 교체, 수정 내용 조회 |
| note_add → notes_list | 메모 세 개 추가 후 최신 두 개를 오래된 순서로 조회 |
| 다른 creator의 예약 취소 시도 | `isError=true`, `error_kind=not_schedule_owner` |
| creator의 취소 | `status=cancelled`, 취소 후 메모 유지 |
| 취소된 정의 수정 | `transition_refused`, `current_status=cancelled` |
| 두 사용자의 병렬 메모 추가 | 두 client thread로 제출한 노트 두 개 모두 고유 ID로 보존; raw 응답의 body와 author 연결도 직접 확인 |
| recipient가 자신을 깨우는 예약 수정 | 원 creator 보존, 자신의 target 유지 |
| recipient가 타 Keeper로 retarget 시도 | `not_schedule_owner` |
| recipient가 자신을 깨우는 예약 취소 | creator와 다른 recipient actor로 취소 성공 |
| instance 교체 전 메모의 보존 | 수정 후 동일 메모 조회 |
| limit=1로 세 예약 순회 | 중복·누락 없이 ID 순서대로 조회 |
| 기존 cursor에 다른 status 필터 사용 | `cursor_mismatch` |
| 과거 due 시각으로 생성 | `due_already_past` |

이 실행의 admin credential도 schedule tool에는 **named caller / automated_actor**로
기록된다. 따라서 creator/recipient 경계를 시험했으며 `Operator_caller`의 타인 예약
변경 권한을 입증한 실행은 아니다. 두 client thread의 한 번의 병렬 제출은 모든
interleaving·경합·부하 검증을 대신하지 않는다.

## F1 — 미시작·paused 발생이 성공한 취소 뒤에도 남음

`retarget-cancel-4`에서 다음 순서를 실제로 실행했다.

1. 임시 workspace에 A/B Keeper를 등록하고 **명시적인 pause directive**를 보냈다.
   두 owner 모두 `paused=true`인 권위 조회를 확인한 뒤 예약을 생성했다.
2. A를 target으로 한 interval 예약을 만들고 due 발생이 A 큐에 접수될 때까지 관측했다.
   `last_wake.status=succeeded`는 dispatch 접수이며 작업 완료가 아니다.
3. 같은 creator가 public schedule id를 유지하며 target을 B로 수정했다.
   새 `schedule_instance_id`와 B target을 응답에서 확인했다.
4. 같은 id의 취소가 성공하고 새 정의가 `status=cancelled`가 됐다.
5. A/B의 disk-backed waiting inventory를 다시 읽었다. B는 비어 있었지만 A에는
   **동일 post id·source ref·incarnation**의 발생이 그대로 pending이었다.
6. 마지막 owner 상태는 `paused=true`, `total_turns=0`, `last_turn_ts=0`,
   `last_runtime_attempt=null`이었다. Resume나 실행 재개는 요청하지 않았다.

실제 입력의 원 instance는 `01a17814-34d5-7000-94ca-69fa05561225`이며 정확한 값은
[finding](../evidence/2026-10-26-schedule-runtime-behavior/retarget-cancel-4/finding.json)과
API 응답을 기준으로 한다. 발생 post id는
`9e2995669a213ae81e2b7ed1fc483dc0d43e681745562418fb26e2909dda5eb3`이다.

18개 check 중 준비·관측 **17 PASS**, 마지막 `cancellation withdraws original A occurrence`
**1 FAIL**로 probe가 exit 1을 반환했다. 서버 PID 4139는 정상 종료(exit 0)했다.
테스트 서버 종료 성공을 제품 취소 성공으로 바꾸어 해석하지 않는다.

현재 취소 hook은 **현재 정의가 지목하는 target만** 철회한다
(`Keeper_schedule_cancel_withdrawal.run`). update는 새 instance로 정의를 교체하므로
이전 A의 pending을 B를 대상으로 한 취소가 찾지 못한다. 일곱 담당 파일은 비교한
main에서도 동일하다. source-derived 후보였던 F1은 이 입력에 한해 실제 반례로 격상한다.

초기 `retarget-cancel-1`은 임시 image promotion 누락으로 Keeper 등록이 실패했고,
`-2`는 하네스가 wire label `schedule_due`의 대소문자를 틀려 이미 접수된 큐를 놓쳤다.
둘 다 취소 결함의 증거로 세지 않는다. `-3`은 provider 연결 거절로 실패한 턴 뒤의
pending 잔류를 관측했다. 미시작·paused 변형의 근거는 **`-4`만**이다.

## 남은 전체 범위

| 범위 | 현재 증거와 다음 확인 |
|---|---|
| recurrence·timezone·cron·윤일 | 기존 domain 28개 실행; 현재 runner/consumer 전체 실행으로 이월하지 않음 |
| continuous busy 중 예약 진입 | #46133–#46135 소스 승인·병합 확인. 이번 바이너리는 그 전 커밋이므로 실제 설치·tool-boundary 양보·소비 완료 미검증 |
| paused/offline → Resume/Boot | paused 보존은 이번에 실행. 재개 후 정확한 발생의 처리·ACK·결과 전달은 미검증 |
| F2 startup recovery 최초 실패 | 현 소스 후보 유지. 같은 process에서 저장소 회복 후 수렴하는지 주입 실행 필요 |
| F3 권한 확인과 mutation 사이 경합 | 순차 creator/recipient 검사는 통과. retarget과 취소/수정의 결정적인 경합은 미검증 |
| F4 due-only 수정과 recurrence 갱신 경합 | 순차 수정과 별개. lock 전 snapshot을 interleave하는 실행 필요 |
| F5 retry/실패 정산 write 실패 | 현 소스 후보 유지. Running 저장 후 정산 실패·복구·후속 tick 실행 필요 |
| 실제 모델·계정 전환 | 원 source/outbox를 유지한 checkpoint/failover 및 효과 한 번 보장 미검증 |
| 결과 목적지 | 실제 model → posting/file tool → 목적지 read-back 미검증 |
| Lane action | 실제 worker/receipt/effect-unknown/redelivery 미검증 |
| TUI | decoder/선택 결정의 기존 component 근거와 별개로 실제 표시·refresh 동작 미검증 |

선택된 실제 backend suite 다섯 개는 MASC `masc-pro-builder`에 요청한
`kmsg-0ee5cad6044d0c44843de8a152152104`는 이 보고서 기록 시점의 조회에서 **Running**이었다.
요청 범위는 `test_schedule_tool_wiring`, `test_schedule_store`, `test_schedule_runner`,
`test_schedule_consumer_dispatch`, `test_lane_addon_scheduled_act`다.
이 상태는 완료된 suite 결과가 아니다. 로컬 Dune/full build·CI watch는 외부 coding
session에서 실행하지 않았다. 실제 결과가 오면 head·명령·실행/skip/실패를 별도로 대조한다.
