---
name: tui-chat-design
description: "MASC TUI의 원본 비동기 요청·Task·이력 상세와 파일 경계 이어읽기, 소스별 표시 준비 단계·물리/논리 관측, 채팅·입력·로딩·진행 상태, 시작 키 인계와 늦은 터미널 응답, 비동기 조회·설정 저장·긴 질문의 요약과 전체 읽기·Ask 답변과 재조회를 바꿀 때 쓴다. Keeper·Work·로그·Board·Runtime·Overview·Tools·Connectors의 원본 요청·입력·revision·소유권, 준비 상세·현재 턴·이력·구성 조회·디렉터리 페이지의 workspace 검증과 캐시 영수증, 공유 조회와 부분 실패, worker·caller·UI 반영·취소·등록 해제와 paint 증거를 구분한다."
---

# 대화를 먼저 읽는 채팅

정본은 `bin/masc_tui_message_layout.ml`, `bin/masc_tui_render_chat.ml`,
`bin/masc_tui_types.ml`이다. 코드와 다르면 이 문서도 함께 고친다.

## 기본 화면

- `Origin_bare`가 기본이다. 운영자 `›`, Keeper `●`, 외부 발신자 `◀`를 작은 여백에 둔다.
- 외부 발신자는 본문 위에 이름·출처를 남긴다. 운영자와 다른 발신자를 합치지 않는다.
- 본문 시작 열은 동일하다. 시계·넓은 역할 열·턴 레일·TOOLS 같은 종류 라벨은 기본으로 그리지 않는다.
- 도구 본문은 이미 호출 이름과 결과 기호를 갖는다. 별도 `■ TOOLS` 열을 반복하지 않는다.
- 읽기 폭은 최대 100 terminal cells다. 한국어·이모지·결합문자는 display width로 센다.
- 대화 사이의 한 줄 여백은 `Spacing`이다. 대화 맨 끝에는 여백을 세지 않으며, 큰 메시지를 잘라 보여줄 때는 첫 줄과 최신 본문을 보존한다.
- 사용자와 Keeper 본문은 원문이다. 요청 ID, TURN 번호, 처리 확인·시각 안내를 본문에 덧붙이지 않는다.
  시간은 여백·헤더에, 기술 식별자는 본문 뒤에 오는 명시적 진단에 둔다.
  그룹 키·인과 관계·검색과 스크롤의 원본 identity는 그대로 유지한다.
- 아직 처리되지 않은 입력은 `전송 대기`·`전송 중`·`처리 대기`·`전송 확인 중` 상태를 계속 표시한다. 접수를 턴 반영으로 바꾸어 말하지 않는다.
- 글꼴 크기·자간·행간은 터미널 에뮬레이터의 설정이다. 앱은 셀 배치와 여백을 제어한다.

## 시작 입력과 터미널 응답

- 시작 probe에 실제 replay 바이트가 생기면 기능 응답을 더 기다리지 않고 같은 디코더와
  입력 버퍼를 입력 루프에 넘긴다. 미완성 OSC/CSI·UTF-8·paste를 finish하거나 버리지 않는다.
  기존 무입력 deadline/byte cap을 줄이거나 새 reader·timer를 추가하지 않는다.
- probe의 원래 관측 소유자는 byte filter 완료 뒤에도 남는다. 일반 입력 디코더가 읽은 늦은
  palette·theme·query graphics·cell size도 그 소유자에 반영하고, 바뀐 불변 관측만 전달한다.
  NO_COLOR·실제 graphics 거절·첫 유효 응답 정책을 유지하며 theme은 실제 후속 통지를 따른다.
- 이미지·portrait·MSX·악보는 현재 기능 관측을 사용한다. 악보 실행 closure에 초기값을
  붙들지 않는다. 키 인계와 기능 반영은 첫 paint·실제 입력 반응·속도 개선 증거와 구분한다.
  검사는 실제 바이트·프로토콜·관측 소유권을 보고 화면 문구·배치·PTY 검사를 만들지 않는다.
- `tui_startup_observation`은 probe dispatch·worker 진입·수집 종료·caller 관측·decoder 설치·
  기능 적용·첫 입력 decode/loop 수신을 구분한다. 수집 종료를 worker 정리로, 입력 수신을
  명령 성공·Task 진척·paint로 부르지 않는다. 실제 no-byte read를 EOF/timeout으로 추정하지
  않는다. 중단 caller와 늦은 worker 결과, 끝까지 관측되지 않은 단계를 따로 보존한다.
  원래 capture의 사실을 먼저 저장하고 로그를 보낸다. timing은 입력/효과 허가를 고르지 않는다.
- 시작 기록의 오프라인 비교는 `scripts/harness/perf/tui_startup_report.py`와 그 packet 계약을
  따른다. 미수신·중단·잘못된 표본도 전체 분모에 남긴다. 파일 해시 확인과 조건 선언의 일치를
  실행·소스 증명이나 속도 verdict로 올리지 않는다. 서로 다른 process의 monotonic 시각을
  빼거나 같은 capture를 여러 표본에 복제하지 않는다. 이 도구는 TUI/PTY/서버를 시작하지 않는다.

## workspace JSON 조회와 이력

- Work Task 상세와 Tools 원본 Task 이력은 `/api/v1/dashboard/tasks/history/page`를 직접
  읽는다. 원래 Task·cursor echo·schema·page 수요를 CPU worker에서 검증하고 캡처한
  불변 prefix에만 붙인다. `H`는 알려진 이전 cursor로 이어 읽고 `r`은 새 prefix를 읽는다.
  실패는 이전 관측과 같은 재시도 cursor를 남기며 자동으로 legacy 배열을 빌리지 않는다.
  주기 조회는 읽던 prefix를 초기화하지 않는다. 새 workspace/read authority는 기존
  owner를 회수하고 재확인 뒤 새 읽기를 시작한다. 이전 결과와 정리가 후속 요청을
  끝내지 않는다. 본문과 이력은 독립 job이며 이력 demand는 terminal 높이에서 온다.
  cursor 소진은 관측한 저장 prefix의 끝이며 전체 과거 이력·Task 완료·paint 증거가 아니다.

- Goal timeline·Task history·Keeper Calls·저장된 브라우저 이력 목록은
  `launch_workspace_json_read`에서 원래 workspace identity·endpoint·authority·read epoch를
  캡처하고 공통 요청·취소 소유권을 쓴다. 시작 직전 로컬 소유권·확인 상태를 검사하며
  별도 identity GET을 직렬로 먼저 보내지 않는다. 세 HTTP consumer 모두 공통 `get_json`을 통해 실제 GET에
  expected base/root를 붙이고 서버 영수증을 확인한다. raw `http_get`으로 우회하지 않는다.
  `Masc_tui_workspace_read`가 기존 world collector와 같은 fiber binding·JSON/cache 경계를
  소유한다. 병렬 child는 원래 binding을 상속하고 형제 collector의 identity를 빌리지 않는다.
  성공 본문과 304 모두 정확한 단일 영수증이 있어야 현재 관측이나 캐시를 반환한다.
  캐시 주소는 expected root를 포함한다. 관측 확인은 효과·재전송 허가가 아니며 기존
  항목 ID·조회 generation·workspace authority의 응답 적용 조건도 유지한다. 비교와
  미실행 protocol 시나리오는 `docs/audits/2026-10-19-tui-history-workspace-admission.md`를 따른다.
  이력 GET 거절은 해당 source의 실패이며 마지막 정상 관측을 보존한다. 그 실패를 전역
  identity 관측으로 만들지 않고 기존 공유 refresh가 실제 identity를 관측한다. 일반
  `launch_workspace_request`와 효과의 사전 확인은 유지한다. 명시적 read chain의 HTTP는
  identity+history 두 GET에서 history 한 GET으로 줄지만 auth 갱신·연결·재조회·화면 시간은
  별도이며 속도 50% 개선을 뜻하지 않는다. 후속 비교는
  `docs/audits/2026-10-19-tui-history-single-admitted-read.md`를 따른다.
- `capture_workspace_json_read`는 UI 호출 시점에 원래 owner를 캡처해 기존 Eio child가
  실행할 callback을 만든다. 현재 턴 조회도 이 callback을 기존 `Masc_tui_async_read.launch`에
  넘긴다. source 오류 귀속·`on_not_run` inflight 해제·Fork_guard를 유지하고 launcher를
  중복 실행하지 않는다. callback은 worker로 넘어가기 전 실제 GET 경로를 묶는다.
  Keeper별 제어 generation과 workspace completion의 적용 조건은 UI가 계속 소유한다.
  `load_keeper_turns`의 순수 row 해석만 공통 CPU 경로에 넘기며 `keeper.turns.decode_wait`는
  pool 대기·해석·반환 관측이다. 조회는 여전히 명시적 GET 하나이고, 이 변경을 HTTP 감소나
  paint·유용한 작업의 실측 개선으로 부르지 않는다. 비교는
  `docs/audits/2026-10-19-tui-turns-workspace-admission.md`를 따른다.
- 같은 항목 ID를 다시 열거나 새로 읽을 수 있으므로 ID만으로 응답을 적용하지 않는다.
  `begin_task_history_read`/`begin_goal_timeline_read`가 받은 원래 request를 완료까지 보관한다.
  명시 재조회는 `Masc_tui_fetched.refresh`로 이전 요청을 대체하고, 일반 `start`의 공유 정책은
  유지한다. 재조회 중 마지막 정상 관측과 조회 진행을 구분해 표시하고, 재조회 실패/재시도는
  마지막 관측과 실패 이유를 함께 남긴다. 최초 값 없는 실패는 빈 이력이 아니다.
  값 없는 실패의 명시 재시도도 알려진 원인을 유지한다. 이때 view는 `Failed`이며
  `in_flight`가 새 요청의 대기를 구분한다. 재시도만으로 복구됐다고 표시하거나 빈 값을 만들지
  않는다. suspension은 재시도 소유자만 철회하고 원인은 보존한다. 상세 비교는
  `docs/audits/2026-10-19-tui-retry-failure-observation.md`를 따른다.
- workspace 철회 시 `withdraw_detail_histories`로 두 값과 대기 소유자를 함께 철회한다.
  재진입/다른 workspace의 같은 ID가 이전 request를 빌리지 않게 generation을 초기화하지 않는다.
  조회 중/조회 완료는 Task 진행·효과·Goal 성공이 아니다. 상태/원래 이벤트 경계를 검사하며
  문구·배치·행 순서·PTY 검사를 추가하지 않는다. Before/After는
  `docs/audits/2026-10-19-tui-detail-history-ownership.md`를 따른다.

## Tools 구성 조회

- inventory·Skills catalog·async-request 관측은 서로의 결과를 입력으로 받지 않는다.
  `launch_tools_load`의 원래 dispatch에서 각각 `launch_workspace_json_read`로 시작한다.
  inventory의 완료 callback에서 형제 조회를 새로 시작하거나 별도 identity GET을 붙이지 않는다.
  세 GET 모두 원래 workspace의 expected root와 서버 receipt·cache 경계를 사용하며, 세 응답을
  동일 시점의 원자적 snapshot으로 부르지 않는다. 자동 재조회 공유·명시 재조회 supersession·
  선택한 Keeper·generation·workspace authority·read epoch의 적용 조건을 유지한다.
- Tools의 각 pane은 자기 구성의 pending 슬롯과 관측·실패를 함께 표시한다. 최초 조회·이전 값이
  있는 재조회·실패 뒤 재시도를 구분하고, 원래 진행 generation에서만 읽는 중이라고 표시한다.
  등록 도구 수는 실제 inventory snapshot이 있을 때만 보이며 미조회를 0개로 바꾸지 않는다.
  진행 표시는 요청·적용·선택·재조회 정책을 바꾸지 않는다.
- 세 pending 구성은 기존 UI 처리에서 각각 정리한다. 한 구성의 지연·실패가 형제의 결과를
  덮거나 막지 않는다. 실패 중 마지막 정상 관측을 유지하고 warming·미초기화·관측 불가를
  정상 빈 값으로 바꾸지 않는다. switch 부재도 공유 launcher의 각 구성 실패로 정리한다.
- 세 typed decoder의 순수 JSON 해석만 기존 공용 CPU 경로에 넘긴다. HTTP·인증·cache·
  pending·선택·UI 상태를 worker로 옮기지 않는다. `tools.inventory.decode_wait`·
  `skills.catalog.decode_wait`·`tools.async_observation.decode_wait`는 pool 대기와 반환도
  포함하며 순수 CPU 시간·paint·Task 진척이 아니다. 명시적 정상 경로의 GET 6→3은
  실제 속도 50% 개선을 뜻하지 않는다. 비교와 미실행 시나리오는
  `docs/audits/2026-10-19-tui-tools-composed-workspace-reads.md`를 따른다.

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

## 에디터 준비 조회

- Keeper 설정의 `e`는 workspace 확인·설정 snapshot 읽기·재확인을 소유된 비동기 조회로
  시작한다. 키 처리 안에서 HTTP를 기다리거나 아직 확인하지 못한 이전 snapshot을 열지 않는다.
- 반복 `e`는 진행 중이거나 편집 대기 중인 같은 요청을 공유한다. Esc, Keeper·화면·탭 이동,
  다른 입력창·모달 진입, workspace/read authority 철회는 그 준비를 취소한다.
- snapshot이 도착해도 대기 중인 키·붙여넣기·미완성 terminal sequence가 있으면 먼저 처리한다.
  같은 편집 intent만 한 번 에디터에 넘긴다. 늦은 응답·worker 정리는 후속 요청을 바꾸지 않는다.
- 편집 text와 patch 기준은 같은 원본 snapshot이다. 저장 전 workspace 확인과 revision 충돌
  처리는 유지한다. 외부 에디터의 terminal interaction과 아래의 비동기 저장 작업을 구분한다.
- 준비 시작·읽기 완료·상태 반영·에디터 인계는 별도 시각으로 관측한다. 인계 시각을 에디터
  실제 표시·키 응답·실제 작업 진척으로 부르지 않는다. 화면 문구·배치 검사를 추가하지 않는다.

## Keeper 설정·Sandbox 저장

- 외부 에디터가 돌려준 원래 text·snapshot·composite revision·patch를 소유된 저장 작업에
  둔다. workspace 재확인과 설정 POST를 키 처리에서 기다리지 않는다. 같은 Keeper의
  pending `e`는 원래 작업을 공유하고, 다른 Keeper의 저장은 별도로 소유한다.
- navigation은 저장 취소 선언이 아니다. authority 철회·중단 전후를 미전송과 결과 미확인으로
  나누고 영수증은 bounded mailbox 없이 남긴다. 알려진 미적용 거절·revision 충돌·조정 필요·
  적용 후 runtime sync 실패를 따로 보존한다. 늦은 영수증은 다른 Keeper 화면을 갱신하지 않는다.
- 실패 뒤 `e`는 current snapshot을 새로 읽고 변경했던 값만 편집기에 복원한다. 손대지 않은
  필드는 current 값을 쓰고, 이전 revision과 context 축소 확인은 재사용하지 않는다. 편집기에서
  다시 확인하기 전 재전송하지 않는다. 원래 작업의 입력·응답은 후속 복구가 덮어쓰지 않는다.
- Sandbox `d/m/s`는 SSOT의 typed profile을 같은 저장 작업에 캡처한다. worker가 최신 config
  snapshot과 composite revision을 읽고 workspace/read owner를 재확인한 뒤 그 profile만 CAS로
  보낸다. 현재 profile이 같아도 revision을 검증한 뒤 미전송 결과로 남긴다. key handler에서
  HTTP를 기다리거나 cached pane의 revision으로 대체하지 않는다.
- 같은 Keeper의 editor/shortcut pending은 직렬화한다. 다른 profile 키가 원래 요청을 바꾸지
  않는다. 종료 뒤 명시적 새 키만 다시 current를 읽는다. shortcut은 남아 있는 editor 초안을
  지우지 않으며 `e` 복구에 섞이지 않는다. 읽은 snapshot·patch는 원래 영수증과 같이 보존한다.
- 시작·worker 관측·UI 반영 시각과 phase를 연결한다. 화면의 진행/복구 안내와 이 로그는
  실제 paint·키 응답·작업 완료·속도 향상 증거가 아니다. 외부 에디터의 terminal interaction은
  별도다. shortcut의 최신 조회 때문에 총 논리 HTTP 수가 늘어도 입력 처리 대기와 구분한다.

## Keeper Runtime assignment

- picker에서 Keeper·workspace/read owner·구체 Runtime 또는 default 복귀 선택을 원래
  저장 작업에 캡처한다. config snapshot과 assignment revision은 worker가 읽고 원래 영수증과
  함께 보존한다. 기존 비동기 config GET→assignment POST 두 요청을 유지하며 key handler가
  HTTP를 기다리지 않는다. POST 직전 local authority/read owner를 재확인하고 server assignment
  CAS를 유지한다. 서버의 atomic workspace precondition이 새로 생겼다고 주장하지 않는다.
- 같은 Keeper의 Settings/Sandbox/assignment pending은 겹쳐 보내지 않는다. 거절된 admission은
  picker 선택을 닫지 않으며 다른 Keeper의 저장은 독립이다. navigation 자체는 취소가 아니다.
- 중단 전후를 미전송/결과 미확인으로 나누고 bounded mailbox 없이 session 영수증에 남긴다.
  알려진 auth 거절·검증된 revision conflict·committed·unchanged와 lock warning을 구분한다.
  HTTP 400에는 IO/atomic-replace 실패도 포함되므로 미적용으로 단정하지 않는다. 다음 명시적
  선택만 current를 새로 읽고, 이전 작업을 자동 재전송하지 않는다.
- 저장된 assignment와 현재 Keeper turn의 실행 Runtime은 별개다. worker 관측·UI admission
  시각도 실제 paint/입력 반응/속도 향상으로 부르지 않는다. 원래 작업의 늦은 영수증이 다른
  workspace의 catalog 갱신 권한을 빌리지 않도록 한다.

## 공유 Runtime catalogue 조회

- 같은 workspace/read owner의 진행 중 catalogue 조회는 소비 화면이 공유한다. 이미 비동기인
  경로를 다시 감싸거나 GET을 추가하지 않는다. 기존 effect-free read-demand order를 사용하며,
  명시적 refresh·저장 후 조회 요구는 진행 중 요청 뒤의 새 조회 한 번으로 모은다. 앞선 응답을
  저장 후 최신 관측이라고 부르지 않는다. Overview/Runtime surface의 별도 reader까지 공유됐다고
  확대해서 주장하지 않는다. ETag 재사용은 진행 중 요청 공유와 별개다.
- full decoder가 반환한 typed snapshot과 assignment를 함께 재사용한다. 기본 route를 얻으려고
  같은 JSON의 snapshot을 다시 해석하거나 현재 전역 catalogue를 끌어오지 않는다. lane 참조·
  runtime 중복·default 일관성 검증과 usage 관측의 독립 오류를 유지한다. 순수 catalogue 해석은
  기존 response-decode CPU 경로에서 하고, HTTP/cache·read owner·UI 반영은 caller에 둔다.
  `runtime.catalog.decode_wait`는 pool 대기와 결과 전달을 포함하며 paint·순수 CPU 시간은 아니다.
- Overview는 같은 응답의 usage를 한 번 캡처한 typed observation으로 catalogue와 usage의
  독립 결과를 만든다. catalogue가 snapshot의 usage 지점 전에 실패해도 읽을 수 있는 usage는
  남기고, usage 오류는 정상 catalogue를 막거나 이전 응답의 quota identity로 대체하지 않는다.
  snapshot/full 전용 경로는 기존 검증 순서를 유지한다. 공유하는 것은 현재 응답의 해석이며
  HTTP reader·ETag cache·request owner까지 합쳐졌다고 주장하지 않는다.
- 재조회·실패 중 마지막 정상 catalogue를 남기고 refreshing/stale과 마지막 실패를 함께
  보여 준다. 정상 empty 결과는 loading이 아니다. 기존 exact replacement의 fresh-read 조건은
  유지한다. 화면 문구 기대값 대신 요청·소유 상태·결정 시나리오를 작성한다.
- workspace/read 철회는 원래 요청을 retire하고 필요한 중첩 조회 demand를 보존한다. 재확인 뒤
  새 요청 하나가 철회된 read와 후속 refresh를 대체한다. 다른 workspace로 전환하면 원래 목록과
  demand를 지운다. 요청 시작·worker 관측/중단·UI admission은 paint나 실제 속도 증거가 아니다.

## 복합 조회의 부분 수신

- 실제 반환한 Result에서 typed 관측을 만든다. Runtime 목록/사용량, Board 글/hearth,
  Keeper 목록/Candle의 구성별 수신·실패를 보존한다. 혼합 결과는 partial로 기록하며 전체
  수신·전체 실패로 누르지 않는다. 바깥 roster 오류처럼 구성 결과가 없는 경우는 만들어내지 않는다.
- partial은 received와 별도로 집계한다. 수치는 논리 reader 단위이며 HTTP 호출·Task 완료
  횟수가 아니다. roster 응답의 수신도 fleet 전수 관측이나 해당 데이터의 완전성을 뜻하지 않는다.
- Runtime·Keeper의 구성 결과는 부모 reader가 반환할 때 함께 관측하며 별도 시각을 추정하지
  않는다. Board 글/hearth는 실제 reader의 시작·반환·예외·취소에서 각각 기록한다. 부모가
  반환하기 전에도 받은 구성을 남기고, 부모 중단이 이미 끝난 구성의 결과·시각을 덮지 않는다.
  실제 취소를 받은 interrupted와 종료 시점까지 결과가 없는 unfinished를 구분한다.
- 진행 이벤트는 각 refresh의 atomic 수신함에 먼저 기록한다. 공용 bounded mailbox를 기다리지
  않으며 UI drain·종단 적용·초기 identity 재결속 전에 회수한다. 후속 refresh는 새 수신함을
  소유하고 늦은 worker는 이전 수신함만 쓴다. ticket·authority 검증은 UI 반영 시 유지한다.
  child 시간은 관측 구간이며 unfinished의 끝은 UI 종료 경계다. 실제 worker 종료·순수 HTTP
  시간·paint·입력 가능·작업 완료 증거로 확대하지 않는다.
- header는 실패한 구성과 받은 구성을 함께 보인다. JSON/log에는 구성별 결과를 남기되 현재
  workspace/read owner·dataset 반영·후속 조회 판단을 바꾸지 않는다. 화면 문구나 배치 검사 대신
  receipt·구성·소유권·종단 상태의 연결을 확인한다.
- Board 글과 hearth 데이터는 같은 요청의 별도 dataset 슬롯을 소유한다. 각 기존 GET의
  workspace precondition·서버 receipt를 유지하며 먼저 반환한 데이터를 형제 조회 전에
  보낸다. 한 쪽 수신·실패는 그 슬롯만 한 번 소비하고 다른 쪽의 결과·오류를 덮지 않는다.
  Board 대기는 남은 슬롯이 있으면 유지하며 실제 collector 종료와 구분한다. navigation은
  두 슬롯 모두 새 owner로 바꾸고, terminal bundle은 아직 반영하지 않은 슬롯만 처리한다.
  기존 글 cursor·초안과 census의 마지막 정상 관측 유지 정책을 보존한다. UI 반영 로그는
  source와 dataset을 구분하며 paint·실측 속도나 원자적 Board snapshot으로 부르지 않는다.
- census는 raw 목록 대신 기존 Fetched view로 미조회·최초 읽기·수신·이전 값과 실패·값 없는
  실패를 표현한다. 진행 여부는 기존 hearth dataset 소유권에서 읽으며 별도 요청 세대나
  타이머를 만들지 않는다. 재조회·실패 중 값은 목록·팔레트·hearth 이동에서 함께 유지한다.
  header·reader index의 전체 수치는 수신 후 census 대기가 없는 경우만 쓰고, 나머지는
  census 줄·팔레트에서 마지막 관측임을 밝힌다. 정상 empty와 조회 실패를 같은 0으로 만들지 않는다.
- terminal이 census 슬롯을 가져갔지만 실제 반영하지 못했거나, 소유 collector가 결과 없이
  끝나면 미수신을 unavailable로 남긴다. 이전 collector가 현재 슬롯을 소유하지 않으면
  새 관측을 실패로 바꾸지 않는다. workspace 철회는 census 값과 후보도 지워 다른 Board
  데이터와 같은 경계를 지킨다. 이 상태·문구는 worker 종료나 paint·속도 증거가 아니다.
- 글 목록도 Fetched 관측 하나에 실제 글과 상태를 함께 둔다. 초기 글 조회 중과 미조회·정상
  empty·실패를 구분하고, 대기는 Board_posts 슬롯에서 읽는다. census 대기를 글 조회로
  표시하지 않는다. 같은 관측을 목록·검색·팔레트·상세 sidebar·키 입력 대상에 쓴다.
  재조회·실패 중 글과 선택·작성 초안을 유지하고 마지막 관측임을 표시한다.
- 상세 응답은 일치하는 글만 갱신하며 목록의 실패·진행 슬롯·순서를 바꾸지 않는다. 새 목록은
  기존 identity 기반 선택 규칙을 사용하고, filtered 목록의 부재로 원본 detail을 닫지 않는다.
  terminal 미반영·소유 collector의 미수신은 목록도 unavailable로 남기며 이전 cleanup은
  새 관측을 낮추지 않는다. 오류 알림의 마지막 발행 기록은 관측과 별도로 두어 내부 미수신
  상태가 같은 오류 알림을 반복 발행시키지 않게 한다. workspace 철회는 목록 후보도 지운다.
- 글 응답은 dispatch에서 고정한 정렬·hearth를 early/terminal 양쪽에 함께 운반한다.
  정상 empty도 그 query와 묶어 저장한다. 필터 변경·실패·상세 갱신이 보존한 글의 출처를
  현재 controls로 바꾸지 않게 한다. 목록/sidebar·팔레트는 query 불일치도 마지막 관측으로
  밝히고 정렬 설명·시간 열·census total은 실제 목록의 query/hearth를 쓴다. 선택 controls는
  요청 조건을 유지한다. query 일치는 formatted 문자열이 아니라 typed sort와 정확한
  optional hearth로 판단한다. metadata는 기존 workspace/refresh/dataset owner를 대신하지
  않으며 미수신은 정상 query 결과가 아니다. 추가 GET·owner 세대·timer·화면 행을 만들지 않는다.
- 글 반영 진단은 실제 반영 함수가 반환한 불변 관측을 early/terminal 로그에 함께 쓴다.
  성공·실패는 원래 응답 query, 반영 당시 요청 controls, 남은 정상 목록 query를 따로 둔다.
  미수신은 delivery query가 없고, 최초 실패는 정상 목록 query도 없다. 정상 empty의 query와
  모두 구분한다. terminal의 남은 소유 슬롯과 workspace admission을 통과한 경우만 missing을
  기록하며 consumed·superseded·거절된 슬롯에 가짜 반영 기록을 만들지 않는다. 진단 JSON은
  제어 입력으로 쓰지 않고 본문·오류 text를 복사하지 않는다. 로그 필드의 소스 구현은 실제
  로그 발생·worker 종료·paint·실측 속도 증거가 아니며 화면 문구 검사를 추가하지 않는다.
- full/navigation dispatch의 context는 원래 요청·현재 opaque owner·예정 Board query를
  함께 보존한다. cold identity가 owner를 바꿔도 원래 query를 현재 controls에서 다시 만들지
  않는다. 미요청 Board의 null intent와 결과 미수신의 null delivery query를 구분한다.
  worker의 early/terminal admission에는 기존 current request를 그대로 쓰고 metadata를
  권한·범위 게이트로 쓰지 않는다. dispatch 로그는 실제 GET 시작이 아니며 rebind는 UI owner
  생성/ack 제안이다. cleanup 로그는 finalizer 밖에 두고 기존 취소·예외 전달을 유지한다.
  시작만 남은 요청은 미완료 관측으로 보존하며 시간 경과로 종료·실패를 추정하지 않는다.

## Runtime 폼 저장

- 모델·계정 폼은 원래 입력과 opening revision으로 소유한 비동기 작업을 만든다.
  workspace 확인·source 읽기·선언 생성·preview·CAS commit을 키 처리 안에서 기다리지 않는다.
- pending 재제출은 같은 작업을 공유한다. 전송 전 중단은 미전송, 가능한 commit dispatch
  이후 응답 단절은 결과 미확인이다. 취소 중 bounded mailbox를 기다려 결과를 잃지 않는다.
- Esc는 폼을 떠나며 commit 취소라고 말하지 않는다. 기존 편집/추가 키는 원래 폼을
  복구한다. 미확인 폼은 재전송을 막는다. 종단 결과 뒤 Ctrl-X로 복구를 닫고 source를
  다시 읽은 뒤 새 폼을 열 수 있다. 원래 영수증과 입력은 session operation에 남긴다.
- 늦은 결과는 후속 폼·다른 workspace를 바꾸지 않는다. commit 영수증 보존과 현재
  workspace의 재조회 권한을 분리한다. 관측 시각을 paint·키 응답·작업 진척으로 부르지 않는다.

## Runtime 원문 저장

- Config 원문 편집 후 저장과 S 재시도도 폼의 같은 비동기 작업·CAS 경로를 쓴다.
  원래 path/revision/text를 보존하고 키 처리에서 저장 HTTP를 기다리지 않는다.
- source 재조회·실패 주석은 같은 draft owner를 유지한다. 편집·명시적 base 채택·교체는
  새 owner다. 늦은 성공은 원래 owner만 끝내고 같은 본문의 새 편집도 지우지 않는다.
- 결과·내구성 미확인은 본문을 유지하고 과거 비교 자료를 해제한다. 당시 진행 중이던
  read generation 이하의 결과는 재확인으로 쓰지 않는다. 새 read 뒤 u/U로 고른 base만
  재시도를 허용한다. 미확인 전 고른 다른 base나 X 뒤 cached source 재열기로 우회하지 않는다.
- 비교 자료를 해제해도 나중에 편집한 본문·owner를 바꾸지 않는다. 영수증·초안은 원래
  workspace에 속하고 read authority를 부여하지 않는다. 외부 편집기 사용 시간과 저장 대기,
  parser-only 확인과 실행·paint·속도 증거를 나눈다.

## Runtime 설정 snapshot

- Config 조회는 같은 immutable source/metadata/account groups/model bindings로 전체 source
  분류·terminal 정제·모델 표를 공유 CPU 경로에서 만든 뒤 UI에 전달한다. 서버가 이미 해석한
  선언 projection을 쓰며 Runtime 원문을 재파싱하지 않는다. UI·palette·요청 소유권을
  worker에서 바꾸지 않고, 들어간 작업이 던진 예외를 caller에서 재실행하지 않는다.
- source/model 해석 실패와 account email 실패를 나눈다. 모델 표 실패를 정상 빈 catalogue로
  바꾸거나 원문을 숨기지 않는다. 모델 선택과 저장 revision은 같은 reading에서 온다.
- model bindings는 같은 path/revision의 명시적 결과만 받는다. 필드 부재·불일치·잘못된 행은
  모델 오류이며 원문과 독립 관측은 유지한다. 로컬 파서나 현재 전역 catalogue로 대체하지 않는다.
  원문만 해석하는 폼 경로의 Runtime 파서는 여전히 환경을 읽으므로 순수 decoder에 넣지 않는다.
- 원문 분류는 path/full text가 같은 불변 값만 재사용한다. 재조회는 기존 초안 분류와
  snapshot의 current 분류를 공유하되 초안 owner·base 선택·read generation을 바꾸지 않는다.
- 원래 workspace/read authority·요청 generation·후속 read 정책이 반영을 결정한다.
  superseded 준비 작업이 끝나도 반영 권한은 없다. pool 부재/이미 worker의 inline 정책과
  새 편집·비 snapshot 변경의 분류는 남는다. 이 변경을 모든 CPU 작업 제거로 부르지 않는다.
- 시작·준비 결과·UI 반영 결정 시각은 같은 generation과 시작 시각으로 연결한다.
  pool 대기/IO/해석을 포함한 구간을 순수 CPU 시간·paint·키 응답·실제 작업 진척으로 부르지 않는다.

## 서버 Runtime source 준비

- raw Config 응답은 원본 source/revision을 보존하고 Keeper-normalized syntax 입력과
  Runtime 원문 입력을 먼저 구분한다. 정확한 바이트가 같을 때만 AST를 공유한다.
  CRLF/말미 CR 정규화로 입력이 달라지면 각각 파싱해 문자열·오류 의미를 유지한다.
- AST를 공유해도 Keeper 문서/검증과 Runtime semantic validation은 독립이다. 한 쪽 실패를
  다른 쪽 정상 빈 설정으로 바꾸지 않는다. 잘못된 AST root도 닫힌 오류로 거절한다.
- Runtime model bindings는 이 요청의 이미 해석한 config에서 순수하게 만든다. 원래 path와
  revision을 붙이고 context 선언 출처·binding 식별자를 보존한다. 계정/credential 경로나
  인증 값은 이 projection에 넣지 않는다. 계정 그룹·email 관측과는 별도 결과다.
- 환경 확장·현재 overlay·계정 파일 관측이 포함된 JSON 준비는 기존 shared IO job이다.
  auth 확인·HTTP 응답 쓰기·기존 commit 적용/audit/protection 경계를 옮기지 않는다.
  이 작업을 순수 CPU나 전체 HTTP I/O 제거로 부르지 않는다.

## 보기 전환

| 키 | 순서 | 기본 |
|---|---|---|
| Ctrl-F | 대화 → inline metadata → origin heading → 대화 | `Origin_bare` |
| Ctrl-N | 숨김 → 요약 → 전체 → 숨김 | `Memory_hidden` |
| Ctrl-D | compact → results → full → compact | `Tools_compact` |
| Ctrl-R | folded → full → hidden → folded | `Reasoning_folded` |
| Ctrl-S | 턴 상세 접기/펼치기 | 기존 상태 유지 |

기본 설정을 알리는 `metadata:off`, `journal:off` 배지를 붙이지 않는다.
사용자가 연 상세 모드만 제목 옆에 표시한다. 모든 단축키는 도움말에서 찾는다.

## 상세 레이아웃

`Origin_inline`은 시계, 화자 열, 턴 레일을 표시한다. 같은 분의 시계와 같은 화자의 이름은 반복하지 않는다.
`Origin_row`는 화자와 시각을 별도 헤더에 표시한다. 소유 Keeper의 이름은 대화 제목과 중복하지 않는다.

상세 표식: 운영자 `▶`, 외부 발신자 `◀`, Keeper `●`, 상태 `○`, 로컬 명령 `›`,
저널 `◈`, 도구 `■`, 추론 `·`, 오류 `✗`. 스킬은 상태에 따라 `◇ ◆ △ ✗`를 쓴다.
색이 없어도 의미를 구별할 수 있어야 한다.

턴 레일은 `╭ │ ├ ╶ ╰`로 같은 턴의 인접 행을 연결한다. 외부 도착은 `───┤`,
저널은 `╌╌╌┤`로 구분한다. 원본 identity로 묶으며 표시 문자열로 그룹을 결정하지 않는다.

## 정보의 밝기

- 대화 본문은 전경색이다. 사용자가 보낸 글의 배경은 본문 영역 안에만 둔다.
- 도구·스킬·추론·저널은 dim이다. 강조나 링크가 닫힌 뒤에도 원래 밝기를 복원한다.
- 제목·시계·상태 크롬은 recede다. 진행줄 전체를 밝은 청록색과 대문자로 강조하지 않는다.
- 실패와 조치 요청은 보이게 남긴다. 내용을 보고 오류인지 추측하지 않고 타입을 사용한다.
- 실제 도구 결과는 Ctrl-D로 펼친다. 결과 수신 `↩`는 성공 판정이 아니다.

## 입력 주변

- 현재 대화의 진행 상태는 한 줄로 표시한다. 현재 호출·응답 상태만 남긴다.
  진행 타이머(요청·호출 경과 시간, 무응답 시간)와 누적 도구 목록·런타임 ID는 상세 레이아웃에 둔다.
- 서버 준비 미리보기는 원래 operation의 실행 ID(배치 binding 포함)나 자율 실행의
  정확한 turn reference로만 진행줄에 연결한다. 조회 시점의 상태는 `최근 확인`으로
  표시한다. provider·Tool 활동이 관측된 뒤에는 늦은 준비 조회가 이를 대체하지 않는다.
  Keeper 이름이나 시각만으로 다른 실행의 상태를 빌리지 않는다.
- 자율 journal이 아직 없을 때의 준비는 실제 Owner 슬롯의 `현재 작업` 관측으로
  표시한다. 대기 중인 요청의 접수·실행으로 바꾸지 않는다. 같은 원래 턴의 provider
  관측이 들어오면 journal 이전에 읽은 snapshot도 이 별도 줄로 다시 그리지 않는다.
- `작업 맥락 조회`는 실제 Lane·workspace memory·wiki 조회의 바깥 scope다.
  병렬 분기가 모두 끝났다는 사실과 각 출처가 정상이라는 판정은 구분한다.
- 첫 공통 프롬프트 조립은 원래 writer의 Prompt 준비 관측이다. 후속 Tools별
  재투영을 새 실행 시작이나 이전 준비 상태의 재개로 표시하지 않는다.
- 준비 단계 기록은 같은 writer가 보관한 scope ID와 원래 operation·turn reference로
  상세에 연결한다. provider 활동 뒤 완료된 준비 기록도 현재 진행줄을 되돌리지 않는다.
  중첩된 단계의 시간은 겹치므로 합산해 전체 대기 시간으로 표시하지 않는다.
  scope ID는 writer 안에서만 의미가 있다. 다른 실행의 같은 숫자를 이어 붙이지 않는다.
  live timeline은 실행 중 관측이며 저장된 과거 턴 기록이나 재시작 복구 증거가 아니다.
  펼친 대화 상세의 Keeper만 이력을 요청한다. 미요청 `null`은 확인한 빈 이력과
  구분하고, 전체 Keeper 상태 조회에 이력을 일괄 첨부하지 않는다.
- 선택된 종료 작업의 상세를 펼치면 기존 runtime trace에서 저장된 준비 보고서를
  읽는다. 자율 journal의 원래 turn reference, 직접 요청의 기록된 reply 또는 정확한
  종단 operation의 outcome reference와 실제 batch execution ID로 연결한다. reply와
  operation의 연결이 다르면 어느 쪽도 고르지 않는다. 실패 알림이 저장보다 먼저 오면
  펼친 선택 작업의 operation만 기존 turns 관측 주기에 다시 확인한다. 종단 metadata를
  확인한 뒤에는 연결이 없는 경우에도 이 추가 조회를 끝낸다. 연결을 추정하지 않는다.
  보고서 UUID마다 scope 번호를 별도로 읽으며, 저장 당시 active는 `기록 당시 미완료`다.
  부분 조회·지원하지 않는 기록·중복 보고서·조회 실패를 빈 이력이나 성공으로 바꾸지 않는다.
  이 정보는 상세 진단이며 현재 진행줄을 바꾸지 않는다. 선택·저널 revision·workspace가
  바뀌면 이전 응답을 분리하고, 같은 저널 revision의 완료된 읽기는 재사용한다.
  같은 Keeper의 명시 재조회는 이전 요청 capability를 폐기하되 같은 원본 target의 마지막
  성공 관측을 남긴다. 재조회 대기·진행·실패를 구분해 표시하고 이전 기록을 최신으로
  확인한 것처럼 그리지 않는다. 다른 Keeper의 이력 새로고침은 이 읽기를 폐기하지 않는다.
  숨긴 상세의 완료는 원래 선택에만 보관하고, 새 실행·revision·workspace는 빌리지 않는다.
  조회 범위의 지원하지 않는 이벤트·잘못된 저널 행·잘못된 JSON 행은 별도 종류로 보존한다.
  잘못된 행은 선택 턴에 귀속할 수 없으며, 조회 범위 수와 반환 행 수를 실패 작업 수로 합치지
  않는다. 제외된 준비 보고서의 실제 해석·연결 거절 이유를 상세에 남기고 단일 행으로 정제한다.
- 준비 상세 GET도 `launch_workspace_json_read`와 공통 `get_json`을 쓴다. 로컬 authority·
  read epoch·identity·endpoint를 확인하고 실제 GET에 expected roots를 붙인다. 2xx와 304의
  서버 영수증 검증·캐시 갱신은 호출 fiber가 소유하며 별도 identity GET을 먼저 보내지 않는다.
  기존 target의 journal/revision·Turn_ref·operation 연결은 그대로 검증한다. JSON과 순수 report
  해석만 공통 CPU 경로에 넘기고 worker에서 workspace binding·HTTP/cache·선택을 바꾸지 않는다.
  `keeper.preparation.decode_wait`는 pool 대기·해석·반환 관측이며 순수 CPU·paint·유용한 작업
  완료 시간이 아니다. source 비교와 미실행 복합 시나리오는
  `docs/audits/2026-10-19-tui-preparation-workspace-admission.md`를 따른다.
- Lane·공유 메모리·Wiki 확인의 시간은 풀 대기와 취소 정리를 포함한 호출자 대기다.
  순수 IO 시간이라고 표시하지 않는다. 출처 조회 실패는 `조회 불가`이며 Tool 실행
  권한 거절과 다르다. world 준비 완료도 모든 출처가 정상이라는 판정이 아니다.
- 모델 응답 종료 이벤트가 오면 응답 활동 표시를 끝낸다. 개별 본문 조각이 끝나면 아직 열린
  Text·Thinking 조각 중 마지막으로 관측한 조각의 활동을 표시한다. 조각이 모두 닫혀도 전체 모델 응답이
  끝났다는 뜻은 아니다. Keeper 턴과 대기 중 도구는 계속 진행될 수 있다.
- 이어서 처리하기를 기다리는 요청은 진행줄을 그리지 않는다. 다음 실행이 시작되면 진행줄이 돌아온다.
- 같은 실행을 진행줄과 `기존 작업 처리 중`으로 중복 표시하지 않는다.
- 다른 Keeper의 실행과 `/interrupt <다른 이름>`은 입력 주변에 표시하지 않는다.
  Keepers 목록·Activity에서 관측하고 제어한다. 추적 중인 요청은 삭제하지 않는다.
- 전송 결과 미확인, 중단 실패, 관측 실패, 승인 질문은 기본 화면에서도 보인다.
  `Attention`은 기본 대화에서 상세를 접어도 남는다.
- Ask 답변 영수증은 원래 제출 요청에 한 번만 보존한다. 그 중복 방지 조건으로 목록 재조회
  완료 관측까지 막지 않는다. 재조회는 실제 Result와 현재 제출·workspace 소유권으로 별도
  관측하고, 실패가 이미 보존한 POST 영수증을 덮지 않는다. 원래 제출 시작 시각에 확인·POST·
  재조회 함수의 진입·반환·예외·취소 시각을 연결한다. 없는 종료는 unfinished로 남긴다.
  함수 대기는 auth·pool·해석·시작 로그 비용을 포함하며 순수 HTTP RTT가 아니다. worker 반환과
  UI admission도 별개이며, 관측은 mutation gate·초안·후속 읽기 권한을 바꾸지 않는다.
  실제 Result는 POST 반환 직후 원래 요청의 atomic 칸에 먼저 남긴다. 공용 큐 알림을 기다린 뒤
  재조회를 시작하지 않는다. 취소·workspace 전환은 이미 받은 결과를 지우지 않으며, 결과 없이
  닫힌 worker는 미적용이나 성공으로 추정하지 않는다. UI는 회차 시작 때 실제 대기 중이던
  큐 구간을 FIFO로 처리한 뒤 원래 요청의 준비된 결과들을 수집한다. 그 구간의 identity 철회가
  먼저 적용되며, 이후 새 트래픽이나 새 publication은 현재 구간·수집 집합을 연장하지 않는다.
  입력 처리 한도가 끝나면 같은 구간·집합을 다음 루프에서 이어간다. Ask 두 종류와 Runtime 폼,
  Keeper 설정·할당·생성의 준비된 원래 소유자를 모두 포함하며 단일 우선순위 검색을 반복하지 않는다.
  최종 POST·재조회 Result 쌍도 별도 원래 칸에 먼저 보존하고,
  제출 당시 workspace/read scope로 완료 메시지를 복원해 같은 operation 판정을 거친다.
  당시 읽기 권한이 없었으면 나중의 권한으로 채우지 않는다. 읽기 철회는 POST 영수증을
  지우지 않으며, 사실 회수만으로 초안·제출 gate를 끝내지 않는다. 세션 보존은 재시작 내구성이
  아니며 큐 포화 중 즉시 표시를 보장하지 않는다. 새 identity 메시지도 다음 FIFO 구간에 속하며,
  결과 적용 시 기존 요청·workspace/read 판정을 다시 거친다. 저장한 사실은 새 workspace의 읽기 권한이 아니다.
- Runtime 폼·Keeper 설정/Sandbox·Runtime 할당의 주기적 결과 회수는 최종 UI 반영을 기다리는
  원래 요청만 읽는다. 불변 이력 값 안에서 전체 이력과 그 조회 집합을 함께 갱신한다.
  atomic publication·빈 조회·초안 복구 해제·workspace/read 철회만으로 요청을 빼지 않는다.
  최종 상태를 정상 반영한 뒤 조회 집합에서 제외해도 미확인 결과·입력·CAS/revision·관측 시각은
  이력에 남는다. 미확인 Runtime 폼의 재시도 제한과 문서 재검증 조건은 전체 이력에서 판단한다.
  이력 보존과 결과 조회 자격은 별개이며 이 변경은 이력 상한이나 새 읽기 권한이 아니다.
  폼 안내가 해당하지 않는 화면과 선택된 폼 요청이 없는 조회는 이력을 순회하기 전에 끝낸다.
- Approvals 요약에서 선택한 질문 전체가 남은 viewport에 들어가지 않으면, 원래 안전한 렌더의
  완전한 행으로 미리보기를 남긴다. 공간이 있으면 전체 Ask를 읽고 답하는 `a` 안내를 함께
  둔다. 미리보기는 답변 모드 진입·기본 선택·제출이 아니며, 원문·선택지·초안은 기존 전체
  읽기에 그대로 남긴다. 숨긴 질문 수 안내도 실제 행 예산을 써야 하며, 한 행뿐이면 선택한
  질문을 먼저 보여 준다. 화면 문구·배치·행 순서·PTY 검사를 만들지 않고, 소스상 행 예산을
  실제 화면·키 반응·속도 검증으로 바꾸어 말하지 않는다.
- 요약 질문의 높이 판단·표시에는 같은 동기 draw 안에서 준비한 원래 버퍼를 한 번만
  사용한다. 질문·초안·입력창 값·폭·커서를 해당 호출의 값으로 캡처하고, 지연 준비 칸을
  worker나 다음 frame으로 넘기지 않는다. 숨김 개수는 전체 원래 질문 수로 유지한다.
  이유/이유 안내를 그릴 공간이 없으면 버퍼를 준비하지 않되 원문이 없다고 분류하지 않는다.
  준비 횟수 감소를 render CPU·paint·Loading 지연의 실측 개선으로 부르지 않는다.
- Ask 입력창은 요약과 전체 읽기 모두 원래 slot의 Ask ID와 질문 ID를 함께 확인한 질문에만
  표시한다. 질문 ID는 Ask마다 다시 쓰인다. 표시 불일치가 원래 slot의 저장 대상이나 초안을
  바꾸는 근거가 되어서는 안 된다. 정상 새로고침의 선택 재결속과 이 표시 검사를 구분한다.
- Ask 답변 후속 상태는 원래 질문에 저장된 Task로 연결한다. 답변 저장·wake·Tool 결과와
  실제 Task 단계를 구분하고, 읽기에 실패해 남긴 단계는 마지막 관측으로 표시한다.
  현재 Keeper Task로 바꿔 연결하거나 Task 관측만으로 전체 Goal 완료를 표시하지 않는다.
  wake/턴·Tool 결과·Task는 독립 source다. 하나의 조회 실패가 다른 관측을 숨기지 않는다.
  wake/턴의 조회 불가·관측한 빈 이력·부분 이력은 별도 타입으로 읽고, 같은 답변의 마지막
  관측을 보관하면 최신 확인 여부를 함께 표시한다. 새 조회는 이전 관측을 남겨 두고
  source별로 조회 중·수신·미확인을 표시한다. 부분 수신 뒤 연결 실패는 먼저 수신한
  source의 최신 확인을 취소하지 않으며 미도착 source만 미확인으로 남긴다.
  병렬 읽기나 Task 단계만으로 답변의 인과성을 주장하지 않는다.
  Tool 관측은 기존 recorded-call 결과 타입으로 성공·보류·실패·미정·형식 오류를
  전달한다. 실패·미정·형식 오류도 원래 물리 관측 건수에 남기고 다섯 합계와 최신
  결과의 bucket을 wire에서 검증한다. typed disposition을 wire outcome보다 먼저
  읽는 공통 판정을 재사용하며, 본문·Tool 이름으로 결과를 추정하지 않는다. 전체 분포와
  최신 결과를 함께 표시하고, retained 상태에도 결과를 보존한다. 이 결과를 효과 성공·
  유용한 작업·Task 완료나 실제 화면 확인으로 바꾸어 기록하지 않는다.
  후속 SSE는 시작 identity, 각 typed source 한 번, 같은 identity의 완료 순서를 검증한다.
  먼저 온 source만 관측하며 다른 source의 미도착을 조회 실패·빈 이력으로 채우지 않는다.
  EOF만으로 전체 읽기를 완료하지 않는다. 같은 답변의 source별 상태에 즉시 반영하고,
  새 답변·workspace/read authority 철회는 조회 worker를 취소한다. 늦은 source와 정리는
  후속 요청의 상태·취소 소유권을 바꾸지 않는다. 요청 시작·수신·상태 반영 시각은 같은
  요청 번호로 기록하되 paint나 실제 작업 진척 시각으로 부르지 않는다.
- 질문의 `o`는 기록된 원본 출처를 로컬에서 펼치고, `O`는 그 Turn_ref에 고정한
  inspector를 연다. 최근 목록 탐색과 고정한 원본은 별도 타입이다. 원본이 없으면
  현재 Keeper 턴으로 대체하지 않는다. 입력 중인 자유문자는 그대로 입력하고,
  inspector를 닫아도 질문 답변 초안을 유지한다.
- 원본 inspector는 턴 기록·직렬화 입력·응답 관측을 독립적으로 읽고 먼저 끝난 것을
  표시한다. 턴 기록 실패가 알려진 원본 입력 조회를 막지 않는다. `조회 중`과
  `조회 불가`를 나누고, 같은 generation의 늦은 pending이 완료된 관측을 지우지 않는다.
  generation·workspace·Keeper가 바뀐 응답은 기존 소유권 경계에서 버린다.
  과거 원본에 현재 next-request 예상이나 runtime catalogue를 섞지 않는다.
  고정한 원본 응답은 v2 turn-transcript의 보존 이력을 읽는다. Keeper·Turn_ref·버전과
  모든 행을 검증하고, 읽기 실패를 빈 응답으로 바꾸지 않는다. 요청 실패 기록은
  일반 Keeper 발화와 별도 타입으로 표시한다. 최근 목록의 응답 미관측은 여전히
  최신 페이지 범위이며 전체 이력의 부재로 확정하지 않는다.
  요청 탭은 응답 상태만 간단히 표시하고 `4:response`에서 보존한 본문 전체를 읽는다.
  응답 읽기는 입력·근거의 열린 항목·커서·스크롤·pane focus를 보존하고 Esc로 되돌린다.
  응답은 별도 스크롤과 실제 viewport를 쓰며 입력 실패가 응답 관측을 숨기지 않는다.
  전체 Markdown 변환은 응답 탭을 열 때만 수행한다. 같은 불변 본문의 변환은 Keeper·
  조회 대상·폭·terminal palette generation·table frame 설정이 같으면 재사용한다.
  응답 탭 진입·응답 스크롤은 추가 HTTP 요청을 시작하지 않는다. 과거 원본의 새로고침도
  현재 runtime catalogue를 읽지 않는다.
  조회 영수증의 시간은 클라이언트 대기·해석 시간이며 화면 표시나 모델 사용 증거가 아니다.
- 접힌 승인 기록이 있으면 진행줄의 `Ctrl-S:details`로 접근한다.
- 상태줄은 대화 대상의 health·mode·gate와 context를 표시한다. 상세 레이아웃에서는
  런타임·세부 사용량도 표시한다. roster 커서는 대화 대상을 바꾸지 않는다.
- 기본 footer는 전송·줄바꿈·중단/돌아가기·명령·도움말만 남긴다.
- 슬래시 메뉴와 녹음 안내는 관련 상태에서 footer를 대체한다.
- 메뉴가 실제로 표시될 때만 방향키·Tab·Enter·Esc를 가로챈다. 초안 보존과 전송 의미는 바꾸지 않는다.
- 시작·workspace 재확인은 Keeper 메타데이터와 Work·agent 관측을 별도 공유 I/O job으로 읽는다.
  UI 스레드에서 전체 디렉토리를 읽고 initial identity 확인 응답을 늦추지 않는다.
  두 source는 대기 슬롯·데이터 타입·캐시 잠금·실패 상태를 따로 소유한다. Work 대기·실패는
  Keeper 입력 가능 여부나 목록을 바꾸지 않는다. 채팅 자동 열기·Task handoff는 Keeper
  메타데이터를 기다리고, 반영 뒤 초안·중단 상태를 보존한 채 후속 처리를 다시 확인한다.
  로컬 결과는 source·workspace authority·base path·요청 소유권을 함께 확인하고 한 번만 반영한다.
  source별 숫자 요청 번호가 같아도 서로 대신 쓸 수 없다. suspension은 두 worker 취소와
  읽기 소유권 회수를 모두 수행한다. 같은 경로로 돌아와도 이전 결과가 새 요청을 끝내거나
  덮지 않는다. 실패는 미조회·정상 빈 목록과 구분한다. 로그는 source와 요청 번호를 함께
  연결하고, worker 관측 구간을 키 응답·화면 표시 시간이나 작업 완료와 구분한다.
- 생성·Keeper 제어 결과·채팅 종료·명시적 새로고침에서도 로컬 디렉토리를 UI가 직접
  다시 읽지 않는다. 생성 완료는 Keeper 메타데이터만, Work도 바뀔 수 있는 나머지 경로는
  두 source를 따로 갱신한다. cadence는 진행 중 읽기를 공유한다. 갱신 중 들어온 명시적
  요구는 후속 읽기 하나로 합치고, 현재 읽기를 취소·재시작하지 않는다. 현재 결과는 관측으로
  반영하되 새 요구를 소비하지 않는다. 성공·실패 모두 후속 읽기를 이어간다. 요청별 취소
  소유자는 workspace 회수·clear와 실제 worker 정리에 쓰며 늦은 정리가 후속 소유자를 지우지 않는다.
  같은 workspace 재조회 중에는 마지막 관측과 초안을 유지한다. 새 Keeper별로 생성 뒤 요청한
  source-demand revision을 보존하고 이를 포함한 읽기와 실제 이름 관측이 모두 있어야 입력을
  연다. 오래된 읽기의 부재는 생성 중 채팅을 닫지 않는다. 여러 생성 대기는 서로 덮지 않는다.
  이 revision은 요청 순서이며 시간·turn·token 한도가 아니다. 확인된 삭제는 기존 identity
  기반 선택 규칙으로 반영한다. metadata 캐시는 실제 파일 경로, archive 캐시는 경로·mtime·
  size에 묶어 다른 workspace의 같은 이름·stat 값에서 관측을 빌리지 않는다.
  Work 반영은 입력·Task handoff wake를 대신하지 않는다. 로그에서 poll/refresh를 구분한다.
  cache lock은 실패·취소 전에 해제하고 원래 예외를 재전달한다. 실제 worker 정리는 공통
  executor 소유이며, 취소 요청 로그를 worker 종료 증거로 바꾸지 않는다.
- Keeper 생성은 editor가 반환한 뒤 workspace 확인과 create-only POST를 소유 fiber에서
  수행한다. 확인 중·전송 중·종료 상태는 원래 요청에 묶고, 전송 전 중단·서버 거절·
  생성 확인·결과 미확인을 구분한다. POST 진입 뒤 취소·연결 실패는 결과 미확인이며
  자동 재전송하지 않는다. 종료 결과를 요청 전용 atomic 칸에 먼저 게시한 뒤 취소 가능한
  알림을 보낸다. 공용 큐가 가득 차도 기존 drain은 게시된 결과를 회수하며, 종료 중인
  worker가 취소를 막은 채 큐 공간을 기다리지 않는다. 원래 workspace가 회수돼도 영수증과 미해결 선언문은
  세션 상태에 남기되 새 workspace의 읽기·입력 권한으로 쓰지 않는다.
  성공은 자기 초안만 지운다. 여러 생성·편집의 초안과 초점은 별도 owner이며,
  후속 사용자 입력이나 대기 중 입력이 있으면 늦은 성공이 대화를 강제로 열지 않는다.
  현재 workspace의 확인된 생성만 metadata 갱신을 요청하고, 실제 입력은 기존
  Keeper별 freshness barrier와 이름 관측을 기다린다. 미해결 선언문은 다음 editor
  진입에서 복구할 수 있으며 재시작 복구를 증명하지 않는다. 로그는 선언문을 싣지
  않고 요청 시작·phase 반영을 기록한다. 이 시각은 화면 표시·네트워크 RTT가 아니다.
- Keeper 상세의 활동 요약과 Logs는 같은 `Masc_tui_fetched` 관측을 사용한다.
  입력 handler와 cadence는 파일을 읽지 않고 원래 workspace authority·base path·Keeper·
  물리 행 범위에 묶인 I/O 요청을 보낸다. 응답은 원래 read scope와 ticket도 일치해야
  반영한다. 같은 대상의 poll은 진행 중 읽기를 공유하고, 명시적 refresh는 후속 읽기
  하나로 모은다. 실패해도 요청한 후속 읽기는 이어간다. 새 대상은 이전 값을 빌리지 않는다.
  활동 요약이 없는 다른 detail tab은 metrics를 요청하지 않는다. Info의 명시적 새로고침도
  같은 source 요구를 사용한다. 화면을 떠나면 진행 중 읽기를 retire하고 마지막 관측만 보관한다.
  같은 대상의 재조회·실패는 마지막 snapshot을 남기고 읽는 중·마지막 관측·실패·부분 행
  진단을 구분한다. 미조회·조회 실패를 정상 빈 기록이나 활동 0으로 표시하지 않는다.
  workspace 확인이 끊기면 소유 읽기를 retire하고 마지막 관측만 보여준다. 재확인 뒤에는
  새 read scope에서 다시 읽는다. 늦은 worker 정리는 다음 요청의 취소 owner를 지우지 않는다.
  읽기는 canonical metrics 위치를 직접 열며 writer 디렉터리·설정·캐시를 준비하지 않는다.
  기존 물리 행 범위와 공통 executor 정책은 유지한다. 로그의 시작·반환·반영 시각은
  worker 순수 IO·키 응답·화면 표시 시간과 다르다. 화면 문구/행 순서 검사는 만들지 않는다.
- 선택된 Keeper의 live-context도 공유 I/O worker에서 읽는다. UI는 메타데이터 반영·행 이동·
  상세 열기에서 이 저장소 읽기를 기다리지 않는다. 소유권은 workspace read scope·base path·
  Keeper·trace와 요청 세대에 묶는다. 채팅에서는 roster 커서가 아니라 대화 대상이 소유한다.
  같은 소유자의 재조회 중에는 마지막 관측을 유지하고, 실패하면 그 관측과 실패를 함께 남긴다.
  선택·trace가 바뀌면 이전 읽기를 취소 요청하며, 실제 worker 정리는 공통 executor가 소유한다.
  새 대상·workspace에는 이전 값을 빌려주지 않는다. source 재확인 주기와 명시적 새로고침만
  같은 key를 다시 읽고, 매 frame에서 완료·실패를 재시도하지 않는다. 진단은 시작·worker 반환·
  UI 반영 관측을 나누며, 미완료 시작도 남긴다. 이 시간은 키 응답·화면 표시·모델 진행이 아니다.
- 응답 본문의 JSON 파싱과 큰 목록의 타입 변환은 공유 CPU worker에서 수행한다.
  worker에는 불변 입력과 순수 해석만 넘긴다. HTTP 요청·credential 교체·ETag 캐시
  갱신·workspace 확인·화면 데이터 반영은 기존 호출자가 소유한다. 늦게 끝난 해석이
  새 화면의 읽기 소유권을 빌리지 않으며, 비동기 해석 완료도 화면 표시나 작업 완료를
  뜻하지 않는다. runtime-event의 `decode_wait`는 풀 대기와 결과 전달을 포함한다.

## 검증

렌더러와 row budget은 같은 projection을 사용한다. 검색·스크롤·화면 너비·메모 캐시도
같은 origin mode와 실제 행을 사용해야 한다. 복사는 원본 응답에서 한다.

- 채팅의 현재 상태 행·접힌 행 수·상세 안내·예약 높이는 같은 동기 draw의 원래 상태
  projection을 공유한다. 명령 메뉴 높이·Activity의 펼치기 키·실제 상태 표시도 같은 값을
  쓴다. 원래 실행이 없거나 다른 Keeper의 실행이면 빈 frame을 그대로 전달한다.
  이 값은 state·worker·다음 frame에 보관하지 않고 다음 draw에서 현재 선택을 다시 읽는다.
  원래 준비·실패·승인·중단 진단을 유지하며 생성 호출 수 감소를 CPU·paint·Loading 지연의
  실측 개선으로 부르지 않는다. 호출 횟수·문구·행 순서를 검증하는 새 검사는 만들지 않는다.
- 같은 frame은 대기 입력의 batch 진단·Activity·관측된 중단 행도 높이 계산과 표시가 함께
  사용한다. batch는 실제 실행 ID로 인덱싱하고 첫 등장 순서·원래 가장 이른 입력·재확인 수를
  보존한다. 같은 시각의 대표 입력을 바꾸지 않으며 frame 밖 인덱스·행 캐시를 만들지 않는다.
- 원래 전송·로컬 대기·우선순위 영수증의 membership은 요청 ID·Keeper·본문 세 값을 모두
  쓰는 동일한 identity로 인덱싱한다. 본문을 정규화·복사·해시하거나 ID만으로 합치지 않는다.
  저장 이력의 소비 확인은 기존의 선택 Keeper·정식 persisted user row 조건을 유지한다.
  임시 control 영수증을 확정으로 올리지 않고 실패·진행·전체/부분 영수증의 판정 순서를
  유지한다. 집합은 membership만 제공하며 원래 요청의 순서·개수·전송 권한을 대신하지 않는다.

폭·기호·기본 모드를 바꾸면 기존 unit 기대값도 함께 갱신한다. 좁은 화면의 첫/마지막
본문, 외부 발신자 이름, 한글·이모지 줄바꿈, 전송 결과 미확인·중단 실패를 확인한다.

소스 projection 미리보기와 실제 TUI 실행 화면은 구분한다. 로컬 Dune 빌드와 CI 실행 시점은
constitution의 execution_protocol을 따른다.
