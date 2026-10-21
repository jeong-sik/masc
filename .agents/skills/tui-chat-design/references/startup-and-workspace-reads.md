# 시작 입력·늦은 터미널 응답, workspace JSON 조회와 이력, Tools 구성 조회

`tui-chat-design` Skill 의 일부다. 정본 파일과 공통 규칙은 그 Skill 의 SKILL.md 를 따른다.

## 시작 입력과 터미널 응답

- workspace 접근의 첫 bearer 준비와 workspace 생성 뒤 재확인은 세션 소유 child에서 기존
  installer를 실행한다. 인증 파일·역할·mint lock 정책은 바꾸지 않는다. 입력과 상태 반영은
  실제 installer의 관측을 기다리지 않고 진행하며, HTTP worker와 bearer header 작성자는
  이미 시작된 준비의 promise를 기다린다. 첫 HTTP는 UI drain이나 terminal probe 완료를
  새 선행조건으로 삼지 않는다. 요청·worker 관측·UI 반영은 따로 기록하고, 결과는 공용
  mailbox 공간 없이 원래 owner에 남긴다. 실패·실행 불가·중단을 성공이나 bearer 권한으로
  바꾸지 않는다. 진단은 기존 routine lazy 정책을 쓴다. 초기 runtime 설정 읽기와 직접 stat,
  기존 probe·보호된 mint I/O의 정리는 남아 있으므로 전체 시작·종료 시간 단축을 주장하지 않는다.
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
