# 에디터 준비, Keeper 설정·Sandbox 저장, Runtime 할당·catalogue·폼·원문·snapshot·source 준비

`tui-chat-design` Skill 의 일부다. 정본 파일과 공통 규칙은 그 Skill 의 SKILL.md 를 따른다.

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
