# 입력 주변: Ask 답변·승인 요약·원본 inspector·상태줄·footer·메뉴

`tui-chat-design` Skill 의 일부다. 정본 파일과 공통 규칙은 그 Skill 의 SKILL.md 를 따른다.

## 입력 주변 — Ask 답변·승인 요약·원본 inspector·상태줄·footer·메뉴

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
  화면도 같은 source의 pending·received·unconfirmed를 모두 구분한다. 미확인 source에
  남은 값은 이전 관측으로 표시하고, 값이 없으면 최신 source 미확인으로 남긴다. 이전
  Task 미관측·미연결·조회 불가와 wake 조회 불가도 최신 수신처럼 표시하지 않는다.
  source 수신과 값의 freshness는 별개다. 수신된 불가 결과가 남긴 과거 양성 증거의
  current flag를 다시 켜지 않고, 전송 실패 뒤 실제 수신된 형제 source를 미확인으로
  낮추지도 않는다. 미확인은 물리 조회 미시작·실패·취소의 원인이나 실제 종료 증거가 아니다.
  최신 source가 받쳐 주지 않는 과거 양성 시각을 하나라도 빌렸으면 합친 관측은 이전 증거를
  포함한다고 표시한다. 새 source 수신·빈 전체 이력·SSE 완료만으로 보존한 시각을 최신 확인으로
  바꾸지 않는다. 모든 보존 시각을 새 source가 다시 확인하면 현재 관측으로 돌아갈 수 있다.
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
  부분 frame과 종단 결과는 같은 세션 소유 수신함의 원래 등록으로 발행한다. 부분 수신은
  등록을 유지하고 종단만 닫는다. 공용 bounded 알림 큐의 빈자리를 기다리거나 부분을
  합치거나 버리지 않는다. 원래 발행 순서·source 수신 시각을 보존하고, UI에서는 읽기
  관측으로 분류해 captured read authority와 원래 질문·답변·ticket을 함께 검사한다.
  부분 관측 API는 caller가 미리 만든 원래 `cancelled` 종단 메시지도 같은 등록에 보관한다.
  실제 Eio 취소는 원래 backtrace와 함께 전파하고, 이미 받은 부분 다음에 취소 사실을
  게시한다. UI가 원래 ticket·질문/답변·workspace/read 권한으로 적용할 때만 읽기 티켓을
  settle한다. 다른 질문·새 조회·닫힌 결과 세션을 다시 열지 않는다. 취소된 switch의
  dispatch 전 거절과 worker 진입 전 철회도 caller 메타데이터를 정리한다. 일반 retained
  operation·session API는 취소를 종단 결과로 만들지 않는 기존 의미를 유지한다.
  미도착 source는 미확인, 받은 source는 원래 관측으로 남기며 화면은 읽기 불완전의 원인도
  함께 표시한다. 종단 게시나 UI settle을 물리 worker 정리·등록 해제 증거로 부르지 않는다.
  실제 worker 진입 전 철회·미시작과 worker 취소·등록 해제는 구분하며, 이미 발행한
  부분 사실은 세션이 닫힐 때까지 보관한다. 늦은 part나 종단이 끝난 등록·세션을 다시
  열지 못한다. 새 cap·timer·retry·도구 제한을 만들지 않고 대기 제거를 속도 실측으로
  환산하지 않는다. wire frame은 서버의 typed formatter 하나에서 만든다.
- 후속 읽기의 종단 원인은 `followup_result`의 실패·취소·미시작·철회로 구분한다.
  실제 strict frame 완료를 확인한 성공만 complete이고, 현재 읽기에 종단이 없으면 unfinished다.
  최초 종단은 불변이며 나중의 화면 철회가 성공·실패·취소 원인을 바꾸지 않는다. 새 읽기는
  이전 source 사실을 보관하되 새 미완료 수명을 가진다. 미시작은 switch 부재처럼 진입하지
  않았다는 근거가 있는 경우만 쓰며 dispatch 예외나 취소만으로 worker 진입을 추정하지 않는다.
  structured trace는 원래 submission 시작 시각·질문·요청 번호에 결속해 started,
  worker_entered, producer_returned/cancelled, cancel_requested/registration_released와
  UI finished를 분리한다. source_processed의 ui_admitted와 source_applied를 구분하고
  observed_ns는 실제 기록 시각, admitted_ns는 UI에서 처리한 경우에만 남긴다.
  completion은 typed 원인만 직렬화하며 오류 본문·답변은 로그에 넣지 않는다. 같은 요청의
  producer와 UI 행을 별개 시도로 세지 않고, 종단 없는 물리/논리 구간을 unfinished로 보존한다.
  clock/trace/source serialization·오류 formatter 비용도 실측 분모에 남긴다. Task 완료·paint나
  실제 비교 실측으로 바꾸어 주장하지 않는다.
- 후속 관측의 출처는 원래 조회의 private capsule로 캡처한다. TUI state 수명마다 기존
  UUID 생산자로 instance ID를 만들고 linked Build_version의 reported version을 보관한다.
  확인된 workspace 두 경로와 서버가 admission 때 보고한 version/binary commit은 같은
  불변 origin에 담고 JSON은 한 번 준비한다. 부분·종단·취소 메시지와 worker/job/UI 로그는
  그 capsule을 그대로 쓰며 늦은 정리를 현재 workspace나 새 서버 identity로 다시 표시하지 않는다.
  admission_started_ns는 private read admission/출처 준비 전 시각이며 이후 observed/admitted
  시각과 구분한다. pending 공유로 새 ticket을 만들지 않은 수요도 clock 비용을 가진다.
  instance ID는 MCP credential이나 권한 token이 아니다. client version은 소스 SHA가 아니며,
  server_identity_at_admission은 뒤의 응답을 처리한 binary 증명이 아니다. 실제 비교는 이
  scope와 별도 실행/설치 근거를 함께 보존하고 다른 프로세스의 monotonic clock을 빼지 않는다.
- Approvals의 `T`는 마지막으로 답변한 원래 Ask의 canonical answer identity와 Task 링크로
  공용 원본 Task inspector를 연다. 생성 요청과 Ask 출처는 닫힌 타입으로 구분한다.
  Ask에는 생성 영수증·생성 조회가 없으며 현재 Keeper나 전역 Task 목록을 빌리지 않는다.
  `o`·`h/H`·`v`·`r`은 기존 exact Task·저장 이력·verification 제출의 읽기 경로를 쓰고,
  `b`는 원래 Ask·답변 시각·stimulus·Task·workspace 연결만 보여 준다. 입력·선택·답변
  재전송·Task 생성·handoff를 수행하지 않는다. 같은 Ask 재방문은 마지막 관측을 보관하며,
  각 조회는 새 ticket과 현재 viewer·workspace/read authority를 확인한다. 새 답변 소유자와
  출처 변경은 이전 조회를 철회하고 늦은 응답을 거부한다. typed answer editor가 키를 소유할
  때는 `T`를 가로채지 않는다. 이 연결은 Goal 완료나 화면·시간 개선의 실측이 아니다.
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
