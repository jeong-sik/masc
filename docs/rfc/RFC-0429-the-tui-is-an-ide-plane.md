---
rfc: "0429"
title: "TUI 는 IDE 면이다 — 실측으로 잡은 결함, 언어 서버의 전 언어 확장, Mermaid 를 터미널에 그린다"
status: Draft
created: 2026-09-06
updated: 2026-09-06
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0378", "a-language-server-the-keeper-can-ask", "0261"]
---

# RFC-0429: TUI 는 IDE 면이다

## 0. Summary

TUI 에는 이미 IDE 의 조각이 있다. Workspace 에서 저장소를 열고, Code 화면에서 파일을 읽고, `K`/`D`/`R` 로 언어 서버에 묻고, `m` 으로 keeper 의 줄 메모를 보고, keeper 가 바꾼 파일과 diff 를 본다. 2026-09-06 새벽에 main 빌드를 tmux 에서 직접 띄워 이 화면들을 하나씩 눌러 봤다. 결과는 §1 에 있다. 화면이 깨지는 곳은 없었고, 대신 세 가지가 잘못 동작했다. 언어 서버와 메모 요청이 TUI 안에서 10초 뒤 timeout 으로 끝나는데 같은 요청을 curl 로 보내면 0.3초에 답이 온다. 변경 목록의 WHAT 열이 줄바꿈을 `\x0A` 여섯 글자로 찍는다. hover 후보를 고르는 팔레트가 후보 4개 옆에 관계없는 task 와 post 18개를 같이 보여준다.

이 RFC 는 그 결함을 고치는 순서와, 그 위에 올릴 세 가지를 정한다. 언어 서버를 서버가 띄울 수 있는 모든 언어로 넓히되 언어와 명령의 대응을 닫힌 합타입과 운영자 설정으로 둔다. Mermaid 블록을 TUI 안에서 그린다. 첫 단계는 OCaml 로 짠 텍스트 렌더러이고, 픽셀 경로(Kitty graphics)는 렌더러가 설정된 경우에만 여는 다음 단계다. keeper 의 줄 메모를 파일 안 주석으로 옮길지는 사용자 결정 뒤에 따로 다룬다.

## 1. 실측 (2026-09-06 02:08–02:20 KST, main 5600fc5, Ghostty 1.3.1, 220×50, tmux)

프레임 43장은 세션 scratchpad `measure/` 에 있다. 서버는 51e1b86 (TUI 보다 오래된 빌드) 였다.

### 1.1 화면 자체는 깨지지 않는다

| 화면 | 확인한 것 | 결과 |
|---|---|---|
| Workspace (저장소 표) | pane 켜고 끔 | 표, 경로, 상태 모두 제자리. pane 이 있어도 168칸 안에서 열이 잘리지 않는다 |
| Workspace / Code (트리 + 파일) | pane 켜고 끔, `l` 로 파일 pane 이동 | 줄 번호와 본문 정상. pane 을 숨기면 구분선이 220칸까지 늘어난다 |
| Changes (keeper 파일 변경) | 45건 목록, Enter 로 diff | diff 본문은 `+` 접두와 들여쓰기 그대로. 목록의 WHAT 열만 §1.3 |
| Git changes | 깨끗한 저장소 | `(working tree clean)` |

사용자가 "Repo, keeper memo, diff, LSP 표시가 제대로 안 되는 것 같다" 고 본 것은 배치가 깨진 게 아니라 아래 세 가지다.

### 1.2 언어 서버 답과 메모가 TUI 안에서만 10초 timeout 이다

- Code 화면에서 `K` 를 누르고 `resolve_with` 를 고르자 제목줄이 `asking hover about "resolve_with"` 로 바뀌고, 10초 뒤 `resolve_with: (GET failed: timeout after 10.0s)` 가 됐다. `m` 으로 연 메모도 `(loading notes)` 뒤 같은 timeout.
- 서버 로그는 키를 누른 그 초(17:11:42Z)에 `LSP pool started ocaml for …/repos/masc` 와 `LSP pool dropped ocaml …: End_of_file` 를 남겼다. 이 두 줄은 요청 단위 pool 의 정상 시작과 정상 종료다. curl 로 같은 route 를 부르면 200 과 함께 같은 두 줄이 남는다.
- 같은 요청을 admin token 으로 직접 잰 값:

| 측정 | 값 |
|---|---|
| hover 순차 15회 | min 0.25s · median 0.28s · max 0.68s |
| hover 병렬 5회 | 0.97s 전후, 모두 200 |
| `/api/v1/status` 12회 (keeper 16대 가동 중) | 0.8ms – 1.7s |

- 그 시각 TUI 프로세스는 `:8935` 로 ESTABLISHED 7개, CLOSED 19개 소켓을 들고 있었다. `r` 를 누른 뒤 12초 동안 제목줄은 10초가 `[reconnecting...]` 이었다.

서버는 1초 안에 답한다. 답을 10초 동안 받지 못한 쪽은 TUI 다. `Masc_http_client.get_sync` 의 timeout 은 `Eio.Fiber.first` 로 응답 fiber 와 `Eio.Time.sleep` 을 겨루게 하는 구조라, 응답 fiber 가 진행하지 못하면 정확히 10초에 이 문구가 나온다. 진행하지 못하는 이유는 아직 모른다. 후보는 둘이다. pool 이 상대가 이미 닫은 warm client 를 건네서 응답이 오지 않는 소켓을 기다리는 경우 (CLOSED 19개가 그 흔적일 수 있다), 그리고 메인 루프가 fiber 에 순서를 늦게 주는 경우. §3.0 이 이걸 재는 방법이다. 추측으로 고치지 않는다.

### 1.3 변경 목록의 WHAT 열이 줄바꿈을 글자로 찍는다

```
1077 task-558   EDIT  APPLIED  masc-main-fr…nfig/env_config_keeper.ml [L404-408→L404-449] |> Float.max base\x0A  ;;\x…x0A    |> Float.max base\x0A  ;;\x0Aend\x0A\
```

`change_row_summary` 가 편집 뒤 본문을 `Terminal_text.single_line` (= `Tui_decode.sanitize_terminal_text`) 에 통과시킨다. 이 함수는 외부에서 온 문자열을 한 줄로 만드는 안전장치라 제어 문자를 `\x0A` 로 바꾼다. 코드 본문의 줄바꿈은 제어 문자가 아니라 내용이다. 한 줄 미리보기에는 줄바꿈을 눈에 보이는 한 칸짜리 표시로 바꾸는 별도 투영이 필요하다. 승인 화면도 같은 문제를 이미 겪었고 (`approval_detail_pane` 주석), 게시판 본문은 줄 단위로 통과시키는 것으로 피했다.

### 1.4 hover 후보 팔레트가 후보와 무관한 항목을 섞는다

`K` 를 누른 줄에 이름이 넷이면 Quick Jump 팔레트가 열린다. 그 목록은 `hover resolve_with` 등 후보 4개 다음에 task 와 post 18개가 이어져 `1/22` 였다. 후보를 고르는 화면에서 다른 도착지 18개는 읽을 필요가 없는 줄이다. 그 상태에서 `m` 을 누르면 메모가 아니라 팔레트 필터에 `m` 이 들어간다.

### 1.5 메모 화면은 여백이 아니라 교체다

`m` 은 파일 본문을 지우고 그 자리에 메모 목록을 그린다 (`notes: <path>` 제목). GitHub 의 줄 메모처럼 코드 옆에 붙는 것이 아니다. 메모가 어느 줄의 것인지 코드와 나란히 볼 수 없다.

### 1.6 언어 서버는 6개 언어, 이 호스트에는 그중 3개만 있다

`Lsp_process_manager.language` 는 `Ocaml | Typescript | Javascript | Python | Rust | Go` 이고 명령은 `ocamllsp`, `typescript-language-server`, `pylsp`, `rust-analyzer`, `gopls` 다. 이 호스트에 있는 것: `ocamllsp` 1.27.0, `pyright-langserver`, `rust-analyzer`, `clangd`, `sourcekit-lsp`. 없는 것: `typescript-language-server`, `pylsp`, `gopls`. Python 은 서버가 아는 명령(`pylsp`)이 없고, 있는 명령(`pyright-langserver`)은 서버가 모른다. C/C++ 와 Swift 는 언어 자체가 없다.

### 1.7 Mermaid 는 서버가 타입으로 알고 TUI 는 평문으로 그린다

`Keeper_chat_blocks` 는 ```` ```mermaid ```` 펜스를 `Mermaid of mermaid_block` 으로 분류한다. TUI 의 `bin/` 에는 `mermaid` 라는 단어가 없다. `lexer_of_language "mermaid"` 는 `None` 이라 소스가 그대로 나온다. 대시보드는 브라우저에서 그린다. keeper 들이 채팅에 남긴 mermaid 펜스는 파일 3개에 6개, 첫 단어는 `graph` 5 · `flowchart` 1 이다.

## 2. 원칙이 강제하는 것

| 원칙 | 이 RFC 에서 |
|---|---|
| 추측으로 고치지 않는다 | §1.2 의 stall 은 원인을 잰 뒤 고친다. 재는 코드가 첫 PR 이다 |
| 닫힌 합타입 | 언어는 variant 로 남는다. 새 언어는 `language_of_extension`, `command_of_language`, `project_markers_of_language` 를 모두 채워야 컴파일된다. Mermaid 도 지원하는 도표 종류가 variant 이고 모르는 종류는 `Unsupported of string` 으로 화면에 그 이름을 적는다 |
| 문자열 분류기 금지 | 줄바꿈 투영은 한 문자를 한 표시로 바꾸는 총함수이지 내용을 보고 고르지 않는다. Mermaid 파서는 토큰 문법이지 substring 탐색이 아니다 |
| Unknown → 허용 기본값 금지 | 설정에 없는 언어 서버는 `Command_not_found` 로 제목줄에 적힌다. 후보 명령을 순서대로 시도하지 않는다 |
| 게이트 추가 없음 | 새 상태·플래그 없음. 렌더러가 없으면 소스가 보이고 그 사실이 제목에 적힌다 |
| 셸 아웃 없음 (TUI) | TUI 는 프로세스를 띄우지 않는다 (#30201 이 `tput` 파이프를 뺐다). 외부 렌더러는 서버가 LSP 서버를 띄우는 것과 같은 자리에서만 띄운다 |
| 테스트 | 렌더러는 golden frame, 투영은 단위, stall 은 두 시계 계측 로그 |

## 3. 설계

### 3.0 S0 — 요청 stall 을 잰 뒤 고친다 (선행, 차단 결함) — 끝남

**답: 메인 루프가 한 바퀴 도는 데 쓰는 시간이다.**

`Unix.select` 는 파이버 하나가 아니라 도메인 전체를 막는다. 소켓을 기다리는 파이버는 이 루프가 돌아올 때만 한 걸음 나아가므로, 응답 하나에 드는 시간이 *걸음 수 × 루프 한 바퀴 비용* 이 된다. §1.2 의 10초는 여기서 나왔다.

측정 도구는 `masc-http-probe` (`bin/masc_http_probe.ml`, #33769 · #33772 · #33785). TUI 를 빼고 같은 클라이언트·같은 시계·같은 10초 제한으로 부른다.

| | 서버(curl) | 탐침 | 살아 있는 TUI |
|---|---|---|---|
| `keepers/asks` (87 B) | 8 ms | 6 ms | 1084 ms |
| `keepers/turns` (2 KB) | 1 ms | 2 ms | 1361 ms |
| `gate/keepers?detailed` (9 KB) | 2 ms | 4 ms | 3013 ms |
| `dashboard/briefing` (1.5 MB) | — | 16 ms | 2508 ms |

이것으로 후보 하나(연결 풀)가 지워졌다. 나머지 후보는 루프의 양보 자리였는데, 기다리고 양보하기만 하는 모양은 재현하지 못했다. 빠진 조각은 루프가 양보하기 전에 하는 일이었다. `--loop-work-ms` 로 그 비용만 세우니 나타난다.

| 루프 한 바퀴 비용 | asks (87 B) | briefing (1.8 MB) |
|---|---|---|
| 없음 | 8 ms | 18 ms |
| 10 ms | 132 ms | 5050 ms |
| 50 ms | 610 ms | 10초에 timeout |

걸음 수는 루프 비용과 무관하게 일정하다 (asks 열세 걸음, 1.8 MB 오백 걸음쯤).

**고침(#33794): 키를 기다리는 자리를 Eio 안으로 옮긴다.** 도메인을 나누는 게 아니라 기다리는 자리가 문제였다. 같은 1.8 MB 를, 루프 한 바퀴 10 ms 기준으로:

| 루프가 기다리는 방식 | 걸린 시간 |
|---|---|
| `Unix.select` | 5544–5631 ms |
| Eio 안에서 대기 | 14–26 ms |

준비 대기만 마감과 겨루고 읽기는 겨루지 않는다. 진 쪽 읽기가 이미 가져온 바이트를 들고 버려질 수 있고 그게 키 입력이다. 시작할 때 터미널 프로브는 `Eio_guard.run_in_systhread` 안에서 같은 reader 를 쓰므로 거기선 커널 대기를 그대로 둔다 — 시스템 스레드가 막히는 건 도메인을 세우지 않는다.

살아 있는 TUI A/B (같은 서버·화면·드라이버, 각 80초, 계측 문턱 100 ms): 100 ms 넘은 요청이 7건(중앙값 347 ms, 최대 610 ms)에서 5건(중앙값 193 ms, 최대 412 ms)으로. 탐침보다 차이가 작은 건 배수가 프레임 비용이라 한가한 화면에서는 작기 때문이다. 표본도 작다.

남은 것: 렌더 일정이 계속 프레임을 요구하는 동안에는 대기가 0이라 루프가 Eio 안에서 멈추지 않는다. 그때는 다시 한 바퀴에 한 걸음이다.

### 3.1 S1 — 읽히는 것 셋

1. **한 줄 미리보기 투영.** `Tui_decode.preview_line : string -> string` 을 추가한다. 줄바꿈(`\n`, `\r\n`)은 `⏎` (U+23CE, 1칸) 로, 탭은 한 칸 공백으로, 나머지 제어 문자는 지금처럼 `sanitize_terminal_text` 로 보낸다. `change_row_summary` 와 승인 목록의 `Edit` 인자 줄이 이 투영을 쓴다. 단위 테스트는 `"a\nb"` → `"a⏎b"`, 폭이 입력 줄 수와 무관하게 1칸씩만 늘어남을 고정한다.
2. **후보 팔레트.** `K`/`D`/`R` 에 이름이 여럿일 때 여는 팔레트는 후보만 담는 닫힌 모드다 (`Palette_choice of { question; candidates }`). 도착지 목록과 섞이지 않고, 필터는 후보 안에서만 돈다. 제목은 `hover · 4 names on line 11` 처럼 질문과 줄을 적는다.
3. **메모는 여백.** `m` 은 본문을 유지하고 왼쪽 gutter 한 칸에 메모가 있는 줄을 `┃` 로 표시한다. 커서가 그 줄에 오면 메모 본문이 제목줄 아래 한 줄(길면 잘라서)에 나온다. 전체 목록은 지금처럼 두 번째 `m` 으로 연다. blame 이 이미 이 모양(여백 + 제목줄)으로 그려지므로 같은 배치 코드를 쓴다.

### 3.2 S2 — 언어 서버를 서버가 띄울 수 있는 모든 언어로

`Lsp_process_manager.language` 를 넓힌다. 각 언어는 확장자, 프로젝트 표지 파일, 기본 명령을 모두 선언한다. 하나라도 빠지면 컴파일되지 않는다.

| 언어 | 확장자 | 프로젝트 표지 | 기본 명령 |
|---|---|---|---|
| Ocaml | .ml .mli | dune-project, dune-workspace | ocamllsp |
| Typescript / Javascript | .ts .tsx / .js .jsx .mjs | tsconfig.json, jsconfig.json, package.json | typescript-language-server --stdio |
| Python | .py .pyi | pyproject.toml, setup.py, setup.cfg | pyright-langserver --stdio |
| Rust | .rs | Cargo.toml | rust-analyzer |
| Go | .go | go.mod | gopls |
| C / Cpp | .c .h / .cc .cpp .cxx .hpp .hh | compile_commands.json, CMakeLists.txt, Makefile | clangd |
| Swift | .swift | Package.swift | sourcekit-lsp |
| Java | .java | pom.xml, build.gradle, build.gradle.kts | jdtls |
| Kotlin | .kt .kts | build.gradle.kts, settings.gradle.kts | kotlin-language-server |
| Ruby | .rb | Gemfile | ruby-lsp |
| Php | .php | composer.json | intelephense --stdio |
| Lua | .lua | .luarc.json | lua-language-server |
| Bash | .sh .bash .zsh | (없음: 파일의 디렉터리) | bash-language-server start |
| Json / Yaml | .json / .yml .yaml | (없음) | vscode-json-language-server --stdio / yaml-language-server --stdio |
| Zig | .zig | build.zig | zls |
| Haskell | .hs | *.cabal, stack.yaml, cabal.project | haskell-language-server-wrapper --lsp |
| Elixir | .ex .exs | mix.exs | elixir-ls (language_server.sh) |
| Dart | .dart | pubspec.yaml | dart language-server |
| Scala | .scala .sc | build.sbt | metals |
| Csharp | .cs | *.sln, *.csproj | csharp-ls |

기본 명령은 코드의 닫힌 표다. 운영자는 `runtime.toml` 의 `[lsp.servers]` 에서 언어별 명령을 바꾼다. 예: `python = ["pylsp"]`. 키는 `lang_id_of_language` 가 내는 문자열이며, 표에 없는 키는 부팅 검증에서 거부된다 (runtime.toml 은 hot reload 대상이므로 재시작 없이 반영된다). Python 의 기본을 `pyright-langserver` 로 바꾸는 근거는 §1.6 (이 호스트에 있는 것). `pylsp` 를 쓰는 곳은 설정으로 돌린다.

참조 인덱스(`reference_index_of_language`)는 OCaml 만 값이 있고 나머지는 `None` 인 지금 상태를 유지한다. 새 언어의 서버가 references 를 위해 무엇을 미리 만들어야 하는지는 각각 재 본 뒤에만 채운다.

TUI 쪽은 이미 언어를 모른다. `/api/v1/lsp/question` 이 답하면 그대로 보여준다. 추가할 것은 둘이다. Code 제목줄에 `python · pyright-langserver` 처럼 언어와 서버 이름을 적고, `Command_not_found` 는 `python · pyright-langserver not on PATH` 로 적는다. `Masc_tui_code_lexer.lexer_of_language` 는 C, C++, Java, Kotlin, Swift, Go, Rust, TypeScript, JavaScript 를 `c_like_lexer` 에, Python 을 `python_lexer` 에, 셸을 `bash_lexer` 에 잇는다. 나머지 언어는 색 없이 그린다 — 문법을 모르는 채 색칠하지 않는다는 지금 규칙 그대로.

### 3.3 S3 — Mermaid 를 텍스트로 그린다

`bin/masc_tui_mermaid.ml` (의존성 없음, `masc_tui_message_layout` 만) 를 둔다.

- **파서.** 지원 종류는 닫힌 합타입 `Graph of direction * node list * edge list | Sequence of participant list * message list`. `graph`/`flowchart` 는 방향(TD/TB/BT/LR/RL), 노드 `id[label]`, `id(label)`, `id{label}`, `id((label))`, 간선 `-->`, `---`, `-.->`, `==>`, 간선 라벨 `-->|text|`, `subgraph … end` 를 읽는다. `sequenceDiagram` 은 `participant`, `A->>B: text`, `A-->>B: text`, `loop/alt/opt … end` 를 읽는다. 첫 줄이 다른 종류(`classDiagram`, `erDiagram`, `stateDiagram`, `gantt`, `pie`, …)면 `Unsupported of string` 이다. 문법 오류는 `Parse_error of { line; what }` 이다.
- **배치.** 그래프는 층 배치다. 역방향 간선을 제거해 DAG 로 만들고(DFS 로 찾은 back edge 를 뒤집어 그린 뒤 표시만 원래 방향), 최장 경로로 층을 정하고, 층마다 barycenter 로 순서를 정한다(고정 반복 횟수, 결정적). 노드 상자는 라벨 폭 + 2, 간선은 직교선으로 그린다. 터미널 폭을 넘으면 라벨을 `fit_middle` 로 줄이고, 그래도 넘으면 가로 스크롤이 아니라 `graph wider than N cells` 한 줄을 남기고 소스를 보인다. 시퀀스 다이어그램은 참가자 열 + 화살표 행이라 배치가 단순하다.
- **출력.** `render : cols:int -> string -> rendering` 에서 `rendering = Rows of string list | Unsupported of string | Parse_error of …`. 셀은 box-drawing 과 화살표 글리프이고 모두 1칸 폭 문자만 쓴다 (ambiguous width 회피, Activity pane 과 같은 이유).
- **어디에 그리나.** 채팅의 `Mermaid` 블록, Code 화면의 `.mmd` 파일과 markdown 안 펜스, 게시판 본문. 세 곳 모두 `rows_of_segments` 가 받는 행 목록으로 들어간다. `Unsupported` 와 `Parse_error` 는 소스를 그대로 두고 첫 줄 위에 `mermaid · classDiagram is not drawn here` 처럼 이유를 적는다.
- **테스트.** golden frame 12장: 방향 5종, 분기·합류, 사이클 1개, subgraph, 라벨 간선, 시퀀스 loop/alt, 폭 초과, 오류 위치. 같은 입력·같은 폭이면 바이트가 같아야 한다.

외부 도구를 쓰지 않는 이유. mermaid-ascii (Go, MIT) 는 graph/sequence/ER 을, termaid (Python, MIT, 의존성 없음) 는 18종을 그린다. 서버가 LSP 서버처럼 이들을 프로세스로 띄우고 행을 받아 오는 길도 있다. 그러나 (1) 실측된 사용은 graph/flowchart 뿐이고, (2) 렌더링이 프로세스와 PATH 에 묶이면 keeper 마다·호스트마다 결과가 달라지며, (3) 결정적 golden test 를 우리 코드에 걸 수 없다. 18종이 실제로 필요해지면 그때 §3.4 의 설정된 렌더러 자리에 넣는다.

### 3.4 S4 — 픽셀 경로 (뒤로 미룸)

Ghostty 는 Kitty graphics 프로토콜을 지원하고 TUI 에는 `/image` 가 쓰는 `Masc_tui_graphics` 가 이미 있다 (프로토콜 질의에 답한 터미널에만 그린다). 부족한 것은 mermaid → PNG 다. `mmdc` 는 Chromium 이 필요하다. 이 단계는 `runtime.toml` `[diagram] renderer = [...]` 로 명령이 설정된 경우에만 서버가 `/api/v1/diagram/render` 에서 PNG 를 만들고, TUI 가 §3.3 의 텍스트 대신 그림을 놓는다. 설정이 없으면 이 route 는 존재하지 않는 것과 같다. 지금은 설계만 적고 구현하지 않는다.

### 3.5 줄 메모를 파일 안 주석으로 — 사용자 결정 대기

서버 annotation (`ide_annotate`, `annotations.jsonl`) 은 코드를 바꾸지 않고 다른 checkout 에 안 따라간다. 파일 안 주석은 diff 와 PR 에 실리고 메모 쓰기 자체가 파일 변경이 된다. 어느 쪽이 맞는지는 메모가 PR 까지 가야 하는가에 달려 있고, 그 답은 이 RFC 밖이다. 답이 오면 §3.1-3 의 여백 그리기가 두 저장소 중 어느 쪽을 읽든 같은 모양으로 남도록 여백 코드는 anchor `(line_start, line_end, text, author)` 만 받는다.

## 4. 검증

| 단계 | 통과 조건 |
|---|---|
| S0 | 세 번 재현에서 네 시각이 모두 로그에 있고, 어느 구간이 10초를 먹는지 한 문장으로 말할 수 있다 — **끝남.** 한 문장은 §3.0 맨 위에 있다. 네 시각 대신 TUI 를 뺀 대조군(`masc-http-probe`)으로 갈랐다: 같은 클라이언트가 밖에서 16 ms 에 받는 1.5 MB 를 TUI 는 2508 ms 로 적는다 |
| S1 | `test_tui_decode` 에 `preview_line` 4케이스. Changes 목록 프레임에 `\x0A` 가 없다 (PTY 시나리오 1개). 팔레트 후보 모드에 task/post 가 없다 (`test_tui_palette`). 메모 여백 golden 1장 |
| S2 | `test_lsp_process_manager`: 모든 variant 가 확장자·표지·명령을 갖는다 (변경 시 exhaustive match 로 컴파일 실패). runtime.toml 파서: 모르는 언어 키 거부, 아는 키는 명령 교체. 이 호스트에서 `.py` hover 가 pyright 로 답한다 (curl 1회, 기록) |
| S3 | golden 12장 바이트 일치. 채팅 PTY 시나리오에서 mermaid 펜스가 상자로 그려진다 |

CI 비용: 단계마다 pr-check 1회 + 해당 suite 만 지정한 targeted run 1회.

S0 은 이 표의 통과 조건을 다르게 채웠다. 네 시각을 한 요청 안에 박는 대신, 같은 클라이언트를 TUI 없이 부르는 대조군을 만들어 전송과 루프를 갈랐다. 요청 안을 쪼개지 않고도 어느 쪽인지 답이 나왔고, 그 도구가 고침의 효과를 재는 자리로도 남았다.

## 5. 하지 않는 것

- 브라우저를 서버에 넣지 않는다. Chromium 이 필요한 렌더러는 설정된 경우에만, 그리고 이 RFC 뒤에.
- 언어 서버 후보를 순서대로 시도하지 않는다. 한 언어에 한 명령, 설정으로만 바뀐다.
- TUI 가 프로세스를 띄우지 않는다.
- Mermaid 18종을 한 번에 하지 않는다. 실측된 두 종류가 먼저다.
- stall 을 timeout 값을 늘려 덮지 않는다.

## 6. Evidence Record

| 항목 | Evidence | Timestamp | Confidence | Delta |
|---|---|---|---|---|
| Ghostty 의 Kitty graphics 지원 | https://ghostty.org/docs/features — "Ghostty supports the Kitty graphics protocol, which allows terminal applications to render images directly in the terminal." | 2026-09-05T17:15Z | High | 픽셀 경로(S4)가 이 호스트의 터미널(Ghostty 1.3.1)에서 가능하다는 근거 |
| Kitty graphics 프로토콜 | https://sw.kovidgoyal.net/kitty/graphics-protocol/ | 2026-09-05T17:15Z | High | 이미 `Masc_tui_graphics` 가 쓰는 프로토콜 |
| mermaid-ascii | https://github.com/AlexanderGrooff/mermaid-ascii — Go, MIT, graph/sequence/ER | 2026-09-05T17:16Z | Medium | 외부 텍스트 렌더러의 지원 범위 비교 기준 |
| termaid | https://github.com/fasouto/termaid — Python, MIT, 의존성 없음, 18종, grid barycenter + A* 라우팅 | 2026-09-05T17:16Z | Medium | §3.3 의 배치 방식 선택에 참고. 채택하지 않음 |
| 터미널 mermaid 의 흐름 | https://cursor.com/changelog/cli-feb-18-2026 — Cursor CLI 가 mermaid 를 ASCII 로 그림 | 2026-09-05T17:16Z | Medium | 텍스트 렌더러가 통용되는 방향임을 보임 |
| 이 호스트의 언어 서버 | `command -v` 결과 §1.6 | 2026-09-05T17:12Z | High | Python 기본 명령을 pyright 로 바꾸는 근거 |
| TUI stall 실측 | §1.2 표, scratchpad `measure/07-hover … 11-later` | 2026-09-05T17:11Z–17:19Z | High | 서버 아닌 TUI 쪽 결함으로 판정 |
