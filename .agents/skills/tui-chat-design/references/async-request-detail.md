# 원본 비동기 요청 상세, Connector 조회와 페이지

`tui-chat-design` Skill 의 일부다. 정본 파일과 공통 규칙은 그 Skill 의 SKILL.md 를 따른다.

## 원본 비동기 요청 상세

- Work와 Tools의 Task 본문·이력은 원래 Task 객체/이벤트 목록·Goal 관측·실제 pane 폭에
  결속한 불변 입력을 기존 CPU 경로에서 준비한다. 동일 입력의 draw·scroll·count는 준비한
  전체 행을 재사용하며 프레임에서 전체 원문을 다시 줄바꿈하거나 해시하지 않는다.
- 본문과 이력의 준비는 각각 원래 consumer/원본 run/Task·workspace read epoch·opaque
  ticket·취소 job을 소유한다. source/Goal/폭 변경과 workspace 철회 뒤 늦은 결과는 버린다.
  이전 표시는 같은 consumer/source와 같은 폭에서만 명시적으로 남긴다. 진행·실패 안내는
  현재 조회 상태에서 계속 읽고, 준비한 행을 조회 freshness·효과/완료 허가로 쓰지 않는다.
  준비 완료 전 임시 행 수로 Work의 저장된 스크롤을 초기화하지 않는다. CPU 대기·정리·UI
  반영과 실제 input/paint·속도 증거를 구분하며 화면/문구/행 순서/snapshot/PTY 검사를 추가하지 않는다.
- Tools 원본 Task 본문은 실제 재조회의 GET·workspace admission·새 ticket을 유지한다.
  요청 시 같은 source의 마지막 불변 Task를 캡처하고, 새 응답을 검증·해석한 뒤 공유 CPU에서
  전체 typed Task equality를 확인했을 때만 이전 Task 객체를 재사용한다. canonical Goal과
  해석 진단은 항상 새 응답에서 가져온다. 이 불변 값 재사용은 이전 조회 권한·freshness를
  빌리지 않으며, UI frame에서 본문을 비교·해시하지 않는다. 같은 ID/status여도 본문·계약·
  handoff·실행 링크·정확한 Skill revision 등이 바뀌면 기존 표시 준비를 빌려주지 않는다.
- 로컬 Work는 원본 producer 목록 identity와 안정화한 Task 값을 하나의 private 불변 관측으로
  보관한다. 요청 캡처와 값 접근은 상수 시간이며 별도 mutable fingerprint나 전역 cache를
  두지 않는다. 실제 I/O 읽기와 cache 잠금을 반환한 뒤 같은 원본이면 기존 관측을 재사용하고
  Task 비교용 CPU 제출을 생략한다. 새 원본만 전체 typed 값 비교를 공유 CPU에서 수행한다.
  새 읽기의 membership·순서·Goal·오류·복구 관측을 유지하며 없어진 Task를 되살리지 않는다.
  cold/empty 읽기도 CPU 비교가 필요 없다. Keeper 메타데이터는 이 작업을 기다리지 않고,
  원래 workspace/source/요청 owner가 I/O·비교·최종 반영을 소유한다. 이 identity는 process
  안의 불변 데이터 증거이며 조회 권한·freshness·재시작 내구성·실측 속도 증거가 아니다.
- 로컬 Work·Keeper 메타데이터는 실제 시작한 원래 요청마다 독립 capture를 소유한다.
  `tui_local_read`는 I/O 제출·worker 진입/본문 반환·제출 caller 관측, 실제 Task 비교 선택과
  CPU worker, 전체 caller, UI admission과 상태 적용, 철회·취소 요청·registry 해제를 구분한다.
  immediate는 실제 planner 판정이며 cold/empty를 이미 성공한 cache hit로 바꾸지 않는다.
  누락은 null로 보존하고 실패·취소·시작 불가·늦은 응답도 원래 capture에 남긴다. 같은 숫자
  요청 번호나 source 이름으로 다른 workspace/process의 관측을 합치지 않는다.
- 상세 로컬 읽기 로그는 기존 routine level을 따른다. 기본 INFO에서 JSON을 직렬화하지
  않아도 원자적 사실과 현재 읽기 표시는 남는다. 상세 기록을 켰을 때 v2의 requested
  identity와 이후 변경 사건을 capture ID로 합친다. 누락된 시작/사건을 성공이나 0으로
  만들지 않는다. 로그 크기의 정적 계산은 실제 디스크 사용량·지연 측정과 구분한다.
- Work 목록·Keeper 목록의 읽기 단계는 현재 source의 실제 대기와 atomic 사실에서만 표시한다.
  경과 시간·추정 timeout으로 단계를 만들지 않고 마지막 정상 관측·오류와 함께 읽는다.
  상태 적용은 실제 apply 뒤 기록하며 worker 반환·등록 해제·상태 적용을 paint·입력 가능·
  Task 진척으로 올리지 않는다. 진단 로그/할당 비용도 실제 Before/After 분모에 포함한다.
- 전역 입력창과 비활성 Overview 안내도 원래 메타데이터 source의 상태를 읽는다. 미조회·
  실패·실패 뒤 재시도·이전 관측의 갱신을 구분하고 workspace 미확인 때 옛 로컬 실패를
  빌리지 않는다. Overview는 `source_reading`만 읽고 대상 Keeper의 전체 projection을 하지
  않는다. 비활성 cursor도 projection 전에 Hidden을 반환해 이 경로를 다시 무겁게 만들지 않는다.
  관측 안내는 editable prompt 뒤에 붙여 원래 초안 window·cursor·행 예산을 바꾸지 않는다.
- `keeper_message_availability`가 입력 허용과 설명의 같은 typed 판정이다. 생성 후 요청한
  메타데이터 revision이 아직 관측되지 않은 Keeper를 삭제/부재로 표시하지 않는다. 읽기
  단계나 안내 문자열로 focus·음성·send를 허가하지 않고 실패 동안 초안·대상을 보존한다.
- 전역 입력창의 행과 cursor는 같은 동기 frame에서 대상·음성 prompt·escaped 초안 window를
  한 번 준비해 함께 반환한다. 다음 frame이나 key handler로 대상/초안을 캐시하지 않고,
  실제 입력은 그때의 원래 판정을 새로 읽는다. 준비 횟수 감소는 실측 입력·paint 속도가 아니다.
- 살아 있는 composer(채팅 또는 focused 행)는 원래 `msg_target_keeper_name`의 가용성을
  새로 읽는다. 목록 cursor 갱신으로 초안·음성·전송 대상을 바꾸지 않는다. 비활성 행만
  roster 선택을 따르고, key 판정은 필요한 대상/초안만 동기 조회한다. 결정에 담긴 같은
  Keeper 이름을 실제 동작에 넘기며 표시용 관측·attachment 수를 key마다 준비하지 않는다.
- 대상 전환은 `retarget_message`를 통해 이전 음성 기여도 철회한다. 이미 저장된 텍스트
  초안은 유지하고 진행 중인 녹음은 기존 Discard 정책을 따른다. 철회된 capture의 점유는
  terminal 응답까지 남기며 A→B→A나 이후 Keep 요청으로 되살리지 않는다. 종료 대기
  표시는 실제 철회·점유 사실을 읽고, 이전 callback이 새 대상의 초안·capture를 해제하지 않는다.
- 명시적 채팅 방문 기록은 `Masc_tui_chat_visit`의 세션 FIFO로 저장하고 초안 복원을
  config commit 뒤에 세우지 않는다. 각 효과는 원래 base·Keeper와 Runtime의 최신 파일
  잠금 편집을 사용하며 방문을 합치거나 실패 효과를 재실행하지 않는다. Home은 최신
  opaque request만 저장 결과로 정착시켜 A→B→A의 옛 응답도 거절한다. 저장 대기·거절·
  내구성 미확인·결과 미확인을 구분하고 superseded 실패도 원래 Keeper로 남긴다.
  기존 입력/시간 예산 사이에서 owned 결과를 적용하며 bounded mailbox로 종료 flush를
  막지 않는다. 정상 종료의 drain은 config I/O가 정착하는 경우의 보장이다. 반환하지 않는
  lock/storage 작업은 close를 Closing/미완료에 남기며 종료 시간 상한을 약속하지 않는다.
  caller 취소 보호와 실제 writer 취소·효과 정착을 구분하고, 아직 실행 중인 효과를 추측해
  성공·미저장·결과 미관측으로 정착시키지 않는다. 메모리 초안과 config 영속화, 소스상 대기
  제거와 실측 속도를 구분한다.
- Task 표시 준비는 원래 consumer/요청/run/Task·workspace·폭·ticket에 귀속해 시작, worker
  진입/반환, caller 관측, UI 적용/거절, 소유권 철회, 취소 요청과 실제 등록 해제를 별도로 남긴다.
  같은 요청의 원자적 사실만 준비 단계 안내에 쓰며, 미관측 단계는 null로 남긴다. worker 반환을
  executor 정리 완료로, 등록 해제를 Task 완료나 paint로 바꾸지 않는다. 진단 비용도 비교에 포함한다.
  종단 결과를 거절할 때 그 요청이 아직 소유한 대기 표식만 정리해 같은 입력의 재진입을 막지 않는다.
  교체 요청의 표식·실패·이전 표시는 건드리지 않는다. 원문·context·경로를 진단 로그에 넣지 않는다.
- `t`로 여는 원본 Task는 확인된 run의 `source_task_id`에서만 가져온다. 같은 요청/context의
  이전 논리 관측을 쓸 때는 그 사실과 관측 시각을 남긴다. 현재 Keeper Task나 목록 행으로
  대신 채우지 않는다. 정확한 Task 본문·이력 API를 독립 조회하고 목록에 없는 Task도 읽는다.
- 본문과 이력은 원래 request source/run/Task·workspace read owner·각각의 opaque ticket과
  취소 job을 소유한다. 한쪽 완료·실패가 형제의 pending/기존 관측을 바꾸지 않는다. 명시적
  재조회는 두 원래 읽기를 대체하고 cadence는 각 pending을 공유한다. Esc는 Task에서 원본
  요청으로, 다음 Esc는 요청 목록으로 돌아간다. 철회·동일 ID 재진입도 이전 ticket을 빌리지 않는다.
- Task 본문은 원래 ID echo와 canonical Goal 관측을 확인하고, 이력은 원래 Task ID가 없는
  행이나 충돌한 ID를 거절한다. 알려진 부분 필드 해석 실패도 숨기지 않는다. 두 관측은
  원자적 snapshot이나 Task 완료 증명이 아니다. 기존 완전한 Task 문서 렌더러를 실제 두
  consumer가 공유하며, 문구·배치·snapshot·PTY 검사를 새로 만들지 않는다.
- Task 이력의 최근 배열을 전체 이력으로 부르지 않는다. 이어읽기는
  `/api/v1/dashboard/tasks/history/page`의 원본 Task·요청 cursor echo·다음 cursor를 사용하고,
  파일 교체·변경된 행 경계·해석 실패를 빈 이력이나 종결로 바꾸지 않는다. continuation을
  다른 Task/workspace에 빌려주거나 실패 시 기존 slice로 조용히 대체하지 않는다. 서버 경로가
  있어도 실제 TUI 소비자·재조회·소유권·이전 관측 연결 전에는 화면 개선 완료로 세지 않는다.
- Tools 비동기 목록은 원래 `submitted_by`·request ID·대상 Keeper를 함께 보관한다.
  J/K 선택과 Enter 상세는 그 원본을 사용한다. 요청이 활성 목록에서 사라져도 선택이나
  열린 상세를 다른 행으로 바꾸지 않는다. `o`의 명시적 원본 ID 조회도 같은 경로를 쓰며
  현재 Keeper를 빠진 요청자나 대상으로 채우지 않는다. 원문 ID 입력 중 기존 초안과
  workspace/read authority를 보존하고 철회된 입력으로 새 조회를 시작하지 않는다.
- 단건 GET은 기존 workspace admission·공유 IO/CPU 경계를 쓴다. 원래 요청자·요청 ID·
  대상의 echo와 물리 상태/결과, run·원본 Task·논리 owner·종결 결정을 엄격히 읽는다.
  물리적 대기/실패와 논리적 종결, 조회 불가를 구분하고 조회를 Task 진척으로 표시하지 않는다.
- 상세는 원래 fetched ticket·read authority·선택과 일치할 때만 반영한다. 명시적 재조회는
  이전 worker에 취소를 요청하고 새 ticket을 소유하며, cadence는 진행 중 읽기를 공유한다.
  늦은 응답·worker 정리는 새 읽기를 끝내거나 덮지 않는다. 닫기·pane 변경·workspace 철회는
  원래 읽기만 retire하며 실제 정리는 공통 workspace job registry가 소유한다.
- 같은 원본의 재조회/실패는 이전 물리 관측과 원인을 보존한다. 물리 조회가 성공해도 논리
  읽기에 실패하면, 요청 context까지 같은 이전 논리만 별도로 남기고 최신 확인이 아니라고
  표시한다. 다른 원본이나 workspace에는 이전 관측을 빌려주지 않는다. 목록 재확인 실패도
  마지막 정상 목록을 숨기거나 정상 빈 목록으로 만들지 않는다.
- 상세를 볼 때 cadence는 그 단건을 읽으며 전체 Tool·Skill 목록을 기다리지 않는다.
  이 경로를 실제 화면·키 반응·속도 증거로 부르지 않는다. 검사는 원래 자원·API·소유권과
  상태를 대상으로 작성하고 문구·배치·행 순서·snapshot·PTY 검사는 만들지 않는다.

## Connector 조회와 페이지

- 상태 목록을 받은 뒤 Connector별 server/channel/person cursor 체인은 `read_map`으로
  독립 실행한다. 같은 체인의 다음 cursor는 앞 페이지가 정한 값으로 순서대로 읽는다.
  기존 Eio scope와 IO/CPU 자원을 사용하며 새 executor·동시성 상한·전체 페이지 cap을
  만들지 않는다. TUI runtime이 설치되지 않은 entry point는 동기 map을 사용한다.
- Connector 조회는 기존 공용 `launch_workspace_json_read`를 사용한다. 실제 상태 GET과
  모든 페이지 GET이 원래 workspace binding을 상속하고 응답·304 receipt를 확인한다.
  페이지의 Connector ID·typed 종류·요청 cursor를 확인한 뒤에만 합친다. 앞뒤 identity GET으로
  중간 페이지를 증명하거나 `current_workspace_id`를 filesystem workspace 증거로 쓰지 않는다.
  historical 이름의 provenance와 기존 인증 경계를 유지한다.
- 공용 JSON 조회는 `fork_workspace_job`의 기존 observation 취소 registry에 등록한다.
  실제 구현은 `Masc_tui_workspace_job.fork` 한 곳에 두고 기존 효과/조회 호출은 같은 기본
  범위를 유지한다. Connector는 원래 request의 physical owner를 job key로도 사용한다.
  `cancel_observation`은 정확히 그 key의 관측만 취소 요청하며 실제 정리까지 등록을 유지한다.
  읽기 epoch 철회 시 병렬 child에도 취소를 요청하고 실제 cleanup까지 원래 owner를 유지한다.
  취소 요청·UI의 대기 해제·worker 종료를 같은 시점으로 기록하지 않는다. Connector의
  시작 실패는 원래 요청의 활성 상태를 즉시 해제하고 source 실패를 한 번 전달한다.
  일반 요청·효과의 observation 기본값은 바꾸지 않는다.
- 상태 snapshot은 같은 원래 요청의 `Connectors_status_loaded`로 먼저 전달한다. 실제 상태와
  바인딩은 이름 체인 완료를 기다리지 않고 적용할 수 있으며, 읽는 중인 이름은 별도 단계로
  표시한다. 요청/읽기 epoch/authority를 캡처한 원래 envelope를 사용하고 두 번째 worker를
  만들지 않는다. 중간 상태는 조회 완료나 나중 write의 수요 해소가 아니다.
- 정상 Error 결과는 해당 체인의 앞서 받은 페이지·형제 결과와 함께 남긴다. 예외·부모 취소는
  structured scope를 따르고, 모든 체인을 합친 최종 결과도 같은 원래 요청이 받는다.
  중간 상태 뒤 준비한 binding 조작과 선택은 최종 이름 enrichment가 초기화하지 않는다.
  중복/철회된 상태와 늦은 최종 결과는 적용하지 않는다. source 단계 전달을 실제 UI
  paint·worker cleanup으로 부르지 않는다. 순수 snapshot/page 해석과 이름
  projection만 공용 CPU 경로를 사용한다. `connectors.snapshot.decode_wait`·
  `connectors.names.decode_wait`·`connectors.names.project_wait`는 pool 대기와 반환도 포함한다.
- Connector 조회 제어는 `Connector_read`의 불변 상태와 opaque 원래 요청을 사용한다.
  상태가 아직 대기 중이면 바인딩 write 수요를 합치고, 그 상태 응답이 도착하면 원래 이름
  작업을 철회하고 새 상태 조회를 시작한다. 이미 이름 조회 중이면 write 즉시 그 원래
  관측만 철회한다. 이전 이름 완료나 실제 cleanup을 새 상태 조회의 선행조건으로 두지 않는다.
  이전 응답은 나중 write의 수요를 소비하지 않는다. 후속 read 자체가 철회되어도 시작 당시의
  수요와 나중 write의 수요를 보존한다. 다른 관측이나 효과를 함께 취소하지 않는다.
  같은 workspace 재확인 시 숨겨진 화면의 수요도 다시 시작하고, 확정된 다른 workspace는
  지운다. 이전 요청의 응답·시작 실패 callback은 새 요청의 상태를 정리할 수 없다.
  시작 실패·재조회 실패는 수요를 보존하되 즉시 반복 실행하지 않는다. 명시/기존 조회 경로가
  다시 시작한다. 조회 중·재조회 대기·시작 실패와 마지막 정상 관측을 화면에서 구분한다.
  이 상태는 UI가 소유한 요청/수요이며 실제 worker 종료·paint 완료 증거가 아니다.
  원래 composition 경계는 `docs/audits/2026-10-19-tui-connectors-composed-workspace-reads.md`,
  후속 수요의 As-Is/To-Be와 미실행 시나리오는
  `docs/audits/2026-10-19-tui-connectors-held-reread-owner.md`를 따른다.
  상태 우선 전달과 바인딩 조작 연속성은
  `docs/audits/2026-10-19-tui-connectors-early-status.md`를 따른다.
  write 뒤 재활성과 실제 정리의 분리는
  `docs/audits/2026-10-19-tui-connectors-write-reactivation.md`를 따른다.
