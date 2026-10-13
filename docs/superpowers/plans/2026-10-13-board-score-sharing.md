# Board 파일 공유 + 악보/Tab 표시 (TUI-first) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 운영자가 TUI에서 로컬 파일을 올려 board post에 첨부하고, TUI가 첨부(파일/오디오/악보/MIDI)와 ` ```alphatex ` 펜스를 표시하게 한다.

**Architecture:** 서버는 attachment wire 포맷(kind 확장 + 선택적 `name`)과 업로드 라우트(`POST /api/v1/artifacts` → `Tool_blob_store.put_durable`)만 추가한다. TUI는 디코드(`bp_attachments`, 엔트리 단위 명시 실패) → 읽기 표시(ATTACHMENTS 섹션) → 쓰기(compose 첨부 스테이징) → ` ```alphatex ` 펜스(구문 강조 → ASCII 탭 렌더) 순으로 쌓는다.

**Tech Stack:** OCaml 5.5, Eio, Yojson, Alcotest. TUI는 `bin/masc_tui_*`, 서버는 `lib/`.

**Spec:** `docs/superpowers/specs/2026-10-13-board-score-sharing-design.md`

## Global Constraints

- constitution `docs/constitution.xml`: 닫힌 합타입, strict parse(unknown → 조용한 기본값 금지), 경로 하드코딩 금지(`base_path` 파생), 문자열 비교로 로직 분기 금지.
- TUI 검사는 화면 문구·배치·행 순서가 아니라 **보낸 요청·저장한 상태·결정(순수 함수 출력)**만 핀한다.
- 함수 단위 테스트는 파서/레이아웃 같은 복잡한 경우(Task 7)에만 허용.
- Stacked PR: Task N의 브랜치는 Task N-1을 base로 삼고, Task 1만 main을 base로 삼는다 (`gh stack`). 각 task의 commit이 그 층의 PR 내용이다.
- 로컬 전체 빌드 반복·CI watch 금지. 검증은 해당 패키지의 targeted `dune build`와 새 테스트 suite 실행까지.
- 채팅 UI 문구·기호는 `.agents/skills/tui-chat-design` 규칙을 따른다.

## Review Focus

1. 20 MiB 요청 body 상한(`Request.max_body_bytes`)이 32 MiB artifact 상한보다 먼저 걸려 대형 업로드가 413이 되는 경로 — 사용자는 한도 이유를 읽을 수 있어야 한다. (Task 2 테스트)
2. 새 kind를 모르는 구 TUI가 그 kind의 첨부를 만나는 경우 — post는 열리고 첨부만 "미지원 kind"로 표시돼야 한다. (Task 3 테스트)
3. keeper가 export한 파일(mime이 `application/octet-stream` 고정)의 첨부 — kind 판별이 `name`/확장자로 떨어져야 한다. (Task 5 테스트)
4. 닫히지 않은 ` ```alphatex ` 펜스 — 렌더 실패/미종결 시 소스라도 보여야 한다 (mermaid arm 선례). (Task 7 테스트)
5. 같은 파일 재업로드 — 같은 sha256, idempotent, 중복 저장 없음. (Task 2 테스트)

---

### Task 1: 서버 attachment kind 확장 + `name` 필드

**Files:**
- Modify: `lib/board_tool_adapter/board_tool_attachment.ml` / `.mli`
- Modify: `config/tools/masc_board_post.toml`, `config/tools/masc_board_post_update.toml`
- Modify: `dashboard/src/api/board.ts` (attachment 디코더가 선택적 `name` 키를 허용하도록 — 현재 `keys.length === 2` 엄격 검사가 `name` 있는 엔트리를 failure card로 보냄. dashboard 렌더러 자체는 후속이지만 디코더 관용은 이 변경과 같은 층에서)
- Test: `test/stanzas/test_board_attachment_kinds.inc` (신규), `test/dune`에 include 1줄

**Interfaces:**
- Consumes: 없음 (스택 최하단).
- Produces: `kind = Image | Video | Youtube | External_link | File | Audio | Score | Midi`;
  `unresolved`와 `t`의 각 variant에 `name : string option`; wire 포맷
  `{"kind": <str>, "url"|"artifact"|"sha256": ..., "name"?: <str>}`.

- [ ] **Step 1: 실패 테스트 작성** — `parse_args`가 `{"kind":"score","sha256":"...","name":"a.gp"}`를 받아들이고, `{"kind":"score"}`에 `name` 없음을 받아들이며, `{"kind":"hologram",...}`를 `Invalid_kind`로 거부하고, `"name": 42`를 거부하는 Alcotest 케이스. 기존 attachment 테스트 파일이 있으면 그 suite에 추가, 없으면 위 .inc 신설.
- [ ] **Step 2: 실행해 실패 확인** — 새 suite 실행(등록은 `test/dune` 관례 주석 :2408-2412 참조). Expected: 컴파일 실패 또는 Invalid_kind.
- [ ] **Step 3: 구현** — `kind` variant 4개 추가 + `kind_to_string`/`kind_of_string` 쌍 갱신(unknown 문자열은 `Invalid_kind`, 절대 기본값으로 눌러 담지 않음). entry 파싱에 선택적 `name`(string일 때만) 추가; `resolve` 결과와 `to_json`에 `name`을 보존. TOML 스키마 2곳의 kind enum과 설명에 새 kind와 `name`을 반영.
- [ ] **Step 4: 테스트 통과 확인.**
- [ ] **Step 5: Commit** — `git commit -m "feat(board): extend attachment kinds with file/audio/score/midi and optional name"`

### Task 2: 업로드 라우트 `POST /api/v1/artifacts`

**Files:**
- Modify: `lib/server/server_routes_http_routes_artifacts.ml` (핸들러 + `add_routes` :85, 모듈 헤더 주석)
- Test: `test/stanzas/test_artifacts_upload.inc` (신규), `test/dune` include

**Interfaces:**
- Consumes: `Tool_blob_store.put_durable : t -> bytes:string -> mime:string -> Tool_output.artifact_ref`; `Http.Router.post`; `with_token_permission_auth ~permission:artifact_read_permission`(`Masc_domain.CanAdmin`); `Http.Request.read_body_async`(초과 시 자동 413).
- Produces: `POST /api/v1/artifacts` — raw binary body, `Content-Type` 헤더가 mime. 성공 201 `{"sha256","bytes","mime"}`. Task 5의 TUI 업로드 함수가 이 계약을 소비.

- [ ] **Step 1: 실패 테스트 작성** — in-process raw HTTP 패턴(`test/test_artifacts_endpoint.ml`, `test/test_board_rest_routes.ml:181-258` 참조)으로: (a) 토큰 없음/Worker 롤 → 401/403, (b) 유효 업로드 → 201 + sha256이 `Tool_blob_store.fetch`로 같은 바이트를 돌려줌, (c) 같은 바이트 재업로드 → 같은 sha256, (d) `max_served_bytes` 초과 → 413과 한도 문구, (e) mime이 비어 있으면 `application/octet-stream`.
- [ ] **Step 2: 실행해 실패 확인** — Expected: 404 (라우트 없음).
- [ ] **Step 3: 구현** — `read_body_async`로 body를 받고, `Content-Type` 헤더(없으면 `application/octet-stream`)를 mime으로 `put_durable` 호출. body 길이가 `Tool_blob_store.max_served_bytes`를 넘으면 기존 `too_large_response` 관례로 413. `Sys_error` → 500, `Eio.Cancel.Cancelled`는 재raise(activity 라우트 패턴). `add_routes`에 `|> Http.Router.post "/api/v1/artifacts" upload_handler` 추가. 헤더 주석 갱신. H2 게이트웨이에는 추가하지 않는다 — H2에는 artifact JSON GET 선례도 없으므로 H1-only가 일관(이 결정을 PR 설명에 기록).
- [ ] **Step 4: 테스트 통과 확인.**
- [ ] **Step 5: Commit** — `git commit -m "feat(server): add POST /api/v1/artifacts upload route"`

### Task 3: TUI 디코드 — `bp_attachments` (엔트리 단위 명시 실패)

**Files:**
- Modify: `bin/masc_tui_types.ml` (:1755 `board_post` 부근)
- Modify: `bin/masc_tui_loader.ml` (`decode_board_post` :670 부근)
- Test: 기존 TUI 디코더 테스트 suite 탐색(`test/`에서 `decode_board_post` grep) 후 확장, 없으면 `test/stanzas/test_tui_board_attachments.inc` 신설

**Interfaces:**
- Consumes: Task 1의 wire 포맷.
- Produces:
  ```ocaml
  type board_attachment_kind = Ak_image | Ak_video | Ak_youtube | Ak_external_link
    | Ak_file | Ak_audio | Ak_score | Ak_midi | Ak_unknown of string
  type board_attachment_source = As_url of string | As_sha256 of string
  type board_attachment = { ba_kind: board_attachment_kind; ba_source: board_attachment_source;
    ba_name: string option; ba_malformed: string option }  (* Some reason = 깨진 엔트리 *)
  ```
  `board_post.bp_attachments : board_attachment list` (meta 없으면 `[]`).

- [ ] **Step 1: 실패 테스트 작성** — (a) `meta.attachments`가 있으면 디코드됨, (b) unknown kind 문자열 → `Ak_unknown`으로 운반되고 post 디코드는 성공, (c) 형태가 깨진 엔트리(필드 누락 등)는 `ba_malformed = Some ...`로 운반되고 나머지 엔트리와 post는 정상, (d) meta 없음 → `[]`.
- [ ] **Step 2: 실행해 실패 확인** — Expected: `bp_attachments` 필드 없음 컴파일 에러.
- [ ] **Step 3: 구현** — 디코더는 엔트리마다 독립 result로 읽는다. post 전체를 실패시키는 경로(`bp_closed`의 malformed-fails-all 패턴)를 여기에 쓰지 않는다 — spec 결정 5.
- [ ] **Step 4: 테스트 통과 확인.**
- [ ] **Step 5: Commit** — `git commit -m "feat(tui): decode board attachments with per-entry explicit failure"`

### Task 4: TUI 읽기 — ATTACHMENTS 섹션

**Files:**
- Create: `bin/masc_tui_board_attachments.ml` — 순수 매퍼 `summarize : board_attachment -> attachment_summary`
- Modify: `bin/masc_tui_render_board.ml` (`board_read_pane` 본문 조립부, "POINTS AT" 섹션 append 패턴 위치)
- Test: Task 3와 같은 suite 확장

**Interfaces:**
- Consumes: Task 3의 `board_attachment`.
- Produces:
  ```ocaml
  type attachment_summary = { as_label: string; as_action: attachment_action }
  and attachment_action = Open_url of string | Fetch_artifact of string | No_action
  ```
  (`as_label`는 `chat_media.ml`의 `"File · name · src"` 관례를 따른 한 줄 요약. kind 아이콘/명칭 결정은 여기서만 일어난다.)

- [ ] **Step 1: 실패 테스트 작성** — 매퍼 고정: file은 `"File · <name|sha256 단축> · <bytes>"` 수준 라벨 + `Fetch_artifact`, youtube/external_link는 `Open_url`, `Ak_unknown k`는 "미지원 kind: k" 명시 라벨 + `No_action`, `ba_malformed`는 "깨진 첨부" 라벨 + `No_action`.
- [ ] **Step 2: 실행해 실패 확인.**
- [ ] **Step 3: 구현** — 매퍼 작성 후 `board_read_pane`에서 `bp_attachments <> []`이면 본문 뒤에 ATTACHMENTS 섹션을 append. image의 inline preview는 기존 `Masc_tui_image_preview`/artifact fetch 관례 재사용(비용이 크면 라벨로 두고 후속으로 미루되, 그 결정을 코드 주석이 아니라 PR 설명에 기록). 레이아웃·행 순서는 테스트하지 않는다.
- [ ] **Step 4: 테스트 통과 확인.**
- [ ] **Step 5: Commit** — `git commit -m "feat(tui): render ATTACHMENTS section in board read pane"`

### Task 5: TUI 쓰기 — compose 첨부 + 업로드

**Files:**
- Modify: `bin/masc_tui_http.ml` — `upload_artifact`(raw binary POST, 저수준 헬퍼 확인), `post_board_new`에 `?attachments` (:2357-2378)
- Modify: `bin/masc_tui_board_requests.ml` (`start_board_post` :27-51)
- Modify: `bin/masc_tui.ml` (`handle_board_compose_key` :14437 부근), `bin/masc_tui_types.ml` (state에 `board_compose_attachments`)
- Test: 같은 suite 확장

**Interfaces:**
- Consumes: Task 2의 업로드 계약, Task 1의 wire 포맷.
- Produces:
  ```ocaml
  val upload_artifact : host:string -> port:int -> bytes:string -> mime:string
    -> (Tool_output.artifact_ref, string) result  (* 실제 반환 타입은 기존 http 헬퍼 관례에 맞춤 *)
  val kind_mime_of_path : string -> (string * string) option
  (* 확장자 테이블: gp/gp3-5/gpx/musicxml/mxl/cap/capx/atex → score, mid/midi → midi,
     png/jpg/… → image, mp3/wav/ogg/… → audio, 그 외 알 수 없으면 None → file+octet-stream *)
  ```

- [ ] **Step 1: 실패 테스트 작성** — (a) `post_board_new ~attachments`가 payload에 `attachments` 배열을 싣고 미지정/빈 리스트는 필드 생략, (b) `kind_mime_of_path "x.gp5" = Some ("score", ...)`, `"x.mid" → midi`, 알 수 없는 확장자 → `None`(호출부가 file로), 대문자 확장자 처리 결정 포함.
- [ ] **Step 2: 실행해 실패 확인.**
- [ ] **Step 3: 구현** — compose 모드에 첨부 스테이징(키 바인딩은 tui-chat-design 스킬 검토 후 결정; armed 상태와 충돌하지 않게). 전송 시 staged 파일을 순차 `upload_artifact` → sha256 수집 → `post_board_new ~attachments`. 업로드 실패 시 post를 보내지 않고 draft를 보존한다(기존 identity 불일치 시 draft 보존 관례). kind 판별이 `name` 확장자에 기대는 것은 keeper octet-stream 파일을 커버하기 위함이다.
- [ ] **Step 4: 테스트 통과 확인 + 실측** — 로컬 서버를 띄워 작은 파일 1개를 TUI compose로 첨부·전송하고, `masc_board_post_get`으로 `meta.attachments` 저장을 확인한다 (evidence 규칙).
- [ ] **Step 5: Commit** — `git commit -m "feat(tui): attach local files to board posts from compose"`

### Task 6: ` ```alphatex ` 펜스 인식 + 구문 강조

**Files:**
- Modify: `bin/masc_tui_code_lexer.ml` (언어 디스패치 :1089 부근)
- Modify: `bin/masc_tui_markdown.ml` (`emit_fence` :1261 arm)
- Test: 같은 suite 확장(lexer 분류 결정만)

**Interfaces:**
- Consumes: 없음.
- Produces: `lexer_of_language`가 `"alphatex"`를 인식; fence 헤더 라벨 `"alphaTex 악보"`.

- [ ] **Step 1: 실패 테스트 작성** — alphatex 토큰 분류: `\title` 등 지시어, `:4`/`:8` duration, `3.6` 노트, `(0.4 2.4).2` 화음, 주석이 서로 다른 span으로 분류됨.
- [ ] **Step 2: 실행해 실패 확인** — Expected: 미등록 언어 단일 span degrade.
- [ ] **Step 3: 구현** — lexer 등록(간이 토크나이저) + `emit_fence`에 alphatex arm 추가(1차: 헤더 + 구문 강조 소스 행; Task 7이 이 arm을 확장).
- [ ] **Step 4: 테스트 통과 확인.**
- [ ] **Step 5: Commit** — `git commit -m "feat(tui): recognize alphatex fences with syntax highlighting"`

### Task 7: ASCII 탭 렌더러 (부분집합)

**Files:**
- Create: `bin/masc_tui_alphatex.ml` — 순수 파서 + 레이아웃
- Modify: `bin/masc_tui_markdown.ml` — alphatex arm을 렌더러 호출로 확장
- Test: 같은 suite에 함수 테스트(파서/레이아웃은 "복잡한 경우"에 해당)

**Interfaces:**
- Consumes: Task 6의 fence arm.
- Produces:
  ```ocaml
  type tab_failure = { tf_reason: string }
  val render_tab : string -> (string list, tab_failure) result
  ```
  부분집합: `\title/\tempo/\ts/\tuning`, duration `:1|:2|:4|:8|:16`, 노트 `fret.string(.dur)`, 화음 `(…).dur`, 쉼표 `r.dur`, 마디 `|`. 테크닉 기호(슬라이드·해머링 등)는 만나면 해당 위치에 생략 표기를 남기고 나머지를 렌더한다.

- [ ] **Step 1: 실패 테스트 작성** — 스파이크 riff 입력(`docs/superpowers/specs/2026-10-13-board-score-sharing-design.md`의 alphaTex)이 정확히 아래 줄들을 산출:
  ```
  e|----------------|------------|----------------|3---------------|
  B|----------------|------------|----------------|3---------------|
  G|----------------|------------|----------------|0---------------|
  D|----------------|------------|--------2-------|0---------------|
  A|----------------|----0---3---|5---3-----------|2---------------|
  E|0---3---5---3---|5-3---------|----------------|3---------------|
  ```
  추가 케이스: 닫히지 않은 입력 → 소스 fallback 대상이 되는 `Error`, 두 자리 프렛(12.1) 열 정렬, 쉼표는 빈 칸.
- [ ] **Step 2: 실행해 실패 확인.**
- [ ] **Step 3: 구현** — 토크나이저 → 마디별 슬롯 배치(8분음표 슬롯 × 2문자) → 6줄 출력. 튜닝 지시어가 있으면 줄 이름에 반영. `.tmp/score-spike/ascii_tab.py`의 배치 로직을 참고하되 OCaml 닫힌 타입으로 다시 쓴다.
- [ ] **Step 4: 테스트 통과 확인 + 실측** — `emit_fence` 연결 후, alphatex 펜스가 달린 board post 1개를 만들어 TUI board read에서 탭이 보이는 것을 확인하고 터미널 캡처를 PR 증거로 붙인다.
- [ ] **Step 5: Commit** — `git commit -m "feat(tui): render alphatex fences as ASCII tablature"`

---

## Self-Review 기록

- Spec coverage: Phase 1→Task 1-2, Phase 2→Task 5, Phase 3→Task 3-4, Phase 4→Task 6-7. 비목표(dashboard, MIDI 파싱 표시, keeper_msg 첨부)는 계획에 없음 — 의도적.
- Type consistency: Task 3의 `board_attachment`를 Task 4-5가 소비, Task 2의 업로드 계약을 Task 5가 소비, Task 6의 arm을 Task 7이 확장 — 이름 일치 확인.
- Review Focus 5개 모두 대응 테스트를 해당 Task에 배치.
- 비율: spec ~200줄, plan ~180줄 — 코드 전사 없음.
