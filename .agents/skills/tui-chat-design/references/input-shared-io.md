# 입력 주변: 시작·workspace 재확인, Keeper 생성, 상세 활동·Logs, live-context, 응답 JSON 파싱 worker

`tui-chat-design` Skill 의 일부다. 정본 파일과 공통 규칙은 그 Skill 의 SKILL.md 를 따른다.

## 입력 주변 — 시작·workspace 재확인, Keeper 생성, 상세 활동·Logs, live-context, 응답 JSON 파싱 worker

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
- 로컬 source의 pending은 원래 caller 결과를 보존한다. 반환 관측만 UI 반영 대기로
  표시하고, 예외·중단·미시작을 각각 구분한다. 입력줄과 Keeper·Work source 안내가 이
  같은 타입을 사용한다. 반환을 payload 성공으로, 중단을 물리 worker 종료로, 미시작을
  UI 오류 메시지 접수로 추정하지 않는다. 표시는 기존 source의 in-flight 요청에만 붙고
  실패 본문·원래 workspace/request admission·후속 조회·입력 권한을 대신하지 않는다.
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
- 공용 workspace launcher의 종료 결과와 실제 미시작 오류는 세션 소유 저장소에 먼저
  게시한다. 공용 알림 큐의 빈칸을 기다려 UI의 미시작 호출이나 완료 worker를 붙잡지 않는다.
  원래 workspace/read epoch·source·ticket 검증과 admitted operation의 영수증/후속 조회
  분리는 UI가 그대로 수행한다. 결과 게시와 pending 등록 해제는 한 불변 atomic 상태에서
  이루어지고, worker 정리는 자기 미게시 등록만 제거한다. 함수 진입 전 철회도 그 등록을
  정리하며 취소를 성공·실패로 합성하지 않는다. 세션 종료는 미수신 결과를 해제하고 늦은
  게시를 거절하지만 worker의 물리 종료나 이미 회수한 결과의 취소를 뜻하지 않는다.
  기존 drain의 유한 shared FIFO prefix 뒤, 기존 요청 소유 결과들 다음에 공용 종료 결과를
  게시 순서로 받는다. 이후 알림은 그 prefix를 늘리지 않으며 중단된 round는 원래 나머지를
  유지한다. 공용 종료 결과가 shared notification에서 owned batch로 옮겨간 만큼 소스 간
  상대 순서는 달라진다. 모든 producer·callback·읽기·정리가 nonblocking인 것은 아니며
  source 저장·로그·paint나 Task 완료를 이 보관과 혼동하지 않는다. 등록/제거의 pending
  목록 탐색·CAS 경합·결과 보관/분리/역순 변환 비용도 Before/After에 포함한다. 새 한도·
  timer·캐시·retry loop를 두거나 큐 대기 제거를 실제 입력/Loading 지연 감소로 환산하지 않는다.
- 이미 수락된 Task 취소의 원래 영수증은 workspace 철회로 취소하지 않는 기존 switch에
  남긴다. 같은 세션 결과 저장소로 전달하되 원래 Task·expected workspace를 담은 unscoped
  메시지를 유지한다. 공용 조회용 workspace job에 넣거나 현 workspace 권한을 감싸면
  수락된 결과를 잃거나 새 workspace에 후속 조회를 보내게 된다. 기존 요청 전 두 검증·MCP
  세션·reason/handoff·서버 전이 판정은 유지하고, 성공 영수증 뒤 재조회는 기존 foreign
  판정으로 보류/철회한다. 자동 재전송·새 root switch로 인계하지 않는다. runtime/switch
  취소와 통신 실패 뒤 결과 미확인 문제는 결과 보관과 별개이며 성공으로 올리지 않는다.
  no-switch·동기 dispatch 실패도 같은 보관 경로를 쓰지만 종료된 세션에 새 메시지는 만들지
  않는다. 큐 공간 대기 제거를 취소 성공·입력 응답·화면 반영의 실측 개선으로 부르지 않는다.
- `/task` 생성은 원래 intent·Task ID·Keeper·본문과 입력 revision에 묶인 세션 소유
  요청으로 보관한다. workspace 철회는 수락된 생성 결과를 취소하지 않고, 원래 확인된
  workspace/두 사전 검증·서버 expected workspace와 fresh Keeper handoff 판정은 유지한다.
  전송 callback 진입 전 실패만 Not_sent이며 tool 오류는 Server_error, 진입 뒤 통신·해석·
  예외·취소는 Unconfirmed다. callback 진입은 물리 전송 증거가 아니다. 취소 사실을 보관한
  뒤 원래 취소를 전파하고 자동 재생성하지 않는다. 완료는 원래 wrapper의 UI 적용을 한 번만
  허용하며 shared prefix 뒤 기존 owned 그룹의 다음 유한 그룹으로 받는다. 성공 intent는
  제거하고 실패/미확인 원문은 세션에 남긴다. 매 frame은 active 요청만 읽고 원문 이력은
  명시적 복구에서 찾는다. UI 전송 대기·반영·Task 생성·handoff·유용한 작업 완료를 혼동하지 않는다.
  성공 뒤 자동 채팅 열기도 원래 editor authority·대상·revision이 맞을 때만 한다. 새 입력이
  있으면 화면은 그대로 두고 fresh Keeper handoff는 자기 queue로 계속 전달한다.
  자동 복원은 Not_sent와 원래 authority·Keeper 대상·불투명 입력 revision이 모두 맞을 때만
  한다. content edit·clear·paste와 첨부/참조 list 변경은 같은 revision을 바꾸며 cursor 이동은 그대로 둔다. 빈 문자열로
  돌아왔다는 이유로 같은 입력이라 추정하지 않는다. `/task-recover`는 같은 Keeper와 확인된
  원래 workspace의 가장 최근 실패 intent를 입력에 복원할 뿐 전송하지 않는다. 미확인은
  Tasks 확인 뒤 재제출하도록 안내하며 새 입력·외부 workspace에 늦은 실패를 덮지 않는다.
  기존 HTTP 인증·precondition 알림과 물리 정리는 여전히 막힐 수 있다. intent/결과 보관,
  입력 편집별 token 할당·active 순회·명시적 이력 탐색 비용을 실측에서 빼지 않는다. 새 cap·
  timer·중복 생성 fallback·문구/행 순서 테스트를 만들지 않고 source 진척을 Loading/paint
  개선 실측이나 재시작 복구로 바꾸지 않는다.
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
- Keeper의 Instructions·Sandbox status·GitHub·Identity 상세는 현재 tab·Keeper의
  원래 `detail_reads` 요청이 있을 때만 조회 진행을 표시한다. 값이 없거나 다른 Keeper의
  stamp라는 이유로 loading을 만들지 않는다. 요청도 값도 오류도 없으면 미조회로 남기고
  기존 server authority 확인이 필요하면 그 상태를 구분한다. 같은 Keeper의 실제 값이
  남아 있으면 재조회 진행·실패와 마지막 관측을 함께 보여준다. 원문 오류는 single-line으로
  정리한다. 이 projection은 실제 조회·초기화·응답 admission·로그인/저장 권한을 바꾸지 않고,
  다른 Keeper의 값이나 container-log pending을 status 요청으로 빌리지 않는다.
- Info 실행·Secrets는 fleet의 Keeper lanes snapshot과 그 원래 in-flight를 사용한다.
  값 없는 미조회를 loading으로 만들지 않고, 재조회·실패 중 남은 관측은 현재 실행이나
  새 검증으로 바꾸지 않는다. Channels는 `Connector_read`의 status/names 단계·쓰기 뒤
  재확인 대기·시작 실패 안내를 그대로 사용한다. 대기 중인 recheck나 미시작을 읽는 중으로
  부르거나 별도 detail 요청의 시계를 빌리지 않는다. Automation은 현재 Keeper의 원래
  schedule 요청으로 진행·재조회와 실제 stamped snapshot·오류를 구분하고 기존 page-capped
  부재 판정을 유지한다. Item account도 자기 pending이 없으면 미조회다. 표시 projection은
  source 상태·요청·취소·응답 적용·binding/Item/schedule 효과 권한을 쓰거나 바꾸지 않는다.
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
