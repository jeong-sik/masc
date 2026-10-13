# Board 파일 공유 + 악보/Tab 표시 설계 (TUI-first)

- 날짜: 2026-10-13
- 상태: 구현됨 (스택 board-attachments/01~07). 아래 "구현에서 달라진 점" 참조
- 맥락: 사용자가 "midi 파일이나 다른 파일을 board 또는 대화에 공유하고 싶고, 악보/Tab
  표시 기능이 있으면 좋겠다"고 요청. 사용자는 dashboard를 거의 쓰지 않으므로
  **TUI가 1차 표시·입력 표면**이다.

## 의도와 이유

Keeper와 운영자가 음악 작업물(MIDI, 악보, 기타 탭)과 임의 파일을 MASC 안에서 주고받고,
TUI에서 바로 확인할 수 있게 한다. Keeper는 텍스트만 다루므로, 바이너리 파일 없이
텍스트(alphaTex)만으로 악보를 공유하는 경로가 특히 중요하다. 기타 탭은 본래 텍스트
포맷이라 터미널과 궁합이 좋다.

## 현재 상태 (2026-10-13 실측)

서버:

- board post attachment 4종(`image | video | youtube | external_link`), 소스는 HTTPS URL
  또는 `.masc/tool_blobs` blob의 sha256. `meta_json.attachments`에 저장, digest 검증 +
  크기 상한 적용. (`config/tools/masc_board_post.toml`,
  `lib/board_tool_adapter/board_tool_attachment.mli`)
- artifact 읽기: HTTP `GET /api/v1/artifacts/<sha256>` (최대 32 MiB),
  `keeper_artifact_read`, dashboard `fetchToolBlobBytes`.
- 로컬 파일을 blob store에 넣는 **업로드 경로 없음** (sha256 첨부는 blob 선존재 전제).
- attachment wire 포맷이 정확히 `{kind, url|sha256}`로 닫혀 있어 파일명을 실을 곳이 없다.
- keeper→keeper 파일 전달은 `keeper_artifact_transfer`로 이미 가능.
- 악보/탭/MIDI 관련 코드 없음 (grep 0건).

TUI (`bin/masc_tui_*`):

- 완전한 Board 화면이 있다: 목록/읽기/작성, 전부 서버 HTTP API 경유
  (`bin/masc_tui_render_board.ml`, `bin/masc_tui_http.ml`,
  `bin/masc_tui_board_requests.ml`).
- 그러나 `board_post` 타입(`bin/masc_tui_types.ml:1755`)에 attachments 필드가 없어
  디코드(`bin/masc_tui_loader.ml:670`)에서 meta가 버려진다.
- 마크다운 펜스 디스패치 지점 `emit_fence`(`bin/masc_tui_markdown.ml:1261`)에 mermaid
  커스텀 렌더러 선례가 있고, board와 chat이 같은 렌더러를 지난다.
- 외부 리소스 표시 관례가 chat에 갖춰져 있다: 링크 프리뷰 카드
  (`bin/masc_tui_link_preview.ml`), 미디어 텍스트 라벨(`bin/masc_tui_chat_media.ml`의
  `"File · name · src"` 형태), 이미지 오버레이(`bin/masc_tui_image_preview.ml`),
  artifact fetch(`GET /api/v1/artifacts/<sha256>`를 이미 사용).
- board compose는 텍스트만 가능. keeper 채팅에는 `:attach <path>` 이미지 첨부가 있으나
  board와 무관.

실측 증거:

- 이미지 attachment 포스트 MCP 생성 + `meta.attachments` 저장 확인
  (post `p-0b185d1e337710cc8c2751dc37f03353`, 24h TTL 테스트).
- alphaTab 스파이크: alphaTex 텍스트 → 오선보+탭+재생, MusicXML 파일 바이트 →
  `api.load()` 렌더링, 둘 다 브라우저 스크린샷으로 확인
  (`.tmp/score-spike/shot.png`, `shot2.png`). dashboard용 후속 단계의 유효성 증거.

## 목표

1. 운영자가 TUI에서 로컬 파일을 올려 board post에 첨부할 수 있다.
2. TUI가 attachment를 표시한다: 파일 카드, 이미지, 링크, 악보(텍스트 표현), MIDI 정보.
3. ` ```alphatex ` 코드 블록이 board와 chat 양쪽에서 구분된 렌더링으로 표시된다
   (keeper의 텍스트 전용 악보 공유 경로).

## 비목표

- TUI에서의 오선보 그래픽 렌더링 (터미널 불가)과 오디오 재생.
- dashboard 렌더러(alphaTab)와 dashboard 업로드 UI — 후속 단계로 미룬다.
  (브라우저 렌더링 유효성은 스파이크로 이미 증명했다.)
- MIDI → 오선보 변환.
- 댓글 attachment, `masc_keeper_msg`/broadcast 첨부.
- blob federation.

## 반목표 (이렇게 되면 실패)

- 업로드가 digest/크기 검증을 우회하거나 `.masc` 밖에 파일을 둔다.
- unknown attachment kind를 조용히 무시한다 (constitution `strict_parse_no_default`).
  TUI가 모르는 kind는 "미지원 kind"로 명시 표시한다.
- TUI 채팅 디자인 규칙(`.agents/skills/tui-chat-design`)을 깨는 표시를 추가한다.

## 제약

- constitution: 닫힌 합타입, 경로 하드코딩 금지, evidence 규칙. TUI 검사는
  화면 문구/배치가 아니라 보낸 요청·저장한 상태·결정만 본다.
- 백엔드와 TUI 모두 OCaml 5.5 + Eio.
- alphaTab(MPL-2.0)은 후속 dashboard 단계의 선택지로만 유지.

## 설계

### Phase 1 — 서버 공통 기반 (표면 무관)

1. 업로드: HTTP `POST /api/v1/artifacts` (raw body) → `Tool_blob_store`
   기록 → sha256 반환. 쓰기 API는 이미 존재한다: `Tool_blob_store.put_durable`
   (fsync 보장) / `put_file_durable`(스풀에서 스트리밍 해시+복사, 대용량에 적합)을
   라우트에 연결하는 작업이다 (`lib/tool_blob_store/tool_blob_store.mli:108,127`).
   저장소는 해시마다 미디어 타입을 두지 않는다. 파일이 무엇인지는 첨부의 kind가 말하고,
   kind는 `name`의 확장자에서 정한다.
2. attachment wire 포맷에 선택 필드 `name` 추가 (아래 결정 1).
3. attachment kind 확장: `file`, `audio`, `score`, `midi`. `board_tool_attachment` 파싱과
   kind 합타입 확장. (dashboard가 모르는 kind를 어떻게 보여줄지는 dashboard 단계에서.)

### Phase 2 — TUI 쓰기 (운영자 공유 경로)

1. board compose에 첨부 스테이징 추가: keeper 채팅 `:attach <path>`의 UX 관례를 따라
   compose 중 파일 지정 → `POST /api/v1/artifacts` 업로드 → sha256+name+kind로 첨부.
   kind는 확장자/mime에서 결정하되 명시 override를 허용.
2. `post_board_new` HTTP 페이로드에 attachments 인자 추가.

### Phase 3 — TUI 읽기

1. `board_post`에 `bp_attachments` 추가 + 디코더 확장. 실패 의미론은 **엔트리 단위
   명시**로 한다 (아래 결정 5): malformed 첨부 1개가 post 읽기 전체를 실패시키지 않고,
   모르는 kind는 "미지원 kind" 항목으로 운반한다 (`bp_kind`의 `Post_kind_unknown`
   선례, dashboard의 `BoardAttachmentDecode` ok/failure 패턴).
2. `board_read_pane` 본문 뒤에 "ATTACHMENTS" 섹션을 append
   ("POINTS AT" 섹션의 확립된 패턴).
3. kind별 표시:
   - image → 기존 image preview/artifact fetch 관례.
   - youtube/external_link → link preview badge 관례.
   - file/audio/midi → `chat_media.ml`의 `"File · name · 크기"` 라벨 관례.
     midi는 1차에서 라벨만 (SMF 파싱 표시는 후속).
   - score → alphaTex 소스이면 펜스 소스 표시, 바이너리(gp 등)이면 라벨 + 파일 정보.
4. 목록 뷰에는 첨부 개수 정도만 표시 (상세는 읽기 화면).

### Phase 4 — ` ```alphatex ` 펜스

1. `emit_fence`에 alphatex arm 추가. 1차는 `masc_tui_code_lexer`에 lexer 등록 수준의
   구문 강조 + "alphaTex 악보" 표시行. board와 chat 양쪽에 자동 적용.
2. alphaTex → ASCII 탭 변환 렌더러를 부분집합으로 포함한다 (아래 미결 사항의 결정).

### 후속 (이 설계의 범위 밖, 순서만 기록)

- dashboard alphaTab 렌더러(스파이크로 유효성 검증 완료)와 dashboard 업로드 UI.
- MIDI SMF 파싱 기반 트랙/길이/BPM 표시.
- TUI에서 첨부를 열거나 내려받는 키.
- MCP 업로드 tool 변형 (TUI/HTTP 외 클라이언트용).

## Builder check 결정 사항 (2026-10-13, 진행자 판단)

1. **wire 포맷에 `name` 선택 필드를 추가한다.** 파일 카드 표기와 포맷 판별에 필요.
   과거 포맷 호환은 constitution `legacy_residue`가 무게를 두지 않는다고 정한다.
   `name`은 option; 없으면 file 카드는 sha256 단축 표기, score는 매직바이트 판별로
   fallback. 서버 타입/파서, TOML 스키마, TUI/dashboard 디코더를 같은 변경에서 고친다.
2. ~~운영자 업로드 UI를 dashboard에~~ → **TUI board compose에 둔다.** (TUI-first 개정)
3. **업로드 소비자는 TUI 운영자(HTTP)로 1차 한정.** TUI는 이미 서버 HTTP를 쓰므로 같은
   엔드포인트로 커버된다. keeper는 기존 `keeper_artifact_transfer`가 커버.
   MCP tool 변형은 후속.
4. **` ```alphatex ` 렌더링은 TUI 공유 마크다운 렌더러(`emit_fence`)에 넣어 board와
   chat 양쪽에서 켠다.** (dashboard 공유 컴포넌트는 후속 단계에서 같은 방침.)
5. **첨부 디코드 실패는 엔트리 단위 명시로 한다.** (2차 검토에서 발견) `bp_closed`의
   "실패 시 None degrade" 패턴은 malformed 항목이 post 전체 읽기를 실패시키므로 이
   문서의 반목표와 충돌한다. 대신: 형태가 깨진 엔트리는 "깨진 첨부"로, 모르는 kind는
   "미지원 kind"로 각각 그 항목만 명시 표시하고 post는 정상적으로 연다
   (`bp_kind`의 `Post_kind_unknown` 운반 선례, dashboard의 ok/failure 엔트리 패턴).

## 미결 사항

없음. 마지막 미결이던 "alphaTex → ASCII 탭 변환 v1 포함 여부"는 2026-10-13
사용자 진행 승인 시 **(a) 부분집합 포함**으로 진행자가 확정했다
(근거: 원래 요청이 Tab 표시이고 1차 표면이 TUI이므로, 포함하지 않으면 v1 어디에도
탭 그림이 없음. 부분집합 범위: duration/노트/화음/마디/반복, 테크닉 기호는 생략하고
생략 사실을 표기).

## 구현에서 달라진 점

- TUI 읽기 화면은 모든 kind를 한 줄 라벨(kind, 이름, 크기)로만 보여 준다. 이미지 미리보기와
  링크 프리뷰, 목록 뷰의 첨부 개수는 넣지 않았다. TUI에서 첨부를 여는 키도 없다.
- dashboard는 새 kind 4종을 읽는다. 저장된 파일은 기존 다운로드 카드로, URL은 링크 카드로
  나온다. 재생기나 악보 렌더러는 없다.
- compose에서 kind는 확장자로만 정하고, 직접 고르는 방법은 없다.
- 업로드는 미디어 타입을 받지 않는다. 저장소가 바이트와 해시만 두기 때문에 받아도 남길
  곳이 없었다. 브라우저 재생처럼 실제 타입이 필요한 기능은 저장소가 타입을 갖게 된 뒤의 일이다.
- 업로드 한도는 저장소 한도(32 MiB) 하나다. 일반 요청 본문 한도(`MASC_MAX_BODY_BYTES`)와
  따로 읽는다.
- 탭은 화면 폭을 넘으면 마디 경계에서 줄을 나눈다. 반복 기호(`\ro`, `\rc`)는 부분집합에 없어서
  그런 악보는 이유와 함께 소스로 보인다.

## 빌더에게 맡기는 사항

- 업로드 엔드포인트의 요청/응답 스키마, kind별 크기 상한 (`max_served_bytes` 범위 내).
  권한은 현행 GET `/api/v1/artifacts/<sha256>`의 `CanAdmin`
  (`server_routes_http_routes_artifacts.ml`) 관례를 따르는지 명시할 것.
- compose 첨부 스테이징의 구체적 키/명령 UX (tui-chat-design 스킬 준수).
- `.xml`이 MusicXML인지 판별하는 방식.
- 목록 뷰 첨부 개수 표기 형식.

## 직접 검증한 확장 지점 (2026-10-13)

- 서버 kind 합타입: `lib/board_tool_adapter/board_tool_attachment.mli:6`
  (`Image|Video|Youtube|External_link`). `parse_args`의 여분 필드 거부와 digest 검증
  `resolve`도 같은 파일. post handler가 `meta.attachments`의 유일한 writer.
- artifact GET 라우트: `lib/server/server_routes_http_routes_artifacts.ml`
  (32 MiB 상한, CanAdmin, systhread 격리).
- TUI `board_post` 타입: `bin/masc_tui_types.ml:1755` (attachments 필드 없음 확인).
- TUI 펜스 디스패치: `bin/masc_tui_markdown.ml:1261` `emit_fence`, mermaid arm 선례.
