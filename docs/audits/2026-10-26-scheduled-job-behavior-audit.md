# 예약 Job 행동 감사 — 2026-10-26

이 문서는 최초 감사 시점의 기록이다. 후속 API33·targeted CI195·실제 모델 실행과
busy F6 반례를 포함한 현재 판정은 [59개 행 최신 근거표](2026-10-26-scheduled-job-coverage-update.md)와
[실제 runtime 보고서](../reports/2026-10-26-scheduled-job-runtime-audit.md)를 따른다.

## 판정

**예약 Job 전체 행동 PASS 아님.** 기존 스케줄러·durable queue·busy 보존 경로는 이미
있다. PR #46092는 이를 재구현하지 않고 채팅에서 관측하는 경로를 보완한다.
그러나 표시 구현 자체에도 감사 중 큐 누락·종단 충돌·취소 후 잔류의 오판과 인계 해석의 누락이 발견됐다.
해당 해석은 수정했으며, 더 넓은 기능에는 아래 취소·시작 복구 결함 후보와
실제 실행·결과 전달·전체 TUI 통합 검증 공백이 남는다.

감사 범위는 사용자 확인대로 **예약 Job 기능 전체**다. MASC 전체 기능 감사가 아니다.
일곱 도구, 시간 계산, dispatch, busy/paused/offline, 소비·실패·취소·인계,
재시작, 목록·상세·노트, TUI, 출력 목적지와 Lane action을 포함한다.

## 계약과 증거의 기준

- 현행 계약: [헌법](../constitution.xml), [도구 스키마](../../config/tools/masc_schedule_create.toml)
  및 같은 디렉터리의 update/list/get/cancel/note_add/notes_list,
  [Schedule_domain](../../lib/schedule/schedule_domain.mli),
  [TUI 안내](../TUI-GUIDE.md).
- [history/outcome RFC](../rfc/RFC-schedule-history-and-outcome.md),
  [출력 목적지 RFC-0376](../rfc/RFC-0376-keeper-owns-output-destination.md),
  [manual demand RFC-0448](../rfc/RFC-0448-manual-keeper-durable-demand.md)는 Draft다.
  구현된 부분은 소스로 확인하되 제안만 있는 동작을 현행 보장으로 계산하지 않는다.
- **실행**: 이번 입력으로 실제 실행한 leaf component 검사. 전체 프로그램 통합 검사가 아니다.
- **소스**: 생산 경로와 관련 기존 테스트를 읽었다. 테스트 존재를 이번 실행으로 세지 않는다.
- **과거 재생**: 과거 실제 백엔드가 생성한 행을 이번 decoder로 재생했다.
  백엔드를 이번 head에서 실행한 것은 아니다.
- **미확인**: 현재 후보의 통합 실행 또는 사용자 결과까지의 관측이 없다.
- **결함 후보**: 소스에서 반례 경로를 확인했으나 실제 저장소를 쓰는 전체 경로 재현은 하지 않았다.

입력 해시는 [component receipt](../evidence/2026-10-26-schedule-behavior-audit/receipt.json)에
있다. `base_head`는 검사를 시작한 커밋의 출처이며, 미커밋 소스를 포함한 실행을 그 커밋의
실행으로 표현하지 않는다. 해시가 실제 검사 입력이다.

## 행동별 대조

| 영역 | 사용자가 할 행동 / 기대 | 확인한 구현·근거 | 판정 |
|---|---|---|---|
| 생성 | Keeper에게 단발 메시지를 예약한다 | tool schema → tool_schedule → Schedule_service/store | 소스; wiring 기존 테스트 있음, 이번 미실행 |
| 생성 | Lane installation/action을 예약한다 | Keeper payload와 구분된 shape, 혼합 shape 거절 | 소스; 실제 Lane worker 이번 미실행 |
| 생성 | 제목·메시지·대상·알 수 없는 필드를 검증한다 | strict schema/domain/wiring validation | 소스; domain 실행은 envelope/반복 규칙에 한정, tool validation 미실행 |
| 생성 | 상대 지연을 생성 시점 기준으로 적용한다 | tool_wiring의 call-clock 시나리오 | 소스; 이번 미실행 |
| 생성 | 과거·현재 초 경계 예약의 허용 여부가 일관된다 | tool_wiring past/current-second 및 update changed-time 시나리오 | 소스; 이번 미실행 |
| 시간 | one-shot 시각·ISO offset을 처리한다 | domain, Time_codec, wiring | 소스; production Time_codec의 단발 admission/offset 경로 미실행 |
| 시간 | interval·daily·cron을 반복한다 | domain next_due 계산 | domain 28건에 포함, 실행 |
| 시간 | cron 목록·범위·step·요일/날짜 조합을 해석한다 | 5-field grammar; wildcard 및 day OR 규칙 | 실행 |
| 시간 | 윤일·불가능한 날짜·장기간 다음 날짜를 구분한다 | domain leap/impossible date 시나리오 | 실행 |
| 시간 | 시간대를 정한다 | UTC/KST/Asia/Seoul 및 고정 offset, DST IANA 거절 | 실행; DST 자동 보정 기능 아님 |
| 시간 | runner tick보다 작은 interval을 생성·수정한다 | create/update admission이 거절, 저장된 양수 interval load와 별개 | 소스; wiring 이번 미실행 |
| 만료 | expires_at을 두고 예약한다 | due/expiry domain 판정; Task 만료와 별도 도메인 | domain 실행; 실제 만료 dispatch 미실행 |
| 권한 | operator/creator/recipient가 수정·취소한다 | authorize_row_change / authorize_replacement, spoof 거절 | 소스; 기존 권한 테스트 이번 미실행 |
| 출력 권한 | 호출자가 임의 결과 채널을 주입한다 | 생성 시 인증된 origin route 결속; update 시 creator route 유지 | 소스; route 결속 테스트 있음 |
| 수정 | public id를 유지하며 새 instance로 바꾼다 | store update_request, Scheduled/Due 한정 | 소스; 기존 store/wiring 테스트 있음 |
| 수정 | 내용만 수정하면서 과거 due 시각을 보존한다 | unchanged timing과 changed timing 별도 판정 | 소스; 기존 테스트 있음 |
| 수정 | 동시 수정·retime가 저장 결과를 잃지 않는다 | store lock 및 concurrent retime 테스트 | 소스; 이번 미실행 |
| 동시 권한 | 권한 확인 사이 target이 바뀌면 이전 recipient 변경을 거절한다 | mutation lock 안 재인가/instance CAS가 없음; 후속 적대적 리뷰 F3 | **결함 후보** |
| 동시 수정 | due만 바꿀 때 다른 호출이 갱신한 recurrence를 보존한다 | omitted recurrence가 lock 전 snapshot에서 복사됨; F4 | **결함 후보** |
| 수정/취소 | A에 이미 대기 중인 반복 예약을 B로 바꾸고 취소한다 | 이전 owner 철회가 보이지 않음; 아래 F1 | **결함 후보** |
| 취소 | 아직 dispatch되지 않은 Scheduled/Due를 취소한다 | store 취소 후 current-target pending withdrawal | 소스; paused/cancel/race 테스트 있음 |
| 취소 | 전달됐지만 아직 턴이 시작되지 않은 단발을 취소한다 | declaration은 이미 Succeeded이므로 schedule_cancel 거절 | **현행 계약의 기능 한계** |
| 취소 | 이미 시작한 작업·완료된 effect를 되돌린다 | Running/terminal 취소 거절; Lane 인계 효과 취소 아님 | **지원하지 않는 행동** |
| 목록 | 상태·owner·target·limit/cursor로 페이지를 읽는다 | list summary/active/target filter/cursor binding | 소스; 기존 wiring pagination 테스트 있음 |
| 목록 | 빈 목록·부분 목록·조회 실패를 구분한다 | request_count/truncated/read_error, TUI retained observation | 소스; 후보 전체 TUI 미실행 |
| 상세 | 정확한 instance/occurrence·wake 이력을 읽는다 | retained wakes와 exact lookup, instance-bound history | 소스; 과거 producer 행 재생 |
| 상세 | 최신 실패 사유·인계 owner·종단 결과를 읽는다 | queue + reaction evidence를 identity 검증 후 해석 | decoder 실행 + 과거 재생 |
| 상세 | 이후 도구 호출과 최종 산출물을 인과적으로 추적한다 | D4 durable turn/result join은 아직 보장되지 않음 | **미확인/기능 공백** |
| 노트 | note_add로 append하고 notes_list로 읽는다 | primary append lock, actor/body validation, read failure 구분 | 소스; 이번 add→list 통합 실행 없음 |
| 노트 | 최신 N개 노트를 시간순으로 읽는다 | 최신 window를 선택하고 내부는 오래된 순으로 반환 | 소스; schema의 trimming 설명 명료화 필요 |
| 노트 | terminal 정의의 노트를 유지한다 | terminal append 허용, prune와 별도 보존 | 소스; 기존 store 테스트 있음 |
| 노트 | 동시 append·손상·읽기 오류를 처리한다 | store concurrent append / corrupt tests, wiring failure tests | 소스; 이번 미실행 |
| dispatch | due가 되면 wake를 한 번 접수한다 | runner occurrence identity, receipt reconcile, durable enqueue | 소스; 기존 runner/consumer 테스트 있음 |
| dispatch | 접수 후 receipt 저장 실패에도 중복 효과를 피한다 | acceptance reconciliation과 same-occurrence retry | 소스; 기존 테스트 이번 미실행 |
| dispatch | 한 예약 실패가 다른 due 예약을 막지 않는다 | runner independent candidate/retry tests | 소스; 이번 미실행 |
| busy | Keeper가 작업 중일 때 도착한 예약을 보존한다 | durable queue 유지, Busy는 ACK하지 않음 | 소스; 과거 live 관측 있음, 후보 runtime 증명 아님 |
| paused | paused Keeper에 도착해도 유실하지 않는다 | queued demand 유지; pause를 무시하고 실행하지 않음 | 소스; 일반 Resume control 존재 |
| offline | owner가 꺼져 있어도 demand를 유지한다 | acceptance/activation receipt, offline single-acceptance test | 소스; 일반 Boot control 존재 |
| 조치 | notice에서 busy/paused/offline 원인과 다음 행동을 안다 | activation reason을 현재 notice가 투영하지 않음 | **관측·조치 안내 공백** |
| 반복 | 앞 회차가 미소비면 다음 회차를 보류한다 | delivery=none의 previous_occurrence_unconsumed hold | 소스; hold notice 표시 결정 확인 |
| 반복 | 지나간 모든 tick을 빠짐없이 실행한다 | result route가 있는 반복은 오래된 pending supersede 가능 | **보장하지 않음: 최신 회차 정책과 구분 필요** |
| 실행 | 다른 입력의 busy를 이 예약의 실행 시작으로 오인하지 않는다 | exact stimulus/post/instance/target 검증 | decoder 실행 |
| 실행 | 턴 시작·끝·ACK·durable 완료를 구분한다 | 별도 stage; turn end/ACK만으로 Completed 금지 | decoder 실행 |
| 실패 | dispatch 실패와 실제 occurrence 실패를 구분한다 | dispatch outcome/terminal failed 별도 | decoder 실행 |
| 유실 | dispatch 기록만 있고 exact queue가 없으면 경고한다 | Missing, producer-only receipt를 Queued로 올리지 않음 | **이번 감사 수정, 실행** |
| 충돌 | ledger와 queue 종단 증거가 충돌하면 완료로 만들지 않는다 | Terminal_conflict 및 동일 owner 반대 outcome 검증 | **이번 감사 수정, 실행** |
| 인계 | 이전 owner ACK와 새 owner pending을 구분한다 | resolved_owner, Queued_at, transfer projection pending | **이번 감사 수정, 실행 + 과거 재생** |
| 복구 | 재시작 전 Running을 Due로 복원한다 | recover_running_on_startup 정상 경로 | 소스; 기존 store 테스트 있음 |
| 복구 | 첫 startup recovery 실패 후 같은 process에서 회복한다 | 실패 로그 후 normal ticks; recovery 재시도 없음; 아래 F2 | **결함 후보** |
| 복구 | dispatch 실패 정산 write 실패 뒤 같은 process에서 회복한다 | Running 복귀 write 실패 후 재정산 경로 없음; F5 | **결함 후보** |
| 복구 | 손상·stale receipt·결과 불확실을 성공으로 덮지 않는다 | strict decoding, unknown/read_error/settling | decoder 실행 + 과거 재생; backend 전체 미실행 |
| TUI | 도착한 단발이 dispatch Succeeded여도 계속 보인다 | chat_schedule_entries에 unsettled occurrence 포함 | 실제 source 추출 결정 실행 |
| TUI | 선택한 Keeper의 예약만 보인다 | target/generation/single-flight read ownership 재사용 | selection 실행; 기존 shared-read 테스트는 이번 미실행 |
| TUI | 앞 회차 시각·다음 예정·hold가 구분된다 | occurrence clock와 next_due 별도 | selection 실행; 렌더러 소스 확인 |
| TUI | F9로 펼치고 입력 공간·좁은 화면을 보존한다 | 기존 key/event·row budget·render projection 재사용 | 소스; 실제 TUI/키 입력 미확인 |
| TUI | 오래된 조회를 현재 사실로 오인하지 않는다 | generated_at/refresh failure/as-of runner hold | 소스; 전체 async refresh 미실행 |
| 알림 | overdue 때 사용자에게 알려 준다 | persistent chat status notice; 매 tick 반복 popup/message 아님 | notice 구현 있음; OS push/sound 별도 보장 없음 |
| 결과 | 채널/파일에 요청한 실제 결과가 도착한다 | Keeper가 posting tool을 선택; final text 자동 forwarding 아님 | **실제 model→tool→목적지 read-back 미확인** |
| Lane | worker 실행·idempotence·effect unknown을 처리한다 | lane scheduled-act receipt/worker 및 기존 테스트 | 소스; 후보 worker 실제 실행 미확인 |

## 구체적인 결함 후보와 기능 공백

### F1. target 변경 후 취소가 이전 owner의 pending을 남길 수 있음 — P2 후보

1. A가 paused인 상태에서 반복 예약의 회차가 A 큐에 접수된다.
2. operator가 같은 public schedule id의 target을 B로 수정한다.
3. 수정은 새 instance를 저장하지만 A의 이전 pending wake는 철회하지 않는다.
4. 취소는 현재 정의의 target B만 검색한다. 성공 응답 뒤 A가 재개되면 이전 회차가 남을 수 있다.

근거: [update_request](../../lib/schedule/schedule_store.ml),
[replacement 권한](../../lib/tool_schedule.ml),
[cancel withdrawal](../../lib/keeper_schedule_cancel_withdrawal.ml),
[current-target supersede](../../lib/server/server_schedule_consumers.ml).
`update`와 `cancel` 각각의 테스트만으로 이 조합을 증명할 수 없다.
필요한 검증은 실제 임시 저장소에서 A pending→B retarget→cancel→A resume 시나리오다.
이번 표시 PR에서는 백엔드 상태 전이를 바꾸지 않았다.

### F2. 첫 startup recovery 일시 실패 뒤 Running이 같은 process에서 남을 수 있음 — P2 후보

[bootstrap maintenance](../../lib/server/server_bootstrap_maintenance.ml)는
recover_running_on_startup을 한 번 호출하고 Error/exception에도 정상 tick loop에 들어간다.
정상 due 선택은 persisted Running을 제외한다. 첫 recovery write만 실패하고 저장소가 회복하면
후속 tick이 정상으로 보이면서 이전 Running은 다음 재시작까지 남을 수 있다.

이는 새로 발견한 이슈 번호가 필요한 문제가 아니다. 동일 내용의
[#25688](https://github.com/jeong-sik/masc/issues/25688)은
[#25859](https://github.com/jeong-sik/masc/issues/25859)로 통합되어 닫혔다.
현재 소스 경로는 남아 있으나, 과거에 실제 수정됐다가 회귀했는지는 확인하지 않았다.
임시 저장소에서 첫 recovery write 실패→정상화→동일 process 재시도를 재현하고 기존 이슈와 대조해야 한다.
정상 dispatch 시작 후 전역 recovery를 반복하는 수리는 현재 process의 lease를 훔칠 수 있으므로 부적절하다.

### 완료·취소·출력의 의미

- **declaration Succeeded**는 consumer가 전달을 접수했다는 뜻이다. Keeper 작업 완료가 아니다.
- **durable occurrence Completed**는 입력을 처리한 턴의 종단 결과다.
  원하는 PR 리뷰 게시·파일 쓰기·채널 메시지 전달 성공을 그 값 하나로 증명하지 않는다.
- 단발이 이미 접수된 뒤 schedule_cancel로 대기를 취소할 수 없는 것은 명시 스키마와 일치한다.
  사용자 입장에서 필요한 기능인지는 별도 결정이 필요하다. 이를 취소 성공이라고 표시하면 안 된다.
- busy/paused/offline 모두 durable 대기를 유지할 수 있지만 다음 행동은 다르다.
  현재 notice는 공통 대기를 알릴 뿐, pause 해제·boot 필요를 충분히 안내하지 않는다.

## 이번에 실제 실행한 것

[재현 스크립트와 로그](../evidence/2026-10-26-schedule-behavior-audit/README.md):

1. 실제 Schedule_domain 소스와 기존 테스트 **28 PASS**.
2. 실제 occurrence decoder **13 PASS**. 수정 전 추가한 두 반례는 **2/9 FAIL**이었다.
   exact queue miss와 terminal contradiction 수정 후 transfer owner까지 검사했다.
3. 과거 실제 백엔드가 생성한 변경 없는 **14개 행**을 새 decoder로 재생해 예상 판정 일치.
4. 실제 production 선언과 chat_schedule_entries 전체를 추출하여 **8개 selection 결정 PASS**.

이 숫자들은 서로 다른 검사다. 61개 예약 시나리오를 전체 runtime에서 실행했다는 뜻이 아니다.
과거 producer 입력은 `509df9de6eb0a433b1be632ca97adc2353e1f78c`에서 실행된
Test workflow run `40179723721`의 56개 선택 consumer 검사에서 나온 행이다.
현재 실행으로 이월하지 않는다. 원본 출처는
[과거 evidence](../evidence/2026-10-25-schedule-drain-projection/README.md)에 있다.

로컬 Dune/full build, 현재 head의 backend 통합 suite, 실제 TUI 화면,
모델·posting tool·목적지 read-back, 설치·재시작·배포는 이번 실행에 포함하지 않았다.
이전의 제한된 source PASS는 이 전체 기능 판정을 대체하지 않는다.

## 다중 모델·다중 사용자 후속 리뷰

[후속 적대적 리뷰](2026-10-26-schedule-multi-actor-review.md)는 다른 모델로 요청한 독립 리뷰에서
취소 후 실제 pending인 `retained_terminal_wake`를 Cancelled로 만들던 새 P2를 발견했다.
실패 1/12를 기록한 뒤 기존 pending/owner 해석을 재사용해 수정했다.
추가로 F3 권한 TOCTOU, F4 omitted recurrence 경합, F5 dispatch 실패 정산 write 후 Running 잔류의
기존 백엔드 소스 반례를 기록한다. 이들은 실제 다중 사용자/모델 runtime 재현 결과가 아니다.

## MASC 리뷰 대응: 식별자 없는 보존 receipt

[리뷰 5650416953](https://github.com/jeong-sik/masc/pull/46092#pullrequestreview-5650416953)은
서버가 허용하는 null stimulus_id를 필수 문자열로 읽어 전체 목록을 실패시키는 P2를 지적했다.
생산자의 queue=unrecognized_receipt / reaction=missing_stimulus_id를 엄격히 대조하고,
남은 schedule/instance/Keeper/post identity와 진행 증거 부재가 맞으면 Unknown으로 보존한다.
그 밖의 잘못된 형식·identity 충돌은 기존처럼 거절한다. 모든 오류를 무시하는 fallback은 없다.
실제 행/목록 consumer를 추출해 수정 전 혼합 페이지 3/9 실패, 수정 후 추가 음성 대조군을 포함한
13개 결정 통과를 기록했다. 현재 component 상태 검사는 13건이며 상세 출처는 evidence README에 있다.

## 전체 행동 PASS를 위해 남은 확인

1. F1/F2를 실제 임시 저장소로 재현하고 권한·취소·recovery 조합을 수리 또는 반증한다.
2. 현재 후보로 일곱 도구의 생성→수정→목록/상세→노트→취소와 실패·동시성을 실행한다.
3. busy/paused/offline/재시작 각각에서 wake 보존과 정확한 시작/ACK를 관측한다.
4. 실제 TUI에서 F9·refresh 실패·Keeper 전환·부분 페이지·좁은 화면을 확인한다.
5. 예약 요청 하나를 실제 모델에서 처리하고 선택된 posting/file tool 효과를 목적지에서 읽어 확인한다.
6. Lane action의 효과와 불확실 결과·재실행 방지를 현재 후보에서 확인한다.

감사의 완료와 제품 전체 동작의 완료는 별개다. 이 문서는 전체 표면의 근거와 공백을
명시한 감사 결과이며, 예약 기능이 전부 검증됐다는 승인 문서가 아니다.
