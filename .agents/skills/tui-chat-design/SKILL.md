---
name: tui-chat-design
description: "MASC TUI의 원본 비동기 요청·Task·검증 증거·이력 상세와 파일 경계 이어읽기, 소스별 표시 준비 단계·물리/논리 관측, 채팅·입력·로딩·진행 상태, 시작 설정·인증 준비·키 인계·음성 보정과 녹음 관측·늦은 터미널 응답, 비동기 조회·상세의 소스별 미조회·진행·재확인 대기·마지막 관측·설정 저장·긴 질문의 요약과 전체 읽기·Ask 답변과 재조회·후속 source 수신/미확인과 이전 증거를 바꿀 때 쓴다. Keeper·Work·로그·Board·Runtime·Overview·Tools·Connectors의 원본 요청·입력·revision·소유권, 준비 상세·현재 턴·이력·구성 조회·디렉터리 페이지의 workspace 검증과 캐시 영수증, 공유 조회와 부분 실패, 공용 완료·원래 Task 생성/취소 영수증의 세션 소유 보관과 알림 큐·입력 revision과 명시적 명령 복구·정확한 Task 생성 사실 조회·원래 요청 inspector, 조회 실패·중단·미시작, worker·caller·UI 반영·취소·등록 해제와 paint 증거를 구분한다."
---

# 대화를 먼저 읽는 채팅

정본은 `bin/masc_tui_message_layout.ml`, `bin/masc_tui_render_chat.ml`,
`bin/masc_tui_types.ml`이다. 코드와 다르면 이 문서도 함께 고친다.

## 주제별 파일

본문에는 화면 전체에 걸리는 규칙만 둔다. 아래 일을 바꿀 때는 그 파일을 먼저 연다.
Keeper 는 `keeper_skill` 을 같은 `identity` 에 `file = "references/<파일>"` 로 부른다.

| 바꾸는 일 | 파일 |
|---|---|
| 시작 입력·늦은 터미널 응답, workspace JSON 조회와 이력, Tools 구성 조회 | [references/startup-and-workspace-reads.md](references/startup-and-workspace-reads.md) |
| 원본 비동기 요청 상세·음성 보정과 입력 관측, Connector 조회와 페이지 | [references/async-request-detail.md](references/async-request-detail.md) |
| 복합 조회의 부분 수신 | [references/composite-partial-reads.md](references/composite-partial-reads.md) |
| 에디터 준비, Keeper 설정·Sandbox 저장, Runtime 할당·catalogue·폼·원문·snapshot·source 준비 | [references/keeper-and-runtime-settings.md](references/keeper-and-runtime-settings.md) |
| 입력 주변: 진행줄·준비 미리보기·준비 상세·응답 활동 | [references/input-progress-and-preparation.md](references/input-progress-and-preparation.md) |
| 입력 주변: Ask 답변·승인 요약·원본 inspector·상태줄·footer·메뉴 | [references/input-ask-and-approvals.md](references/input-ask-and-approvals.md) |
| 입력 주변: 시작·workspace 재확인, Keeper 생성, 상세 활동·Logs, live-context, 응답 JSON 파싱 worker | [references/input-shared-io.md](references/input-shared-io.md) |

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

입력창 주변의 진행·질문·조회 규칙은 세 파일로 나눠 둔다. 위 표의 `입력 주변:` 행을 본다.

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
