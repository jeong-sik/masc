# Board 파일 공유 + 악보/Tab 표시 설계 (TUI-first)

- 날짜: 2026-10-13
- 상태: 구현됨 (native stack #42781, 브랜치 `board-attachments/01`~`07`)
- 맥락: 운영자가 MIDI나 다른 파일을 board에 공유하고, 악보나 탭을 볼 수 있기를 원했다.
  운영자는 dashboard를 거의 쓰지 않으므로 **TUI가 먼저**다.

## 의도와 이유

Keeper와 운영자가 음악 작업물(MIDI, 악보, 기타 탭)과 임의 파일을 MASC 안에서 주고받고,
TUI에서 바로 확인할 수 있게 한다. Keeper는 텍스트만 다루므로, 바이너리 파일 없이
텍스트(alphaTex)만으로 악보를 공유하는 경로가 특히 중요하다. 기타 탭은 본래 텍스트
포맷이라 터미널과 궁합이 좋다.

## 목표

1. 운영자가 TUI에서 로컬 파일을 올려 board 글에 붙인다.
2. TUI가 글의 첨부를 보여 준다.
3. ` ```alphatex ` 코드 블록이 board와 chat 양쪽에서 탭 악보로 보인다.
   Keeper가 텍스트만으로 악보를 공유하는 경로다.

## 비목표

- TUI에서 오선보를 그리거나 소리를 내는 것.
- dashboard 악보 렌더러와 dashboard 업로드 화면.
- MIDI를 악보로 바꾸는 것.
- 댓글 첨부, `masc_keeper_msg`/broadcast 첨부.
- blob federation.

## 반목표 (이렇게 되면 실패)

- 업로드가 digest·크기 검증을 우회하거나 `.masc` 밖에 파일을 둔다.
- 모르는 첨부 kind를 조용히 무시한다 (constitution `strict_parse_no_default`).
- TUI 채팅 디자인 규칙(`.agents/skills/tui-chat-design`)을 깨는 표시를 추가한다.

## 제약

- constitution: 닫힌 합타입, 경로 하드코딩 금지, evidence 규칙. TUI 검사는
  화면 문구·배치가 아니라 보낸 요청·저장한 상태·결정만 본다.
- 백엔드와 TUI 모두 OCaml 5.5 + Eio.

## 설계

### 서버

1. 첨부 kind는 8개다: `image`, `video`, `youtube`, `external_link`, `file`, `audio`,
   `score`, `midi`. 클라이언트가 보내는 첨부 하나는 `{kind, url | sha256, name?}`이다
   (`lib/board_tool_adapter/board_tool_attachment.ml`). 글에는 url 그대로, 또는 저장소의
   `_blob` wrapper(`artifact`)로 저장된다.
2. `name`은 파일 이름이다. 비어 있지 않은 UTF-8이고, 한 줄이고, 경로 구분자가 없고,
   255바이트 이하다. 들어올 때 한 번 검사한다.
3. 업로드는 `POST /api/v1/artifacts`다. 요청 본문이 파일이고, `Tool_blob_store`에
   저장한 뒤 `201`과 `{sha256, bytes}`를 돌려준다. `CanAdmin` 권한이 필요하다.
4. 업로드 한도는 저장소가 내려 주는 한도와 같은 32 MiB
   (`Tool_blob_store.max_served_bytes`)다. 일반 요청 본문 한도(`MASC_MAX_BODY_BYTES`)와
   따로 읽는다.
5. 저장소는 파일마다 미디어 타입을 두지 않고, 업로드도 받지 않는다. 파일이 무엇인지는
   첨부의 kind가 말한다.

### TUI 쓰기

1. board 새 글 작성 화면에서 `Ctrl-A`로 경로를 입력해 파일을 붙인다. 붙인 파일은 글을
   보낼 때 순서대로 올리고, 받은 sha256과 이름, kind를 글의 `attachments`에 싣는다.
2. kind는 파일 이름의 확장자로 정한다.
3. 하나라도 올리지 못하면 글을 보내지 않는다. 쓰던 글과 붙인 파일은 남는다.
4. 파일은 붙일 때와 보낼 때 두 번 검사한다. 심볼릭 링크, 디렉터리, 빈 파일, 일반 파일이
   아닌 것, 한도를 넘는 파일은 거절한다. 보낼 때의 한도는 읽기 자체가 지킨다.
5. 댓글에는 첨부를 싣지 않는다.

### TUI 읽기

1. `board_post.bp_attachments`는 `meta.attachments`를 첨부 하나씩 읽은 결과다 (결정 5).
2. 읽기 화면은 본문 아래 `ATTACHMENTS`에 첨부마다 한 줄(kind, 이름, 크기)을 보여 준다.
3. dashboard는 kind 8개를 모두 읽는다. 새 kind 네 가지는 저장된 파일이면 내려받기
   카드로, url이면 링크 카드로 나온다.

### ` ```alphatex ` 코드 블록

1. `masc_tui_code_lexer`가 색을 입히고, 블록 머리에 "alphaTex 악보"라고 적는다.
2. `Masc_tui_alphatex_score`가 글자를 악보 값(마디, 박, 음)으로 읽고,
   `Masc_tui_alphatex`가 그 값을 탭으로 그린다. board와 chat이 함께 쓰는 markdown
   렌더러에서 부른다.
3. 읽는 범위는 지시어 `\title` `\tempo` `\ts` `\tuning`, 길이 `:1`~`:16`, 음, 화음, 쉼표,
   마디선, 반복 기호(`\ro`, `\rc N`, `\ae`)다. 여는 마디는 `|:`, 닫는 마디는 횟수와 함께
   `:|xN|`, ending 은 `|1,3|` 로 그린다(#42858, #42859). 범위 밖의 것이 있거나 마디 없는
   반복 기호가 있으면 그리지 않고 이유와 원문을 보여 준다.
4. 길이를 바꾸지 않는 주법 표기는 그리지 않고 그 음 뒤에 `*`를 붙인다.
5. 화면보다 넓으면 마디 경계에서 줄을 바꾼다.

## 결정

1. **첨부에 선택 필드 `name`을 둔다.** 없으면 sha256 앞부분으로 표시한다. 서버 타입과
   파서, 도구 설명(TOML), TUI와 dashboard의 읽기 코드를 함께 바꿨다.
2. **운영자가 파일을 올리는 화면은 TUI board 작성 화면이다.**
3. **업로드를 쓰는 쪽은 TUI 운영자(HTTP)다.** Keeper 사이의 파일 전달은
   `keeper_artifact_transfer`가 맡는다.
4. **alphatex 그리기는 board와 chat이 함께 쓰는 markdown 렌더러에 둔다.**
5. **첨부를 읽지 못한 것은 첨부 하나 단위로 드러낸다.** 읽지 못한 첨부는 "깨진 첨부"와
   이유로, 모르는 kind는 받은 단어 그대로 그 줄에만 표시한다. 글과 나머지 첨부는 그대로
   읽는다 (`bp_kind`의 `Post_kind_unknown` 선례, dashboard의 ok/failure 방식).

## 후속

- dashboard 악보 렌더러(alphaTab, MPL-2.0)와 dashboard 업로드 화면.
- MIDI 파일을 읽어 트랙, 길이, BPM을 보여 주기.
- TUI에서 첨부를 열거나 내려받는 키, 이미지 미리보기, 목록 화면의 첨부 개수.
- TUI/HTTP 밖의 클라이언트를 위한 MCP 업로드 도구.
- 그 밖의 항목은 이슈 #42782에 있다.
