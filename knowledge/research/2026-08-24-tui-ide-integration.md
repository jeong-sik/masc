# MASC TUI 에 IDE 기능을 넣는 문제 — 사전 조사

작성 2026-08-24 · 측정 기준 커밋 `89dd2799fc` (main)

## 0. 요약

세 줄로 먼저 말하면 이렇다.

1. **서버 쪽은 이미 대부분 만들어져 있다.** `lib/ide` 2,351줄 + `lib/server` 의 LSP 프록시·IDE HTTP 3,027줄, 합쳐서 약 5,400줄이 돌고 있고 HTTP 라우트도 9개 열려 있다. 지금 이걸 쓰는 건 웹 대시보드뿐이고, **TUI 는 `/api/v1/ide/*` 를 한 번도 부르지 않는다.**
2. **하지만 그 데이터로는 diff 를 그릴 수 없다.** 라이브 store 480건을 세어 보니 전부 `line_start:1`, `turn:0` 이다. "이 키퍼가 이 파일을 건드렸다"까지만 사실이고 줄 번호는 장식이다.
3. **진짜 diff 를 그릴 데이터는 다른 곳에 있다.** `~/.masc/tool_calls/` 의 Edit 기록이 `old_string`/`new_string` 을 통째로 갖고 있고, 키퍼마다 `~/.masc/playground/<keeper>/repos/<repo>/` 에 진짜 git 체크아웃이 있다. 둘 다 **HTTP 로는 안 열려 있다.**

즉 막힌 곳은 "IDE 기능을 새로 만드는 것"이 아니라 **이미 있는 사실을 TUI 까지 실어 나르는 길이 없는 것**이다.

---

## 1. "IDE 기능" 을 쪼개면

스크린샷(Claude Code 가 diff 를 그리는 화면)에서 실제로 눈에 보이는 건 다음 다섯 가지다. 난이도가 크게 다르므로 한 덩어리로 다루면 안 된다.

| # | 원하는 것 | 지금 상태 | 진짜 걸림돌 |
|---|---|---|---|
| A | 키퍼가 고친 코드를 diff 로 본다 | 없음 | 데이터가 HTTP 로 안 나옴 (§3.1) |
| B | 색이 입혀진 코드 | 부분적으로 있음 | 렉서 3개뿐 (§2.3) |
| C | 파일을 열어 편집 | `$EDITOR` 왕복만 있음 | 키보드 입력 표현력 (§4.2) |
| D | 터미널을 TUI 안에 박기 | 없음 | VT 파서를 새로 써야 함 (§5.3) |
| E | vim 과 붙기 | 없음 | **제일 쉽다** (§5.1) |

체감 난이도 순서가 직관과 반대다. 제일 어려워 보이는 vim 연동이 제일 싸고, 제일 당연해 보이는 diff 표시가 배관 공사를 요구한다.

---

## 2. 이미 있는 것

### 2.1 서버의 IDE 계층 — 만들어졌고, TUI 만 안 쓴다

```
lib/ide/                      2,351줄
  ide_bridge.ml                 845   tool/turn 이벤트, 커서 수집
  ide_annotations.ml            400   줄 단위 주석 CRUD (append-only jsonl)
  ide_annotation_types.ml       284   타입이 붙은 코드 주소 (RFC-0378)
  ide_region_tracker.ml         212   키퍼가 건드린 줄 범위
  ide_ingest_queue.ml           102

lib/server/ (IDE·LSP 부분)    3,027줄
  server_ide_lsp_proxy.ml     1,450   LSP 프록시
  server_ide_http.ml          1,029   HTTP 라우트
  lsp_process_manager.ml        235   언어 서버 프로세스 관리
  lsp_message_router.ml         213
  lsp_overlay_provider.ml       (별도) codelens/hover/진단/코드액션/폴딩
```

열려 있는 라우트 (`lib/server/server_ide_http.ml`):

```
GET  /api/v1/ide/observations/snapshot
GET  /api/v1/ide/annotations      POST  /api/v1/ide/annotations
DELETE /api/v1/ide/annotations/{id}
GET  /api/v1/ide/regions
GET  /api/v1/ide/events
GET  /api/v1/ide/presence
GET  /api/v1/ide/cursors          POST  /api/v1/ide/cursors
GET  /api/v1/ide/memory
```

`lsp_overlay_provider.mli` 를 보면 LSP 응답에 MASC 주석을 끼워 넣는 함수가 이미 다 있다 — `codelenses`, `diagnostics`, `enrich_hover`, `completion_items`, `code_actions`, `folding_ranges`.

**소비자는 웹 대시보드뿐이다** (`dashboard/src/api/ide.ts`, `dashboard/src/components/ide/`). TUI 가 부르는 엔드포인트를 전부 뽑아 보면:

```
/api/v1/board                          /api/v1/keepers/composite
/api/v1/dashboard/briefing             /api/v1/keepers/chat/stream
/api/v1/dashboard/planning             /api/v1/keepers/tool-approvals
/api/v1/dashboard/tools                /api/v1/operator/confirm
/api/v1/gate/connectors                /api/v1/repositories
...
```

`/api/v1/ide/` 로 시작하는 건 **한 개도 없다.**

### 2.2 붙어 있는 배선

- **키퍼별 진짜 git 체크아웃**: `~/.masc/playground/<keeper>/repos/<repo>/`. 확인해 보니 `rondo` 는 `feat/task-484-keeper-tool-surface` 브랜치에 더러운 파일 2개를 들고 있다. `git diff` 가 바로 나온다.
- **`$EDITOR` 왕복**: `bin/masc_tui_editor.ml`. raw 모드를 풀고 자식 프로세스를 띄운 뒤 되돌린다 (`~restore` / `~reenter`). vim 연동의 씨앗이 이미 여기 있다.
- **Ctrl-Z 서스펜드**: `bin/masc_tui.ml:3041`. 복귀할 때 전체 다시 그리기까지 붙어 있다.
- **대체 화면 + 동기화 출력**: `masc_tui_frame_presenter.ml` 이 `?1049h` (대체 화면), `?2026h` (동기화 출력), 이전 프레임과 비교해 바뀐 줄만 다시 그리기를 한다. 깜빡임 없는 전체 화면 앱의 기본은 다 갖췄다.
- **Overview 의 2단 배치**: `masc_tui_render.ml:480` 근처에서 `panel_width` / `right_panel_width` 로 좌우를 나눠 그린다. 화면 쪼개기가 불가능한 구조는 아니다.

### 2.3 이미 있는 문법 색칠

`bin/masc_tui_markdown.ml` (1,048줄) 안에 손으로 쓴 렉서 프레임워크가 있다. 코드 펜스의 언어 태그를 보고 렉서를 고른다:

```ocaml
let lexer_of_language (tag : string) =
  match String.lowercase_ascii (String.trim tag) with
  | "ocaml" | "ml" | "mli" -> Some ocaml_lexer
  | "bash" | "sh" | "shell" | "zsh" -> Some bash_lexer
  | "json" -> Some json_lexer
  | _ -> None
```

**세 개뿐이다.** 태그가 없거나 모르는 언어면 색을 안 칠하고 그냥 코드 색 하나로 둔다 — 추측해서 칠하지 않는 건 옳은 선택이다. 다만 키즈노트 쪽 TypeScript, 대시보드 쪽 TS/CSS 는 전부 여기 안 걸린다.

---

## 3. 없는 것, 그리고 고장난 것

### 3.1 region 데이터는 diff 로 쓸 수 없다 (측정)

라이브 store `~/me/.masc-ide/by-url/github.com_jeong-sik_masc/regions.jsonl`, 480줄:

```
전체                     480건
line_start ≠ 1            0건
turn ≠ 0                  0건
tool_name 분포            edit_file 431 / write_file 49 / apply_patch 0
```

샘플:

```json
{"file_path":"dashboard/src/components/fusion/fusion-surface.ts",
 "line_start":1,"line_end":1400,"keeper_id":"taskmaster",
 "source":{"type":"tool_call","tool_name":"edit_file","turn":0}}
```

`line_end:1400` 은 파일 전체 길이다. `ide_region_tracker.mli` 에 `parse_hunk_header` 가 있고 `@@ -1,5 +2,7 @@` 를 읽게 되어 있지만, **그 경로를 타는 `apply_patch` 호출이 0건**이라 한 번도 안 돌았다. 실제로 쓰는 `edit_file` / `write_file` 은 파일 전체 범위로 떨어진다.

`turn:0` 이 전부인 것도 같이 봐야 한다. 턴 번호가 안 채워지고 있다. 이건 별도 이슈감이다.

→ **결론: region 은 "누가 이 파일을 만졌나" 표시로는 쓸 수 있고, diff 로는 못 쓴다.**

### 3.1a 그런데 region 수집 자체가 멈춰 있다 (추가 측정)

위 결론도 취소해야 한다. 오늘(2026-08-24) 것을 세어 봤다.

```
오늘 파일 쓰기 tool call (Edit/Write)          176건
그중 repos/masc 안으로 들어간 것               138건
가장 최근 repos/masc 쓰기                      18:26 (kidsnote 키퍼)

github.com_jeong-sik_masc/regions.jsonl 마지막 줄   2026-08-22 12:57
github.com_jeong-sik_masc-mcp/regions.jsonl 마지막   2026-08-23 11:34
오늘 기록된 region                                    0건
```

같은 저장소에 같은 모양의 쓰기가 138번 들어갔는데 region 은 한 줄도 안 늘었다. **한가한 게 아니라 끊긴 것이다.**

playground 루트에 떨어진 26건(예: `verify-468.sh`)은 저장소 밖이라 주소가 안 붙는 게 정상이다 (RFC-0378 이 `_orphan` 을 없앴다). 하지만 `repos/masc/...` 138건은 주소가 붙어야 한다.

→ **`/api/v1/ide/regions` 위에 뭘 지으면 이틀 된 목록을 보게 된다.** 이슈로 남겼다: [#30077](https://github.com/jeong-sik/masc/issues/30077)

### 3.2 tool_events 도 diff 재구성이 안 된다

`~/me/.masc-ide/by-url/.../tool_events.jsonl` 한 줄의 모양:

```json
{"type":"tool","tool_name":"Grep","keeper_id":"taskmaster","turn_id":"task-335",
 "outcome":"ok","latency_ms":127,
 "summary":"{\"ok\":true,\"op\":\"rg\",...",   ← 잘린 출력
 "file_path":"dashboard/src","timestamp_ms":...}
```

`summary` 는 **출력**을 자른 것이고 **입력**이 없다. 여기서 diff 를 만들 수는 없다.

### 3.3 진짜 데이터는 `tool_calls` 에 있다 — 그리고 HTTP 로 안 열려 있다

`~/me/.masc/tool_calls/2026-08/11.jsonl` 의 Edit 기록:

```
tool: Edit
input keys: ['file_path', 'old_string', 'new_string']
```

Write 기록은 `content` 를 통째로 들고 있다. 게다가 한 줄에 이만큼이 같이 붙어 있다:

```
keeper, turn (2790), keeper_turn_id, task_id, goal_ids,
execution_id, tool_use_id, trace_id, session_id,
action_radius {target_path, sandbox_target, observed_paths},
route_evidence {descriptor_id, capability_id, canonical_name},
model, runtime_profile, lane, duration_ms, success
```

`keeper_tool_call_log.mli` 가 "persists a single tool call record with **full I/O**" 라고 쓴 그대로다. 큰 payload 는 내용 주소 blob 으로 빠진다 (`lib/tool_blob_store/`).

**서버 라우트를 전부 뽑아 봐도 이걸 내보내는 건 없다.** `/api/v1/dashboard/gate/tool-events`, `/api/v1/tool-metrics` 는 집계이고 I/O 가 아니다.

→ **A(diff 보기)의 실제 작업은 "diff 렌더러"가 아니라 "읽기 라우트 하나"다.**

---

## 4. TUI 구조가 막고 있는 것 네 가지

여기서부터가 진짜 설계 문제다. 순서대로 심각하다.

### 4.1 프레임이 문자열 목록이다 (제일 큰 것)

```ocaml
type frame = {
  surface_key : string;
  terminal_rows : int;
  terminal_cols : int;
  cursor : cursor;
  lines : string list;      (* ← ANSI 가 이미 박힌 완성된 줄 *)
}
```

채팅 기록도 마찬가지다:

```ocaml
type msg_entry = {
  me_role : msg_role;       (* Message_tool 이 있긴 하다 *)
  me_text : string;         (* ← 내용은 그냥 문자열 *)
  ...
}
```

셀 격자(cell grid)도 컴포지터도 없다. 줄을 문자열로 이어 붙여 만든다.

이게 왜 문제냐면 — diff 한 블록을 그리려면 줄마다 **왼쪽 홈통(줄번호 + `+`/`-`), 배경색, 그 위에 얹은 문법 색**, 세 겹이 겹친다. 여기에 접기/펼치기, 가로 스크롤, 검색어 강조가 더 붙는다. 문자열을 잘라 붙이는 방식으로 이걸 하면 ANSI 리셋이 서로를 잡아먹는다. `masc_tui_ansi.ml` 주석에 이미 같은 사고가 기록돼 있다:

> 배지를 닫는 리셋이 줄 전체를 감싼 스타일도 같이 닫아서, 화면마다 다른 길이만큼 굵어졌다

**이건 diff 를 붙이면 반드시 다시 터진다.** 겹치는 스타일이 두 겹에서 세 겹이 되기 때문이다.

### 4.2 조합키를 읽지 못한다

`bin/masc_tui.ml:142` 의 `read_key` 는 CSI 를 읽되 파라미터가 붙은 건 전부 버린다:

```ocaml
| Some ("", 'A') -> Some "up"
| Some ("5", '~') -> Some "pageup"
...
| Some (_, _) -> Some "unknown-esc"     (* ← 여기로 다 떨어진다 *)
```

`Shift+Up` 은 `ESC [ 1;2 A` 다. 파라미터가 `"1;2"` 라서 위 마지막 줄로 간다. **Ctrl+화살표, Alt+글자, Shift+글자 조합이 전부 `unknown-esc` 다.**

쓸 수 있는 키가 단일 글자 + 화살표 + 몇 개 named key 뿐인데, 화면이 이미 14개다 (`Overview / Acting / Keepers / Lanes / Board / Approvals / Planning / Schedules / Verification / Harness / Repositories / Connectors / Tools / System_logs`). 여기에 IDE 조작(파일 열기, 검색, 정의로 이동, hunk 넘기기, 접기)을 얹을 자리가 없다.

터미널은 Ghostty 이고 **Ghostty 는 Kitty 키보드 프로토콜을 지원한다.** `CSI > flags u` 로 켜면 조합키가 제대로 구분돼서 들어온다. 즉 이건 터미널 한계가 아니라 파서 한계다.

### 4.3 마우스는 휠만 읽는다

SGR 마우스 리포트를 디코드하긴 한다 — 그런데 휠만 화살표 키로 바꾼다 (`Masc.Tui_decode.sgr_wheel_key`). 클릭 좌표를 쓰는 곳이 없다.

그래서 파일 트리 클릭, 커서 놓기, 경계 끌어서 화면 나누기, hunk 접기 클릭이 전부 불가능하다.

### 4.4 색이 16색이다

`masc_tui_ansi.ml` 은 `\027[31m` 계열 16색만 쓴다. 24비트 색(`\027[38;2;r;g;b m`) 헬퍼가 없고, `COLORTERM` 을 보는 코드도 없다 (`lib/runtime/runtime_antigravity.ml` 에서 환경변수 이름으로 한 번 언급될 뿐).

이 환경은 `COLORTERM=truecolor` 다. diff 배경을 스크린샷처럼 은은한 초록/빨강으로 깔려면 24비트가 필요하다. 16색의 `녹색 배경` 은 눈이 아프다.

---

## 5. 갈림길

### 5.1 길 A — vim 에 붙인다 (제일 싸다)

Neovim 0.11.6 이 깔려 있고 `EDITOR=nvim` 이다. 설치된 런타임 문서(`/opt/homebrew/share/nvim/runtime/doc/remote.txt`) 기준으로 쓸 수 있는 것:

```
--listen <address>       RPC 를 이 주소로 연다
--server <address>       돌고 있는 nvim 에 붙는다
--remote {file}          그 nvim 에서 파일을 연다
--remote-send {keys}     키를 보낸다
--remote-expr {expr}     식을 평가하고 결과를 받아온다   ← 양방향
--remote-ui              서버의 화면을 이 터미널에 띄운다
```

맞물리는 지점이 이미 있다. `ide_bridge.mli` 의 커서 수집 함수가 정확히 nvim 이 줄 수 있는 것만 받는다:

```ocaml
val ingest_cursor_event :
  base_path:string -> codebase:string -> keeper_id:string ->
  file_path:string -> line:int -> ?column:int ->
  ?selection_end:(int * int) -> ?focus_mode:string ->
  source:string -> unit -> (unit, string) result
```

그리고 `POST /api/v1/ide/cursors` 가 이미 열려 있다.

- **MASC → vim**: TUI 에서 hunk 를 고르고 키 하나 → `nvim --server $NVIM --remote +{line} {file}`
- **vim → MASC**: `autocmd CursorMoved` 에서 `POST /api/v1/ide/cursors`. 그러면 TUI 의 keeper presence 옆에 사람 커서도 뜬다.

**새로 만들 개념이 없다.** 서버 계약도 그대로다. 붙이는 쪽 코드만 있으면 된다.

단점: 별도 창이다. 한 화면 안에서 다 되는 그림은 아니다.

### 5.2 길 B — TUI 안에 diff 를 그린다 (중간)

필요한 것:

1. **읽기 라우트 하나** — `GET /api/v1/keepers/{id}/changes` 가 tool_calls 를 투영해 타입 붙은 diff 를 준다. 또는 키퍼 체크아웃에서 `git diff` 를 돌린다.
2. **프레임 모델을 문자열에서 조각으로** (§4.1). 이게 진짜 비용이다.
3. **truecolor + 색 팔레트** (§4.4)
4. **Kitty 키보드 프로토콜 파서** (§4.2) — hunk 사이 이동, 접기에 조합키가 필요하다.

**데이터 출처를 둘 중에 골라야 한다.** 성격이 다르다:

| | tool_calls 재생 | 키퍼 체크아웃의 `git diff` |
|---|---|---|
| 보여주는 것 | 키퍼가 **하려던** 것, 호출 단위 | 트리에 **남은** 것 |
| 귀속 | 키퍼·턴·task 가 다 붙어 있음 | 없음 (누가 뭘 했는지 모름) |
| 정직함 | 실패한 편집도 기록에 남아 있음 | 실제 상태와 항상 일치 |
| 비용 | 라우트 하나 | 라우트 하나 + 프로세스 실행 |

둘 다 필요할 가능성이 높다. **"키퍼가 방금 뭘 고쳤나"는 tool_calls, "이 브랜치가 지금 어떤 상태인가"는 git diff.** 하나로 합치려 들면 둘 다 거짓이 된다.

### 5.3 길 C — 터미널을 TUI 안에 박는다 (제일 비싸다, 권하지 않는다)

`bin/dune` 의 의존성은 `eio`, `eio_main`, `yojson`, `uucp` 뿐이다. TUI 프레임워크도 PTY 라이브러리도 없다. `openpty`/`forkpty` 를 쓰는 코드도 없다.

터미널을 안에 박으려면 PTY + VT 파서(커서, 스크롤 영역, 스타일, 대체 화면, 마우스 통과)를 새로 써야 한다. 그러면 **MASC 안에 터미널 에뮬레이터를 하나 갖게 되고, 그건 MASC 가 하려는 일이 아니다.**

Ghostty 를 이미 쓰고 있으니 창을 나누는 건 터미널이 더 잘한다. 이 길은 지금 접는 쪽을 권한다.

---

## 5.4 그래서 "제일 싼 1단계"가 없다 — 후보를 다 재 봤다

vim 점프를 붙이려면 "이 파일, 이 줄"이 손에 있어야 한다. 그걸 줄 수 있는 곳을 전부 확인했다.

| 후보 | 지금 상태 | 쓸 수 있나 |
|---|---|---|
| `GET /api/v1/repositories` | 응답이 `{"repositories":[],"total":0}` | ✗ 비어 있음 |
| `GET /api/v1/ide/regions` | 이틀 전에서 멈춤 (§3.1a) | ✗ 죽은 데이터 |
| 채팅 기록의 tool 행 | `shorten` 이 경로를 잘라서 표시 문자열에 녹임 | ✗ 되돌릴 수 없음 |
| 라이브 transcript 의 `args` | 원본 JSON 그대로 있음 (`tool_call.args`) | △ **진행 중인 턴 하나만** |
| `~/.masc/tool_calls/*.jsonl` | 정확하고 오늘 것도 있음 | ✗ **HTTP 로 안 열림** |

**정확하면서 살아 있는 건 `tool_calls` 하나뿐이고, 그건 라우트가 없다.**

`bin/masc_tui_types.ml:619` 를 보면 라이브 transcript 는 `msg_live : transcript option` — 한 개다. 턴이 끝나면 기록으로 접히고 그때 `args` 가 버려진다:

```ocaml
(* masc_tui_keeper_chat_transcript.ml:24 — 라이브 *)
type tool_call = { call_id; tool_name; args : string; subject; ended; result_ready }

(* masc_tui_keeper_chat_history.ml:32 — 기록. args 가 없다 *)
| Tool_calls of string list
```

버려지는 지점이 `render_rows` 다. 입력은 `(outcome, tool_name, args, duration)` 튜플인데 출력이 `string list` 다. **`args` 가 한 함수 일찍 버려진다.** 여기를 살리는 건 워크어라운드가 아니라 원래 있던 사실을 안 버리는 것이다 — 다만 `Tool_calls` 계약과 `msg_entry.me_text : string` 까지 번져서 6~7 파일이 된다.

→ **원래 계획의 1단계와 3단계는 순서를 바꿔야 한다.** 데이터 라우트가 먼저다.

---

## 6. 권하는 순서

각 단계가 그 자체로 쓸 만해야 한다. 다음 단계가 안 와도 손해가 아니어야 한다.

§5.4 때문에 원래 세웠던 순서를 고쳤다. 데이터가 먼저다.

| 단계 | 무엇 | 왜 이 순서 | 크기 |
|---|---|---|---|
| 0 | **region 수집이 끊긴 것을 이슈로** (§3.1a) + `line_start:1`·`turn:0` (§3.1) | 지금 이 데이터를 믿고 뭘 만들면 이틀 된 거짓 위에 짓는 것 | 이슈 1~2건 |
| 1 | ~~**`GET /api/v1/keepers/{name}/file-changes`**~~ **완료** — tool_calls 를 타입 붙은 변경 목록으로 투영 (파일, 키퍼, 턴, task, old/new) | 정확하고 살아 있는 유일한 출처 | 완료 |
| 2 | **`--remote` 로 vim 열기** — 1 의 목록에서 파일:줄 을 눌러 nvim 점프 | 1 이 있으면 문자열 파싱이 필요 없다. 서버 변경 0 | 작음 |
| 3 | **Kitty 키보드 프로토콜 + truecolor** | 이후 전부가 여기 막힌다. 독립적으로도 이득 (조합키가 열린다) | 중간 |
| 4 | **프레임을 조각(span) 모델로** | diff 를 그리려면 필요. 1 없이 하면 목적 없는 리팩터가 된다 | 큼 |
| 5 | **diff 렌더러** — tool_calls 화면 / `git diff` 화면 둘로 나눠서 (§5.2) | 여기까지 와야 스크린샷 같은 그림이 나온다 | 중간 |
| 6 | **vim → MASC 커서 되먹임** (`POST /api/v1/ide/cursors`) | 2 의 반대 방향. 서버는 이미 받을 준비가 됨 | 작음 |

4번을 1번보다 먼저 하고 싶은 유혹이 있는데, 그러면 안 된다. 4번은 17,510줄짜리 TUI 의 렌더링 모델을 바꾸는 일이라 **그릴 것이 손에 있는 상태에서** 해야 한다.

**결정된 것 (2026-08-24, Vincent):** diff 출처는 tool_calls 와 `git diff` **둘 다**, 단 **다른 화면으로**. 하나로 합치면 둘 다 거짓이 된다 — 앞엣것은 "키퍼가 하려던 것"이고 뒤엣것은 "트리에 남은 것"이다.

---

## 7. 아직 확인 못 한 것

정직하게 남긴다.

1. **`turn:0` 의 원인.** region tracker 가 turn 을 못 받는 건지, 호출하는 쪽이 0 을 넘기는 건지 안 봤다.
2. ~~**tool_calls 의 보관 기간.**~~ **답 나옴** — 기본 30일 (`MASC_TOOL_CALL_LOG_RETENTION_DAYS`, `Keeper_tool_call_log.init`). 별개로 더 센 제약이 하나 나왔다: 인자 직렬화가 4,000바이트(`max_output_len`)를 넘으면 `input` 전체가 미리보기 문자열로 눌려서 **텍스트가 아예 안 남는다**. 하루 8~13건, 파일 변경의 약 5%다. 큰 변경일수록 걸리므로 화면에 "N건은 너무 커서 못 보여줌"을 같이 그려야 한다 (`over_budget`).
3. **원격 TUI.** TUI 는 `localhost:8935` 에도 붙고 `masc.crying.pictures` 터널에도 붙는다. 로컬 파일을 바로 읽는 지름길을 쓰면 원격에서 깨진다. 3번 단계를 HTTP 라우트로 하자는 이유가 이것이다.
4. **웹 대시보드의 IDE 화면이 실제로 돌고 있는지.** 파일은 있는데 (`dashboard/src/components/ide/`) 사람이 쓰고 있는지는 확인 안 했다. 안 쓰는 화면이면 TUI 와 계약을 맞출 필요가 없고, 쓰는 화면이면 맞춰야 한다.
5. **다른 언어 렉서를 늘릴지.** TypeScript 가 없으면 키즈노트 쪽 코드는 색이 안 붙는다. 손으로 렉서를 더 쓸지, 아니면 아예 안 칠할지는 결정이 필요하다.

---

## 근거

| 항목 | 확인 방법 | 시각 |
|---|---|---|
| region 480건 전부 `line_start:1` | `rg -c` on `~/me/.masc-ide/by-url/github.com_jeong-sik_masc/regions.jsonl` | 2026-08-24 |
| Edit 기록의 `old_string`/`new_string` | `~/.masc/tool_calls/2026-08/11.jsonl` 첫 Edit 행 파싱 | 2026-08-24 |
| TUI 가 IDE 라우트를 안 부름 | `rg -o '"/api/[a-z0-9/_{}-]*"' bin/masc_tui_http.ml bin/masc_tui_loader.ml` | 2026-08-24 |
| 조합키가 `unknown-esc` 로 떨어짐 | `bin/masc_tui.ml:183` | 2026-08-24 |
| Ghostty 가 Kitty 그래픽 프로토콜 지원 | <https://ghostty.org/docs/about> | 2026-08-24 |
| Ghostty 가 Kitty 키보드 프로토콜 지원 | ghostty-org/ghostty discussions #5071, #9368 | 2026-08-24 |
| nvim remote 플래그 | `/opt/homebrew/share/nvim/runtime/doc/remote.txt` (설치된 v0.11.6) | 2026-08-24 |
| 키퍼 체크아웃이 진짜 git | `~/.masc/playground/rondo/repos/masc` → `feat/task-484-keeper-tool-surface`, 더러운 파일 2 | 2026-08-24 |
| 오늘 repos/masc 쓰기 138건, region 0건 | `~/.masc/tool_calls/2026-08/24.jsonl` 집계 vs `regions.jsonl` 마지막 줄 | 2026-08-24 18:54 |
| `/api/v1/repositories` 가 빈 응답 | `curl localhost:8935/api/v1/repositories` → `{"repositories":[],"total":0}` | 2026-08-24 |
| `/api/v1/ide/regions` 는 codebase 를 요구 | `curl .../ide/regions` → `missing_ide_scope` (기본값으로 뭉개지 않음, RFC-0378 대로) | 2026-08-24 |

확신도: **높음** — 위 항목은 전부 이 장비에서 직접 세거나 읽었다.
확신도: **중간** — §6 의 단계 크기 추정. 4번(프레임 모델 교체)은 실제로 손대 보기 전에는 폭을 모른다.
