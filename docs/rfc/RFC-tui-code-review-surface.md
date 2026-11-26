---
rfc: "tui-code-review-surface"
title: "TUI 에서 키퍼가 바꾼 코드를 훑고 바로 연다"
status: Draft
created: 2026-11-26
updated: 2026-11-26
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC tui-code-review-surface: TUI 에서 키퍼가 바꾼 코드를 훑고 바로 연다

- 상태: **초안.** 운영자가 범위를 1~4단계로 골랐다(2026-11-26). `$EDITOR` 편집(5단계)은 이 RFC 밖이다.
- 계기: 운영자가 코딩 에이전트 Pi 의 확장 화면(diff 보기, 소스 떠 있는 창, vim 으로 잠깐 편집)을 보고 「masc 도 그렇게 개선 가능?」이라고 물었다.
- 헌법 로드맵 `IDE` 항목(「Keeper 작업이 그대로 투영되고 … 코드와 결합해 상태를 관측」)의 첫 조각이다.
- 코드 좌표는 `origin/main` `db1f64b19da0d` 에서 읽었다.

## 0. 요약

- 지금 TUI 는 파일 하나의 diff 를 줄 목록으로만 보여 준다. 덩어리(hunk) 경계가 없고, 바뀐 파일 목록과 diff 가 따로 논다.
- 키퍼 대화나 도구 기록에서 파일을 보려면 Infra › Code 탭으로 가서 파일을 다시 찾아야 한다.
- 이 RFC 는 네 가지를 정한다.
  1. 서버 diff 응답이 덩어리 경계를 타입으로 싣는다(D1).
  2. Code 탭에 「변경 검토」 화면을 둔다. 바뀐 파일 목록과 diff 를 한 화면에서 오간다(D2).
  3. 도구 기록이 실행 때 확정한 대상 파일을 타입 있는 필드로 남긴다(D3).
  4. 그 필드가 있는 도구 행에서 파일을 떠 있는 창으로 연다(D4).

## 1. 지금 모습

### 1.1 diff

- 서버 `GET /api/v1/git/diff` 는 `path` 가 꼭 있어야 한다. 없으면 400 이다(`lib/server/server_routes_http_routes_workspace.ml:2196` `handle_git_diff_get`).
- 응답을 만드는 `parse_unified_diff`(같은 파일 `:1384`)는 `@@` 줄을 읽어 줄 번호만 맞추고 버린다. 응답에는 `add`·`delete`·`context` 줄만 남는다.
- TUI 는 Infra › Code › `v` Git › Diff 에서 지금 연 파일 하나의 diff 를 색칠한 줄 목록으로 그린다(`lib/masc_tui/screens_domain/screen_infra.ml:3237`).
- 바뀐 파일 목록은 같은 메뉴의 Status 화면(`Code_git_status`)에 따로 있다. 목록에서 파일을 골라 diff 로 가는 길이 없다.
- TUI 의 「working tree」 표기(`screen_infra.ml:3245`, `path = ""`)는 서버가 400 을 주므로 닿지 않는 분기다.

### 1.2 파일 보기

- 파일 내용은 `Cmd.Get_workspace_file { scope; path }` 로 읽는다. `scope` 는 `Ws_project | Ws_repo of string | Ws_keeper of string` 이다(`lib/masc_tui/protocol/wire_infra.mli:22`).
- 파일을 볼 수 있는 곳은 Code 탭 오른쪽 칸 하나다.
- 도구 기록 행(`Wire_keeper_context.tool_call_entry`, `wire_keeper_context.mli:291`)은 도구 이름과 입력 JSON 을 그대로 싣는다. 대상 파일을 가리키는 타입 있는 필드는 없다.

## 2. 하지 않는 것

- TUI 프로세스 안에서 사용자 코드를 불러 돌리는 확장(Pi 방식)은 만들지 않는다. TUI 의 메시지와 명령은 닫힌 합타입이고, 이 구조를 유지한다.
- 도구 이름이나 입력 JSON 의 키 이름을 문자열로 비교해 파일 경로를 뽑지 않는다(헌법 `forbidden#string_matching`). 대화 본문에서 경로처럼 생긴 글자를 찾지도 않는다.
- 파일 쓰기는 이 RFC 범위 밖이다. 떠 있는 창은 읽기 전용이다.
- 화면 문구·배치를 확인하는 테스트는 만들지 않는다(헌법 `build_and_ci`). 테스트는 보낸 요청·저장한 상태·결정만 본다.

## 3. 결정

### D1. diff 응답은 덩어리를 타입으로 싣는다

- 서버는 `@@ -a,b +c,d @@ <맥락>` 줄을 버리지 않고 덩어리 행으로 낸다.

  ```json
  {"kind": "hunk", "oldStart": 12, "oldCount": 4, "newStart": 12, "newCount": 6, "section": "let step ~now m msg ="}
  ```

- `section` 은 git 이 `@@` 뒤에 붙이는 함수 맥락이다. 없으면 필드를 뺀다.
- TUI 디코더는 `kind` 를 닫힌 합으로 읽는다. 모르는 값이면 지금처럼 디코드를 실패시킨다(`wire_infra.ml:1496`).

  ```ocaml
  type git_diff_row =
    | Hunk of { old_start : int; old_count : int; new_start : int; new_count : int; section : string option }
    | Line of git_diff_line
  ```

- `git_diff_snapshot.lines` 는 `rows : git_diff_row list` 로 바꾼다. hard cut 이다. 옛 형식을 읽는 코드는 남기지 않는다.
- TUI 의 닿지 않는 「working tree」 분기는 지운다.

### D2. Code 탭의 「변경 검토」 화면

- `Infra_store.code_right_mode` 의 `Code_git_diff` 를 `Code_review` 로 바꾼다. 상태는 「지금 고른 바뀐 파일」과 「그 파일의 diff 읽기」를 함께 가진다.

  ```ocaml
  type code_review = {
    selected : string option;          (* git status 의 path *)
    diff : (workspace_scope * string * git_diff_snapshot) Observed.t;
  }
  ```

- 화면은 둘로 나뉜다. 왼쪽은 `git status` 의 바뀐 파일, 오른쪽은 고른 파일의 diff 다. 좁은 창에서는 오른쪽만 보이고 파일 이름이 머리줄에 붙는다.
- 키:

  | 키 | 동작 |
  |---|---|
  | `n` / `N` | 다음·이전 바뀐 파일을 고르고 그 diff 를 읽는다 |
  | `]` / `[` | 다음·이전 덩어리 머리로 스크롤한다 |
  | `s` | 한 줄 보기 ↔ 나란히 보기 |
  | `Enter` | 지금 줄의 새 줄 번호(삭제 줄이면 옛 줄 번호 근처 새 줄)로 파일을 Code 파일 보기에서 연다 |

- 나란히 보기는 창 너비가 두 칸을 다 담을 때만 고를 수 있다. 너비 기준은 이름 있는 상수 하나로 둔다. 좁으면 `s` 는 이유를 상태 줄에 알리고 한 줄 보기를 유지한다.
- 덩어리 이동과 파일 이동은 화면 계산이 아니라 저장한 `rows` 에서 위치를 구한다. 그래야 테스트가 상태로 확인할 수 있다.

### D3. 도구 기록은 대상 파일을 실행 때 확정해 남긴다

지금 모습:

- 기록을 쓰는 곳은 `Keeper_tool_call_log.log_call`(`lib/keeper_tool_call_log.ml:892`)이다. 키퍼 호출은 `keeper_hooks_agent_core.ml:919` 에서 들어온다.
- 파일 도구는 실행 때 `confined_path` 를 확정한다(`keeper_tool_filesystem_runtime.ml:344`·`:421`·`:593`, `keeper_tool_filesystem_remote_write.ml:277`). 이 값은 결과 JSON 의 문자열로만 나가고 기록에는 타입으로 남지 않는다.
- 기록의 `action_radius.target_path` 는 모델이 넘긴 입력에서 키 이름으로 고른 값이다(`keeper_runtime_contract.ml:116-152` `first_target_field`). 번들 기준 상대 경로와 절대 경로가 섞인다. 이 값은 쓰지 않는다.
- 실행에서 기록까지 타입 있는 값을 나르는 길은 이미 하나 있다. `Keeper_tool_execution.t.file_change_evidence`(`keeper_tool_execution.mli:49`)가 호출별 표(`keeper_tool_call_log.ml:128-166`)를 거쳐 `log_call` 에 들어가고, 행의 `file_change_evidence` 필드로 저장된다(`:1173-1177`). 바뀐 줄 범위(1부터, 양끝 포함)를 싣는다(`keeper_file_change_evidence.mli`).

결정:

- `Keeper_tool_execution.t` 에 `file_target : Keeper_file_target.t option` 을 `file_change_evidence` 옆에 둔다. 같은 호출별 표와 `log_call` 인자로 나른다.

  ```ocaml
  (* Keeper_file_target *)
  type t = private { keeper : string; relative_path : string; read_range : line_range option }
  ```

- `relative_path` 는 `Keeper_alerting_path.confined_relative_path confined` 다(`keeper_alerting_path.mli:144`). TUI 는 이것을 `Ws_keeper keeper` 범위의 경로로 쓴다. 서버의 `Ws_keeper` 기준 폴더는 `Keeper_sandbox.host_root_abs_of_meta` 다(`server_routes_http_routes_workspace.ml:101-115`).
- 값을 만드는 곳은 `confined` 가 보이는 파일 도구 실행 지점이다. 쓰기·고치기 도구와 읽기 도구(`keeper_tool_filesystem_runtime_read.ml`, `_owned_read.ml`) 모두 넣는다. 읽기 도구는 읽은 줄 범위를 `read_range` 로 싣는다.
- 기록 행에 `file_target` 필드로 저장한다. 파일 도구가 아닌 호출에는 필드가 없다. 필드가 없다는 것은 「대상 파일 없음」이다. 다른 값으로 채우지 않는다.
- TUI 는 `tool_call_entry` 에 `file_target` 과 `file_change_evidence` 를 디코드해 싣는다. 떠 있는 창의 첫 줄은 고친 범위의 시작 줄, 없으면 읽은 범위의 시작 줄, 둘 다 없으면 파일 처음이다.

### D4. 떠 있는 파일 창

- 새 overlay `Nav.File_peek of file_peek` 를 둔다.

  ```ocaml
  type file_peek = { scope : Wire_infra.workspace_scope; path : string; line : int option }
  ```

- 여는 곳: 키퍼 도구 기록 행 중 D3 의 대상 파일 필드가 있는 행에서 `o`. 필드가 없는 행에서는 `o` 가 아무 요청도 내지 않고 상태 줄에 「이 도구 기록에는 대상 파일이 없어요」를 띄운다.
- 창은 지금 화면 위에 뜬다. 뒤 화면의 상태는 바뀌지 않는다. `Esc` 로 닫으면 원래 자리로 돌아간다.
- 파일 내용은 기존 `Cmd.Get_workspace_file` 로 읽는다. 새 서버 경로를 만들지 않는다.
- 창 안 키: 스크롤, `]`/`[` (그 파일에 diff 가 있으면 덩어리 이동), `Enter` 로 Code 탭 파일 보기로 옮겨 가기.
- 읽기 실패·없는 파일·권한 없음은 `Observed.Failed` 로 그대로 보여 준다. 빈 내용으로 바꾸지 않는다.

## 4. 열린 질문

- `confined_root`(`keeper_alerting_path.ml:799` 에서 정규화)가 `host_root_abs_of_meta` 와 늘 같은 폴더인지 아직 확인하지 않았다. 4층에서 같은 키퍼로 두 값을 비교하는 테스트를 먼저 쓴다. 다르면 4층을 멈추고 이 RFC 를 고친다.
- Docker 원격 쓰기는 경로를 따로 옮긴다(`keeper_tool_filesystem_remote_write.ml:320` `remote_path`). 이 경우에도 `relative_path` 가 같은 뜻인지 4층에서 확인한다.

## 5. 단계와 확인

각 단계는 native stack 의 한 층이다.

| 층 | 내용 | 확인 |
|---|---|---|
| 1 | 이 RFC | 운영자 승인 |
| 2 | D1 서버 덩어리 행 + TUI 디코더 hard cut | 서버: 덩어리 둘인 diff 입력에 `hunk` 행 위치·값 테스트. TUI: 디코더 테스트(모르는 `kind` 는 실패) |
| 3 | D2 변경 검토 화면 | `n`/`N` 이 낸 `Get_git_diff` 요청, `]`/`[` 뒤 스크롤 위치, `Enter` 가 연 파일·줄을 상태로 확인 |
| 4 | D3 도구 기록 대상 파일 | 파일 도구 실행 한 번 뒤 기록에 대상 파일 필드가 남는지 |
| 5 | D4 떠 있는 파일 창 | `o` 가 낸 `Get_workspace_file` 요청, 필드 없는 행에서 요청 0건, `Esc` 뒤 뒤 화면 상태 그대로 |

## 6. 나중 일

- `$EDITOR` 로 열어 고치기. 운영자 결정(2026-11-26): 키퍼가 일하는 중인 worktree 파일이면 경고하고 확인을 받은 뒤 연다. 별도 RFC 로 낸다.
