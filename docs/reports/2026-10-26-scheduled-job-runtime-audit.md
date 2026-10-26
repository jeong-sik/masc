# 예약 Job 실제 API 행동 감사 — 2026-10-26

예약 Job 전체를 행동 기준으로 대조한 결과는 **전체 PASS가 아니다**. 일곱 도구의
순차 사용·두 사용자 권한·병렬 메모·페이지 조회는 설치 바이너리에서 실행했다.
반면 **paused A의 미시작 발생을 B로 retarget한 뒤 취소하면 A의 pending이 남는 F1**을
실제 서버에서 재현했다. 취소 뒤 실행 재개나 외부 효과 발생까지 시험한 것은 아니다.
추가 실제 모델 검사에서는 단독 예약 두 건이 성공했지만, **busy 중 후속 예약에 양보한
원래 작업을 효과 없이 Completed/ACK로 소비하는 F6 P1**도 재현했다.

전체 범위는 [기존 행동별 대조표](../audits/2026-10-26-scheduled-job-behavior-audit.md)와
같다. [59개 행의 최신 근거표](../audits/2026-10-26-scheduled-job-coverage-update.md)는
각 요구와 실행 suite/case·실제 runtime 기록·남은 한계를 일대일로 연결한다.
이 보고서는 그 표 중 새 실행으로 판정이 달라진 부분과 남은 검증을 기록한다.
관련 기존 이슈는 [#25692](https://github.com/jeong-sik/masc/issues/25692)와
[#46120](https://github.com/jeong-sik/masc/issues/46120)이며,
새 misfire 정책이나 임의 backlog/age 제한을 제안하는 보고서가 아니다.

## 초기 API/F1 실행 대상과 증거

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
  초기 `api-extended-1`과 `retarget-cancel-4`의 서버는 exit 0으로 끝났고 임시 base는 제거됐다.
  추가 restart run의 exit 124/0은 아래 절에서 별도로 구분한다.

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

## 재시작·정의 만료·누락 interval의 실제 실행

추가 `restart-expiry-3`은 설치 바이너리 `1ce158d50d3eb48648e6deea7f668172f914fea3`,
SHA-256 `b6a50b5e88c4730b029af14cd5a6b7a587f69f9535f90c7101caf9711e8c7312`를
두 번 기동했다. 앞선 bc3038a 실행으로 이월하지 않는다. 임시 workspace에서 기존
runner 설정을 1초로 정하고 명시적으로 paused인 Keeper 하나로 **23개 상태 check PASS**였다.

- 같은 base에서 재기동한 뒤 세 예약의 instance와 원 accepted source의
  post/ref/incarnation, 메모가 유지됐다. owner는 끝까지 paused, turns=0이었다.
- 두 정의의 expiry가 실제 서버 정지와 재기동 사이에 들어감을 시각으로 검증했다.
  접수되지 않은 단발은 `Expired`, retained wake count=0이었다.
- 이미 접수된 반복 예약의 정의도 `Expired`가 됐지만 기존 입력은 그대로 pending,
  기존 dispatch receipt와 retained wake count=1을 보존했다. 이는 현재 계약의
  **future intake 만료와 accepted work 보존의 구분**이며 만료 결함으로 분류하지 않는다.
- 다른 interval은 정지 중 적어도 세 due 시점을 놓쳤다. 재기동 후 pending과 retained
  wake history가 각각 하나였고, 다음 due는 실제 wake 시작 시각 뒤였다.
  raw dispatch 시각으로 검산해도 가능한 missed 수가 endpoint의 retained-history
  ceiling 32보다 작아, 잘린 이력을 한 번의 dispatch로 잘못 읽는 경우는 아니다.

**종료는 완전히 정상적이지 않았다.** 첫 process는 SIGTERM 뒤 설치된 10초 graceful
shutdown guard로 **exit 124**, 둘째는 exit 0이었다. 23은 위 상태 판정 수이고 clean
shutdown 성공 수가 아니다. 따라서 이 실행은 guard 종료 뒤의 저장 상태 복원을
보여 주며, Running lease에 write fault를 주입한 F2/F5 복구를 증명하지 않는다.
[실제 process 시각·exit code·로그·이력](../evidence/2026-10-26-schedule-runtime-behavior/restart-expiry-3/processes.json)을 보존했다.

초기 `restart-expiry-1`의 17개 검사는 두 process exit 0으로 끝났으나 history count는
검사하지 않았다. `-2`는 종료가 due보다 늦어 fixture 전제가 실패했다. 준비 시간대를
늘리고 명시적인 시간·이력 검사를 더한 **`-3`만 이번 추가 보존 bundle의 근거**다.

## 남은 전체 범위

| 범위 | 현재 증거와 다음 확인 |
|---|---|
| recurrence·timezone·cron·윤일 | domain 28개와 위 짧은 interval downtime 실행; 장기 downtime·daily/cron 통합 실행은 미검증 |
| continuous busy 중 예약 진입 | 실제 6a2d 실행에서 진입·양보는 관측했으나, 원래 효과 없이 Completed/ACK되는 F6 P1 반례 확인. 아래 참조 |
| paused/offline → Resume/Boot | paused 보존은 이번에 실행. 재개 후 정확한 발생의 처리·ACK·결과 전달은 미검증 |
| F2 startup recovery 최초 실패 | 현 소스 후보 유지. 같은 process에서 저장소 회복 후 수렴하는지 주입 실행 필요 |
| F3 권한 확인과 mutation 사이 경합 | 수리 PR46182의 locked 재인가와 공개 update interleaving/locked cancel 거절을 별도 Test124로 실행. 실제 HTTP cancel 경합·수리 binary 실행은 미검증 |
| F4 due-only 수정과 recurrence 갱신 경합 | 순차 수정과 별개. lock 전 snapshot을 interleave하는 실행 필요 |
| F5 retry/실패 정산 write 실패 | 현 소스 후보 유지. Running 저장 후 정산 실패·복구·후속 tick 실행 필요 |
| 실제 모델·계정 전환 | DeepSeek·GLM의 독립 단독 예약은 실제 노트/ACK까지 성공. 원 source/outbox를 유지하는 provider/account failover는 미검증 |
| 결과 목적지 | 내부 노트 목적지는 실제 모델 도구 호출·Keeper author·되읽기 확인. posting/file 등 외부 목적지는 미검증 |
| Lane action | 실제 worker/receipt/effect-unknown/redelivery 미검증 |
| TUI | decoder/선택 결정의 기존 component 근거와 별개로 실제 표시·refresh 동작 미검증 |

선택된 실제 backend suite 다섯 개는 MASC `masc-pro-builder`에 요청했다.
최초 operation `kmsg-0ee5cad6044d0c44843de8a152152104`는 Running으로 관측됐으나,
공유 서버의 재시작 뒤 12:17 UTC 정확한 REST 조회에서 **Failed / Turn_cancelled**였다.
이전 실행이 완료됐다는 근거는 없다. 기존 artifact와 살아 있는 process/handle을 먼저
회수하고 중복 실행 없이 미실행 부분을 이어 달라는 복구 요청
`schedule-backend-resume-0c7be315f4334255b271e1195ca530d0`를 보냈다.
12:19 UTC 접수와 12:21 UTC 같은 id 재조회는 **Queued**였다.
세 상태 영수증은 [동일 evidence 디렉터리](../evidence/2026-10-26-schedule-runtime-behavior/README.md)에 있다.
요청 범위는 `test_schedule_tool_wiring`, `test_schedule_store`, `test_schedule_runner`,
`test_schedule_consumer_dispatch`, `test_lane_addon_scheduled_act`다.
이 접수는 완료된 suite 결과가 아니다. 로컬 Dune/full build·CI watch는 외부 coding
session에서 실행하지 않았다. 실제 결과가 오면 head·명령·실행/skip/실패를 별도로 대조한다.

후속 조회에서 복구 operation도 **Failed / Interrupted_by_restart**로 끝났다. 같은 검사를
다시 Keeper에 제출하지 않고, `Test` workflow의 `minimal=true`와 위 다섯 `TARGET_SUITES`만
명시해 실행했다. [run 40322812745](https://github.com/jeong-sik/masc/actions/runs/40322812745)는
head `932d071e624ce26c075f486a4e07b0fd9ac1d4ed`, ref `audit/scheduled-job-runtime-20261026`,
**conclusion=failure**다. 테스트 시작 전 `keeper_unified_turn.ml`의 unused
`autonomous_yield_request_for_wake` warning 32에서 컴파일이 멈춰 **다섯 suite 모두 미실행**이다.
이는 일반 API 33 PASS나 추가 상태 23 PASS를 무효화하지 않지만 backend suite 성공
증거도 아니다. 해당 helper는 main `1ce158d50d3eb48648e6deea7f668172f914fea3`의
기존 [#46151](https://github.com/jeong-sik/masc/pull/46151)에서 이미 제거됐다.
감사 PR은 그 수정 위로 restack했으며 별도 중복 수리는 만들지 않았다.

동일한 다섯 suite의 새 `Test` [run 40325758202](https://github.com/jeong-sik/masc/actions/runs/40325758202)는
head `ae6cabc219bccb6eb57726d81c3f8cc99ba3e04e`, ref `audit/scheduled-job-runtime-20261026`로
실행해 **conclusion=success**로 완료됐다. 실제 suite-runner artifact를 받아 52/58/22/56/7건,
총 **195개 case**의 실행과 suite별 OK를 확인했다. admission 원본은 그대로 보존하고 완료 영수증과
로그 발췌·원본 digest를 추가했다. 이는 해당 head의 타깃 검사이며 전체 회귀·설치된 바이너리·
실제 provider 전환·F1 수리 성공 증거가 아니다. 이후 감사 문서 head로 CI 결속을 이월하지 않는다.

F1 후속 수리는 현재 target만 확대하는 변경으로 끝내면 안 된다. 이전 instance의 receipt는
retention으로 잘릴 수 있어 canonical durable queue discovery의 오류를 보존해야 한다.
scheduled-source transfer와 복구 projection도 취소와 같은 serialization 경계에 참여해야
취소 직후 다른 owner에서 pending이 다시 생기는 경합을 막을 수 있다. 기존 intake →
ledger → queue 잠금 순서를 거꾸로 잡는 수리도 피해야 한다. retarget 반례뿐 아니라
다중 인계·미완료 outbox·읽기 실패·부분 철회 뒤 저장 실패의 실제 회귀를 함께 확인해야 한다.


## 실제 모델의 단독 예약과 busy 반례 F6 — P1

[별도 실제 모델 bundle](../evidence/2026-10-26-schedule-real-model-behavior/README.md)은
동일한 설치 프로그램을 소유한 격리 base에서 실행한 세 기록이다. 각각 `/health?full=1`의
embedded binary와 hash를 확인했으며 모델 credential 값은 보존하지 않았다.

- `real-deepseek-1`: `ollama_cloud.ollama-cloud-deepseek-v4-1-flash`, 실행 binary
  `1ce158d50d3eb48648e6deea7f668172f914fea3`. 단독 예약의 고유 본문을
  Keeper 자신이 `masc_schedule_note_add`로 한 번 저장하고 되읽었다. 같은 exact
  occurrence의 turn-start/end, durable Completed/ACK와 total_turns=1을 확인했다.
- `real-glm-1`: `glm-coding.glm-5-3`, 같은 `1ce158d…` binary. 같은 경로가 성공했다.
  다만 잘못 추측한 schedule ID 세 건의 note 호출은 `schedule not found`로 거절됐다.
  실제 성공 append는 한 건이고 최종 note_count=1이다. 오류 없는 실행이라고 세지 않는다.
- `real-busy-deepseek-1`: 실제 binary는 **`6a2d8dd6171e1d732ca15f918fb084e462e4d371`**,
  SHA `87f8c4afffa1b0b30075f5b2bddfa264edec2d454d972593e68c1068aa5ea548`다.
  설치 binary가 검사 사이 바뀌었다. 원래 checkpoint된 source의 효과가 없는 채
  후속 source만 실행되고 두 source가 모두 Completed/ACK로 종결되는 반례가 나왔다.

busy 반례의 실제 순서는 다음과 같다.

1. 첫 one-shot이 실제 모델 turn #1에 들어간 것을 exact reaction과 live Owner로 확인했다.
2. turn #1이 끝나기 전에 같은 Keeper에 두 번째 예약을 보냈다. `overlap.json`에서
   같은 turn #1 중 두 exact source가 모두 pending, 두 note는 모두 비어 있었다.
3. 13:17:50 UTC 첫 모델 실행이 `yielded_to_durable_stimulus(2)`로 checkpoint됐다.
   실제 도구 호출은 loader 두 번뿐이었다. 첫 노트는 쓰지 않았다.
4. 원본 reaction ledger는 first의 `turn_finished.disposition=checkpointed` 직후
   같은 first의 ACK를 기록한다. 이 ACK는 second의 turn-start보다 앞선다.
5. 다음 실행은 checkpoint를 실제 resume해 second의 get/note/readback을 수행했다.
   최종 first note 0건, second note 1건인데 둘 다 exact terminal Completed/ACK,
   live turn=null이다. 이후 recovery·수동 ACK·재실행 요청은 하지 않았다.

직독한 실행 head `6a2d8dd…`의 `keeper_heartbeat_loop.ml:666`은 checkpoint를
`Batch_ack_attention_only`로 분류하고, `:1427`의 분기는 Connector만 보존하며
Schedule_due도 `terminalize_completed_selection`에 넘긴다(`:1320`).
`Keeper_scheduled_turn_handoff` 자체는 우선권 요청이며 ACK 주체가 아니다.
독립 리뷰도 같은 원본/소스를 대조했다. **checkpoint 파일 유실**이나
**두 번째 완료를 첫 source로 오인**한 반례라고 설명하지 않는다.

수리는 미완료 예약의 exact durable ownership과 재개 입력을 terminal까지 유지해야 한다.
또 여러 예약을 한 batch에 넣고 하나만 이행한 뒤 전체를 ACK하는 조합도 검증해야 한다.
`Schedule_due -> false` 한 줄만으로 완전 수리를 선언할 수 없다.
첫 효과가 이미 정산된 경우의 비중복, successor 취소/교체, checkpoint 뒤 재시작도 남는다.

원래 busy observer는 “둘 다 terminal + live turn 없음 + 필수 효과 누락”을 실패로
끝내는 oracle이 빠져 계속 관측했다. 별도 실제 API로 그 상태를 확인한 후 observer만
SIGINT(exit 130)로 끝냈다. producer는 다시 no-live-turn을 읽고 소유한 서버만 종료했다.
부모 observer가 이미 끝나 서버 exit code는 수집하지 못했으므로 정상 종료 PASS가 아니다.
원본 partial checks는 그대로 보존하고, 별도 finding·ledger·tool receipts로 실패를 증명한다.

이 새 실행들은 내부 durable note 목적지의 성공과 busy 결함을 증명한다. 모델 간 인계,
provider/account failover, 외부 파일·채널 결과, 실제 sandbox Execute, Lane worker나
TUI까지 검증했다고 확대하지 않는다. API33·상태23·CI195·단독 모델 두 예·busy 반례는
서로 다른 범위이며 합산해 사용자 시나리오 통과 수로 만들지 않는다.

F3 권한 수리 [#46182](https://github.com/jeong-sik/masc/pull/46182)는 별도 Test
[40330717541](https://github.com/jeong-sik/masc/actions/runs/40330717541), head
`ed79abfd0500cec731168ab2517969ef30db490a`, ref `fix/schedule-mutation-authority-20261026`,
conclusion **success**다. 실제 4suite artifact의 55/58/9/2=124 cases를 대조했다.
F4 수리 [#46193](https://github.com/jeong-sik/masc/pull/46193)는 같은 native stack
#46194의 상위층이며 head `e0be8af8df8d223bbdf052f3372e282d06f58cb2`다.
해당 head의 별도 두-suite Test40332170687은 **success**, 57+58=115 cases다.
F1 all-owner 취소 수리 [#46211](https://github.com/jeong-sik/masc/pull/46211)는 같은 스택의
세 번째 층이며 head `08da4d99f1b2a58cae5f87f3a71ce4556c83cfe8`다. Test40343103111,
ref `fix/schedule-cancel-all-owners-20261026`, conclusion **success**에서 지정 세 suite가
통과했다(명시 64+12=76 cases, queue executable은 별도 case 수를 출력하지 않음).

[수리 증거 묶음](../evidence/2026-10-26-schedule-repair-validation/README.md)은 별도
native Test40339887803의 definition `117dc31e1ca8f71f47bbbe91fa2adab5befb5761`,
ref `ci/schedule-native-runtime-proof-20261026`, product source
`94b2df25abcdfe20c658322f4156ad63f5546c34`, conclusion **success**를 구분한다.
그 portable binary를 격리 base에서 실제 실행했다. DeepSeek/GLM에서 checkpoint 동안
첫 source가 보존되고 후속 작업과 원래 작업의 두 note/ACK가 확인됐다. DeepSeek의 첫
observer는 overlap을 놓쳐 실패했으며 원본 FAIL을 유지하고 raw ledger로 실제 순서를 대조했다.
GLM은 첫 source 재입장 뒤 첫 note를 쓴 순서와 observer11 PASS/producer exit0을 확인했다.
DeepSeek의 effect-before-arrival 두 예는 정상 순차 처리이며 after-effect checkpoint의 증거가 아니다.

F6 [#46202](https://github.com/jeong-sik/masc/pull/46202)의 후속
`b5c9762b27845918eba2acb804434a0da435cc78`은 native source와 lib/bin tree가 같지만,
Test40341860767, ref `fix/schedule-work-continuation-20261026`, conclusion **failure**다.
수정된 Connector32 cases는 통과했고 Owner106 cases 중 scheduled handoff 3건이
`operation did not become terminal`로 실패했다. fixture가 실제 production의 exact
checkpoint resume를 생략한 원인을 고쳤으며, 별도 Test40348100243의
`ccb0007e95ead82676a58d0dcc17d740dfe94f30`, 같은 ref, conclusion **success**에서
Owner106 cases가 모두 통과했다(skip/fail0). main 위로 rebase된 새
`6dedd652df1273c9476a04643b445601e30181ad`의 결과로 이월하지 않는다.
실제 모델 결과 역시 현재 head CI·운영 설치·전체 피쳐 PASS로 이월하지 않는다.
