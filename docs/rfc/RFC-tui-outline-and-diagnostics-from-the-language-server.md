---
rfc: "tui-outline-and-diagnostics-from-the-language-server"
title: "Code 화면이 파일 개요와 진단을 언어 서버에게 묻는다"
status: Draft
created: 2026-11-05
updated: 2026-11-05
author: vincent + claude
supersedes: []
superseded_by: null
related: ["a-language-server-the-keeper-can-ask"]
---

# RFC — Code 화면이 파일 개요와 진단을 언어 서버에게 묻는다

## 0. 요약

- Code 화면은 언어 서버에게 hover, definition, references 셋만 묻는다. 파일의 구조(개요)와 오류·경고(진단)는 묻지 않는다.
- 이 RFC 는 두 가지를 읽기 전용으로 더하자고 제안한다. 개요는 `textDocument/documentSymbol`, 진단은 `textDocument/publishDiagnostics` 의 내용이다.
- 가치는 아직 증명되지 않았다. 가장 강한 반론은 §5.1 이다. 운영자가 `e` 로 `$EDITOR` 를 열면 편집기가 이미 둘 다 보여준다.
- 그래서 이 RFC 는 구현 전에 사용자가 정할 것 다섯 가지(§6)를 먼저 묻는다. 답이 없으면 코드를 쓰지 않는다.

## 1. 지금

### 1.1 TUI 가 묻는 것

- `lib/lsp_client/lsp_questions.mli` 의 `question` 은 `References | Definition | Hover` 셋이다. 모듈 머리말이 "Completion, formatting and code actions belong to an editor; rename writes files" 라고 경계를 적는다.
- TUI 는 서버의 질문 라우트(`lib/server/server_routes_http_routes_workspace.ml`)로 묻는다. 라우트는 `Lsp_questions.question_of_string` 으로 질문 이름을 읽고, 모르는 이름은 `question must be definition, hover or references` 오류를 돌려준다.
- 같은 `Lsp_questions.ask` 를 Keeper 도구(`lib/keeper/keeper_tool_code_query.ml`)도 쓴다. 두 소비자가 한 어휘를 나눠 쓰는 것이 의도다. 라우트 주석이 "한 소비자가 한 단어 뒤처졌던" 전례를 적고 있다.

### 1.2 이미 있는 것

- 언어 서버 풀(`lib/lsp_client/lsp_workspace_pool.ml`)은 `textDocument/publishDiagnostics` 통지를 받는다. 그러나 `Versioned_diagnostics` 는 통지가 왔는지만 보고 "diagnostic text or count" 는 읽지 않는다(`.mli` 설명). Pyright 의 References 가 첫 분석 전에 불완전하게 답하는 문제를 피하려는 용도다.
- 외부 IDE 용 프록시(`lib/server/server_ide_lsp_proxy.ml`)는 `textDocument/documentSymbol` 을 통과시키고 `documentSymbolProvider` 를 선언한다. TUI 는 이 경로를 쓰지 않는다.
- 파일 열기와 닫기, 문서 버전, 요청 기한은 `ask_document` 가 맡는다. 새 전송 계층은 필요 없다.

### 1.3 측정

2026-11-05 에 이 저장소(main, `_build` 있음)에서 실제 `ocamllsp 1.27.0`(opam 5.5.0)에게 직접 물었다. 방법은 `initialize` → `didOpen` → `documentSymbol` 이고, 각 파일을 한 번씩 쟀다. 반복하지 않았고 파일 캐시 상태는 통제하지 않았다. 스크립트는 이 PR 에 넣지 않았다(재현이 필요하면 §6.5).

| 파일 | 줄 수 | documentSymbol | 최상위 심볼 | 답 크기 | 진단 통지 |
|---|---|---|---|---|---|
| `lib/lsp_client/lsp_questions.ml` | 230 | 0.31초 | 22 | 8 KB | 0.49초, 0건 |
| `lib/repo_manager/repo_git.ml` | 631 | 0.32초 | 48 | 29 KB | 0.48초, 0건 |
| `bin/masc_tui.ml` | 41,921 | 3.84초 | 976 | 626 KB | 3.84초, 0건 |
| 오류 세 줄짜리 임시 파일 | 3 | 0.05초 | 3 | 0.7 KB | 0.31초, 4건 |

- 개요는 파일 크기에 거의 비례해 커진다. 4만 줄 파일은 3.84초에 626 KB 다.
- 진단은 열린 파일에 오류가 있을 때 0.3~0.5초 안에 통지로 온다. 오류가 있는 임시 파일에서는 3줄에 4건이 왔다.
- 재 보지 않은 것: Pyright 와 TypeScript 서버의 개요·진단, 동시에 여러 파일을 열 때의 시간, `textDocument/diagnostic`(요청형 진단) 지원 여부.

## 2. 문제

- 운영자가 4만 줄 파일을 열면 위치를 찾는 수단이 `/` 텍스트 검색과 `D`(정의로 점프)뿐이다. "이 파일에 무엇이 있나"를 묻는 수단이 없다.
- 컴파일 오류나 경고를 TUI 에서 볼 수 없다. 지금은 CI 의 type-check 가 처음 컴파일하는 곳이다(`docs/constitution.xml` 의 로컬 빌드 금지 규칙).
- 다만 이 두 가지가 실제로 필요한지는 측정하지 않았다. TUI 에서 Code 화면을 얼마나, 무엇 하러 쓰는지의 기록이 없다. 이 RFC 의 가장 약한 고리다.

## 3. 제안

### 3.1 개요

- `Lsp_questions.question` 에 `Outline` 을 더한다. 서버 메서드는 `textDocument/documentSymbol` 이다.
- 답은 `Symbols of symbol list` 다. 심볼은 이름, 종류, 줄 범위, 자식 목록이다. 서버는 계층형(`DocumentSymbol[]`)이나 평면형(`SymbolInformation[]`)으로 답할 수 있으므로 둘 다 읽고, 읽을 수 없는 모양은 기존 방식대로 `Unparsed_answer` 오류로 돌려준다. 건너뛰지 않는다.
- 빈 목록은 "서버가 봤는데 없다"이고, "서버 없음"·"설치 안 됨"과 다른 사실이다(기존 `Locations []` 와 같은 원칙).

### 3.2 진단

- 진단은 질문이 아니라 서버가 보내는 통지다. 저장소를 만들면 상태가 생기고(§5.3 이 반박한다), 안 만들면 파일을 열고 통지를 기다렸다가 내용을 돌려주고 닫는 일회성 읽기가 된다.
- 제안은 후자다. `ask_document` 와 같은 모양으로, 새 파일 버전을 열고, 그 버전의 `publishDiagnostics` 를 기다려 내용을 돌려주고, 닫는다. 기다림은 기존 요청 기한이 묶는다. 통지가 기한 안에 안 오면 오류이고, 빈 목록으로 바꾸지 않는다.
- 답은 `Diagnostics of diagnostic list` 다. 진단은 줄 범위, 심각도(오류·경고·정보·힌트), 메시지, 출처다.

### 3.3 경계

- 읽기 전용이다. completion, formatting, rename, code action 은 계속 이 모듈 밖이다. 이 RFC 는 그 경계를 지우지 않고 "묻는 것"을 둘 늘릴 뿐이다.
- 언어 서버가 없는 언어는 기존 §3.3(서버 없음의 유형 있는 답)을 따른다.

## 4. 층

각 층은 이전 층의 CI 통과를 기다린다.

1. `Lsp_questions` 에 `Outline` 과 답 파서. 서버가 실제로 준 JSON 을 고정한 시험으로 계층형·평면형·모르는 모양을 확인한다.
2. 질문 라우트가 `outline` 을 받는다. 오류 문구에 `outline` 을 더한다.
3. TUI 디코드와 Code 화면의 개요 팔레트(키는 층 3 에서 정한다).
4. 풀이 진단 내용을 돌려주는 읽기.
5. 라우트와 TUI 의 진단 목록.

## 5. 반론과 거절한 대안

### 5.1 편집기가 이미 한다

`e` 는 `$EDITOR` 로 초안을 연다(`docs/guides/TUI-KEYS.md` 의 Workspace / Code). 편집기는 보통 개요와 진단을 이미 보여준다. TUI 가 같은 일을 하는 이유가 필요하다.

- 가능한 이유: 운영자가 원격 터미널에서 TUI 만 쓰는 경우, Keeper 가 쓴 파일을 편집기 없이 읽는 경우, 편집 중이 아니라 읽기만 하는 경우.
- 이 이유들이 실제인지는 모른다. §6.1 이 이것을 묻는다.

### 5.2 외부 IDE 프록시를 TUI 가 쓴다

프록시는 이미 `documentSymbol` 을 통과시킨다. 그러나 TUI 가 그 프로토콜(LSP over WebSocket)을 말하려면 JSON-RPC 클라이언트를 새로 만들어야 한다. 기존 RFC(`a-language-server-the-keeper-can-ask` §4)가 "raw 소켓을 주면 소비자가 수명 주기를 떠안는다"고 거절한 것과 같은 이유로 거절한다.

### 5.3 진단 저장소를 둔다

풀이 파일별 최신 진단을 기억하면 요청이 즉시 답한다. 그러나 열린 문서·버전·무효화의 상태가 생기고, 그 상태가 서버와 어긋나는 경로가 늘어난다. 일회성 읽기가 0.3~0.5초이므로 이 RFC 는 저장소를 만들지 않는다. 느리다고 증명되면 다시 본다.

### 5.4 큰 파일에서 개요를 자른다

626 KB 를 받아 앞 N 개만 보이는 방법은 "한도로 증상을 가리는" 쪽에 가깝다. 이 RFC 는 한도를 정하지 않고 §6.4 로 넘긴다.

## 6. 사용자가 정할 것

1. **가치.** 개요·진단이 TUI 에 필요한가. 필요하다면 §5.1 의 어느 경우인가. 아니라면 이 RFC 를 `Dropped` 로 닫는다.
2. **Keeper 에게 노출할지.** `question_of_string` 은 Keeper 도구와 라우트가 함께 쓴다. `Outline` 을 variant 에 더하면 Keeper 도구도 받게 될 수 있다. 두 소비자의 어휘를 같게 둘지, 갈라서 TUI 전용으로 둘지 정해야 한다. 이 문서는 도구의 입력 스키마를 확인하지 않았다.
3. **진단을 어떻게 받나.** 통지를 기다리는 방식(§3.2)과 요청형 `textDocument/diagnostic`(LSP 3.17) 중 어느 쪽인지. 요청형은 `ocamllsp` 가 지원하는지 재 보지 않았다.
4. **큰 파일.** 4만 줄 파일은 3.84초에 626 KB 다. 그대로 받을지, 최상위만 먼저 줄지, 줄 범위로 나눠 받을지.
5. **재현 수단.** 위 측정을 반복할 수 있게 스크립트를 `scripts/` 에 둘지.

## 7. 하지 않는 것

- completion, formatting, rename, code action.
- 진단 저장소와 무효화.
- 새 전송 계층.
- 언어 서버를 설치하거나 관리하는 일.

## 8. 워크어라운드 자기 점검

- 텔레메트리로 때우는가: 아니다. 답을 돌려준다.
- 문자열 분류기를 더하는가: 아니다. 심각도와 종류는 닫힌 variant 로 읽고, 모르는 값은 오류다.
- N-of-M 패치인가: 아니다. 개요와 진단 둘이 이 RFC 의 전부이고, §7 이 나머지를 닫았다.
- 한도·쿨다운·중복 제거·복구로 가리는가: §5.4 가 한도를 거절했다. 큰 파일 처리는 §6.4 에서 정한다.
