---
rfc: "tui-json-display-boundary"
title: "TUI 는 JSON 을 값으로 받아 한 경계에서 터미널 글자로 바꿔요"
status: Draft
created: 2026-11-15
updated: 2026-11-15
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC: TUI 는 JSON 을 값으로 받아 한 경계에서 터미널 글자로 바꿔요

- 상태: 초안. 코드는 바꾸지 않아요.
- 이슈: #47489.
- 먼저 있는 일: #47493 이 `Masc.Tui_terminal_json.sanitize_canonical_preview` 를 만들었어요. 같은 날(2026-11-02) #47490·#47495·#47497·#47499 가 화면 다섯 곳을 그 함수로 옮겼어요. 모두 `Refs` 였고 이슈는 열려 있어요.
- 코드 좌표는 `origin/main` `807a5e46ab99` 에서 읽었어요. 운영 데이터는 읽지 않았어요.

## 0. 요약

- JSON 을 직렬화한 뒤 일반 텍스트 정리기에 넣으면, 직렬화가 만든 이스케이프의 숫자를 원문 글자로 읽어 홀로 남은 변형 선택자(U+FE0F)를 날바이트로 내보내요.
- 화면 코드는 직렬화한 문자열을 아무 정리기에나 넣을 수 있어요. 그래서 호출처를 고쳐도 같은 꼴이 다시 생겨요.
- `Tui_terminal_json` 에 값(`Yojson.Safe.t`)을 받는 함수를 두고, 화면에 JSON 을 그리는 곳은 모두 그 함수를 불러요. 문자열을 받는 정리기는 모듈 안으로 내려요.
- 직렬화 결과를 문자열 필드에 담는 decode 결과 8개는 닫힌 타입으로 나눠요.

## 1. 무엇이 깨지나요

- 재현: `` Yojson.Safe.pretty_to_string (`String "\000\239\184\143") `` 는 이스케이프 `\u0000` 바로 뒤에 U+FE0F 날바이트 `ef b8 8f` 를 붙여요. 이 결과를 `Tui_terminal_text.sanitize_terminal_text` 나 `Masc_tui_keeper_chat_projection.terminal_safe_text` 에 넣으면, 정리기는 이스케이프 끝의 `0` 을 키캡 바탕 글자로 읽고 선택자를 그대로 내보내요. 터미널에는 아무것도 보이지 않아요.
- 직렬화 전 원문 값에서 정리하면 선택자는 `️` 로 보여요. 직렬화가 끼면 글자 맥락이 바뀌어요.
- 필요한 정리기는 이미 있어요. `sanitize_canonical_preview` 는 직렬화기 출력의 문자열 맥락을 따라가요(`lib/tui_terminal_json.mli`). 문제는 함수가 없다는 것이 아니에요. 화면 코드가 직렬화한 문자열을 일반 정리기에도 넣을 수 있다는 것이에요.

## 2. 왜 호출처를 하나씩 고쳐서는 안 되나요

- 2026-11-02 에 다섯 곳을 고쳤어요. 그런데 2026-11-10 #50997 이 같은 꼴을 새로 만들었어요(`bin/masc_tui_lane_addons.ml:955-958`, `pretty_to_string` 뒤 줄마다 `sanitize_terminal_text`).
- 문자열을 받는 API 는 직렬화 결과와 글자를 가르지 못해요. 막을 자리는 타입이에요.
- `lib/tui_*.ml`·`bin/masc_tui*.ml` 에서 `Yojson.Safe` 로 직렬화하는 227곳을 모두 판정했어요. 곳마다의 목록은 부록 A 에 있어요.

| 판정 | 곳 | 파일 | 층 |
|---|---|---|---|
| 표시 아님: 요청 본문, 로그, journal, 해시, 비교 키, 편집기 파일, Keeper 맥락 | 139 | 20 | 바꾸지 않음 |
| 숫자만 직렬화(문자열이 없어 결함이 생기지 않음) | 4 | 2 | 바꾸지 않음 |
| A: `sanitize_canonical_preview`·`document_json` 을 손으로 이음 | 8 | 6 | L0 |
| E: 바이트 예산으로 자른 접두 | 3 | 2 | L0 |
| B: 직렬화 뒤 일반 정리기나 문서 렌더로 넘김 | 36 | 17 | L1 |
| C: 오류·안내 문장 안에 JSON 을 끼움 | 26 | 6 | L2 |
| D: 직렬화 결과를 decode 결과의 문자열 필드나 표시 줄에 담음 | 10 | 5 | L3 부터 |
| F: Yojson.Raw 로 원문 철자를 지키는 표시 | 1 | 1 | §5 결정 뒤 |

## 3. 경계

### 3.1 값을 받는 함수

```ocaml
(* lib/tui_terminal_json.mli *)
val preview : Yojson.Safe.t -> string
(** [Yojson.Safe.to_string] 한 줄을 터미널에 보낼 글자로 바꿔요. *)

val pretty_lines : Yojson.Safe.t -> string list
(** [Yojson.Safe.pretty_to_string] 전체를 정리한 뒤 줄로 나눠요. *)
```

- 직렬화와 정리를 한 함수 안에서 해요. 부르는 쪽은 직렬화한 문자열을 쥐지 않아요.
- 정리는 줄로 나누기 전에 전체에 한 번 걸어요. 잘라 낸 줄 하나만 보면 문자열 안인지 알 수 없어요.
- 결과는 표시용 글자예요. 끝까지 직렬화한 결과는 같은 JSON 값으로 다시 읽혀요. 하지만 원문 바이트는 아니에요. 복사와 해시는 값이나 원문을 따로 써요.

### 3.2 바이트 예산

```ocaml
type layout = Compact | Pretty
type within = Whole of string list | Cut of string list

val source_bytes : layout -> Yojson.Safe.t -> int
val within : layout -> max_bytes:int -> Yojson.Safe.t -> within
```

- 예산은 직렬화기 원문 바이트로 세요. 지금 `bin/masc_tui_render_lanes.ml:1308` 이 세는 방식과 같아요.
- `Pretty` 는 예산 안 마지막 줄바꿈에서 잘라요. 줄바꿈이 없으면 UTF-8 경계에서 잘라요(`render_lanes.ml:1293-1295` 와 같은 규칙). `Compact` 는 UTF-8 경계에서 잘라요(`bin/masc_tui_operator_projection.ml:335`).
- 잘린 접두는 바이트 0 부터 시작해요. 그래서 지금 정리기 계약("a UTF-8-safe prefix starting at byte zero") 안에 들어요.
- `source_bytes` 는 표시 글자를 만들지 않아요. 필드마다 예산을 나누는 `render_lanes.ml` 처럼 자르기 전에 길이만 알아야 하는 곳이 써요.
- 「… truncated, total N bytes」, 「...」 같은 알림 문장은 부르는 쪽이 지금처럼 붙여요. `Whole`·`Cut` 두 경우를 모두 `match` 해요.

### 3.3 문자열 API 를 내리는 조건

- A 8곳과 E 3곳이 §3.1·§3.2 로 옮겨 모듈 밖 호출이 0 이 되면, `sanitize_canonical_preview : string -> string` 을 `.mli` 에서 내려요.
  - `render_lanes.ml:1307` 의 `heading_source` 는 JSON 이에요(`` Yojson.Safe.to_string (`String name) ``, 이름을 JSON 문자열로 직렬화한 값). `within Compact` 와 `source_bytes Compact` 로 옮겨요.
- `bin/masc_tui_render_prim.mli:145` `document_json : width:int -> string -> string list` 도 문자열 대신 `within` 결과나 값을 받게 바꿔요.
- `test/test_tui_terminal_json.ml` 이 문자열 함수를 부르는 6곳은 값 함수로 다시 써요.
- 일반 텍스트 정리기(`Tui_terminal_text.*`, `Masc_tui_keeper_chat_projection.terminal_safe_text`)는 그대로 둬요. 글자를 위한 함수예요.

## 4. D: 문자열 필드를 닫힌 타입으로

한 필드에 글자와 직렬화한 JSON 이 섞이면, 그리는 쪽은 어느 정리기를 걸지 정할 수 없어요. 아래 8개 필드를 나눠요.

| 필드 | 좌표 | 지금 | 바꿀 모양 |
|---|---|---|---|
| 보관 항목 section `Json` | `bin/masc_tui_retained_view.ml:18,30,56`, 원문은 `bin/masc_tui_context_inspector.ml:683` | 직렬화 결과와 원문 텍스트가 `Json of string` 하나 | `Json of Yojson.Safe.t`. 원문은 `sections` 가 이미 파싱한 값 |
| `kc_input` | `lib/tui_decode.ml:2724-2728` | 문자열은 그대로, 나머지는 직렬화 | `Text of string \| Json of Yojson.Safe.t` |
| `kc_output` | `lib/tui_decode.ml:2735-2740` | 같음(option) | 같은 타입의 option |
| runtime param 값 | `lib/tui_decode.ml:4751` | decode 에서 `to_string` | `Yojson.Safe.t` |
| Librarian `actual_input` | `lib/tui_decode.ml:6315` | decode 가 pretty 줄을 만듦 | decode 는 값을 돌려주고, 그리는 쪽이 `pretty_lines` |
| `Preflight_failed` | `lib/tui_decode.ml:6699` | 직렬화 문자열 | 타입 있는 실패 값 |
| `th_note` | `lib/tui_decode_task_inspection.ml:107` | 다른 생산자의 메모 글자(`handoff_context.summary`)와 한 필드 | `Text \| Json` |
| 도구 활동 args | `bin/masc_tui_keeper_chat_history.ml:913` → `make_tool_activity` | 직렬화 문자열 | `Text \| Json` |

- 두 갈래 필드는 한 타입을 같이 써요. `Tui_terminal_json` 옆에 `type payload = Text of string | Json of Yojson.Safe.t` 와 `payload_lines` 를 둬요. `Text` 는 일반 정리기로, `Json` 은 §3.1 로 가요. 어느 정리기를 쓸지는 이 `match` 한 곳에서만 정해요.
- 모두 TUI 메모리 안의 decode 결과예요. 저장 상태 모양은 바뀌지 않아요. 하드컷도 마이그레이션도 없어요.

## 5. F: 정할 것

`bin/masc_tui_render_fusion.ml` 은 주석이 있는 원문은 그대로 그려요(`Fusion_json_original`). 주석이 없으면 `Yojson.Raw` 로 다시 들여 써요. 실수 변환이 큰 지수를 `Infinity` 로 바꾸거나 값을 반올림하지 않게 하려고 일부러 Safe 값을 쓰지 않아요. `:437` 은 제어 문자가 든 문자열 리터럴만 다시 써요.

| 선택지 | 하는 일 | 잃는 것 |
|---|---|---|
| (가) Raw 를 받는 경계 함수를 하나 더 둬요 | `raw_pretty_lines : Yojson.Raw.t -> string list`. Raw 출력도 직렬화기 출력이라 지금 정리기 계약 안에 들어요 | 주석 있는 원문 갈래는 남아요. 원문 리터럴에 이스케이프로 쓴 이모지 바탕은 넘치게 이스케이프돼요(`.mli` 가 적은 차이) |
| (나) Safe 값으로만 그려요 | 경계가 하나로 모여요 | 실수 철자와 주석이 사라져요. 지금 주석이 막으려는 일이 다시 생겨요 |
| (다) 주석 있는 원문은 JSON 이 아니라 글자로 다뤄요 | 일반 정리기로 그려요 | 그 갈래에서는 이 결함(`\u0000` 뒤 선택자)이 남아요 |

## 6. 층 계획

네이티브 스택으로 쌓아요. 층마다 자기 changelog 조각을 넣어요. 층 하나의 작업은 20k token 안으로 둬요. 넘으면 그 층을 둘로 나눠요.

| 층 | 내용 | 범위 | 시험 |
|---|---|---|---|
| L0 | §3.1·§3.2 경계, A 8곳과 E 3곳 옮김, §3.3 문자열 API 내림 | 경계 2파일, 소스 8파일, 시험 1파일 | 경계 함수 |
| L1 | B 36곳을 `preview`·`pretty_lines` 로 옮김 | 17파일 | 새 시험 없음 |
| L2 | C 26곳의 문장 안 JSON 을 `preview` 로 옮김 | 6파일 | 새 시험 없음 |
| L3 부터 | §4 필드마다 한 층(8층) | 필드와 그 소비처 | decode 결과 |
| F | §5 결정 뒤 | 1파일 | (가)면 경계 함수 |

- L0 경계 함수 시험: 키와 값에 U+0000+U+FE0F, C0(탭·ESC), C1(U+0080), 방향 제어(U+202E)를 넣어요. 정상 `❤️`·`👩‍💻`·태그 깃발도 넣어요.
  - 결과에 ESC 를 뺀 제어 바이트가 없고, 정상 순서에 붙은 것 말고 날 `ef b8 8f` 가 없는지 봐요. 정상 순서가 그대로인지도 봐요.
  - 끝까지 직렬화한 결과는 같은 값으로 다시 읽히는지 봐요.
  - `within` 은 예산 0 부터 전체 길이까지 모든 바이트에서 같은 조건을 지키는지 봐요. 예산이 전체 이상이면 `Whole`, 아니면 `Cut` 인지도 봐요.
  - 고치기 전 방식(직렬화 뒤 줄마다 일반 정리기)으로 바꿔 넣으면 이 시험이 실패하는지 확인해요.
- L1·L2 는 부르는 함수만 바꿔요. 바이트는 L0 시험이 지켜요. 화면 행 시험은 만들지 않아요.
- L3 부터는 decode 결과를 봐요. 문자열 값은 `Text`, 아닌 값은 `Json` 으로 나오는지 봐요. 보관 항목은 `sections` 가 값을 담는지 봐요.

## 7. 하지 않는 것

- 표시가 아닌 직렬화 139곳은 바꾸지 않아요.
- 숫자만 직렬화하는 4곳은 그대로 둬요.
- 일반 텍스트 정리기에 JSON 이스케이프를 알아보는 규칙을 넣지 않아요. 글자로 쓴 `\u0000` 과 직렬화가 만든 `\u0000` 은 글자만 보고 가를 수 없어요.
- 소스를 grep 하는 검사기를 만들지 않아요. 같은 꼴이 다시 생기는 것은 값을 들고 다니는 타입과 리뷰로 막아요.
- 화면 문구·배치 시험(PTY 포함)을 만들지 않아요.
- 저장 상태 모양을 바꾸지 않아요.

## 부록 A. 판정 목록

`origin/main` `807a5e46ab99` 에서 `rg -n 'Yojson\.Safe\.(pretty_)?to_string|Yojson\.Safe\.pretty_print|Yojson\.Safe\.to_buffer|Yojson\.Safe\.pp' --glob 'lib/tui_*.ml' --glob 'bin/masc_tui*.ml' lib bin` 이 찾은 227곳이에요. 숫자는 줄 번호예요.

**A** (8)

- `bin/masc_tui_approval_detail.ml`: 407
- `bin/masc_tui_operator_projection.ml`: 151, 154
- `bin/masc_tui_render_activity.ml`: 101, 754
- `bin/masc_tui_render_lanes.ml`: 1959
- `bin/masc_tui_render_work.ml`: 2205
- `bin/masc_tui_tool_detail.ml`: 107

**E** (3)

- `bin/masc_tui_operator_projection.ml`: 332
- `bin/masc_tui_render_lanes.ml`: 1274, 1307

**B** (36)

- `bin/masc_tui_github_identity.ml`: 160
- `bin/masc_tui_keeper_config.ml`: 747, 761, 996
- `bin/masc_tui_lane_addons.ml`: 956, 1002, 2343
- `bin/masc_tui_nested_result.ml`: 3
- `bin/masc_tui_original_task_read.ml`: 164, 227
- `bin/masc_tui_render.ml`: 137
- `bin/masc_tui_render_approvals.ml`: 372, 377, 396
- `bin/masc_tui_render_board.ml`: 59
- `bin/masc_tui_render_chat.ml`: 2693
- `bin/masc_tui_render_config.ml`: 121
- `bin/masc_tui_render_memory.ml`: 447, 1267
- `bin/masc_tui_render_prim.ml`: 6400
- `bin/masc_tui_render_tools.ml`: 278, 625, 725, 1298, 1299
- `bin/masc_tui_resource_document.ml`: 197
- `bin/masc_tui_schema_form.ml`: 171, 178, 182, 299, 303, 332, 336, 361
- `bin/masc_tui_task_document.ml`: 204
- `bin/masc_tui_types.ml`: 23444

**C** (26)

- `bin/masc_tui.ml`: 31998
- `bin/masc_tui_keeper_config.ml`: 542, 827, 838, 843, 846
- `bin/masc_tui_loader.ml`: 798, 864, 1878
- `bin/masc_tui_mcp.ml`: 220, 238
- `bin/masc_tui_schedule_decode.ml`: 30, 39, 55, 59, 71, 75, 307, 315, 332, 336, 357, 365
- `lib/tui_decode.ml`: 3197, 3287, 5691

**D** (10)

- `bin/masc_tui_context_inspector.ml`: 683
- `bin/masc_tui_keeper_chat_history.ml`: 913
- `bin/masc_tui_retained_view.ml`: 18, 30
- `lib/tui_decode.ml`: 2727, 2739, 4751, 6315, 6699
- `lib/tui_decode_task_inspection.ml`: 107

**F** (1)

- `bin/masc_tui_render_fusion.ml`: 437

**숫자만** (4)

- `bin/masc_tui_lane_addons.ml`: 1542
- `bin/masc_tui_render_lanes.ml`: 1853, 1871, 1953

**표시 아님** (139): `masc_tui_http.ml` 60, `masc_tui.ml` 48, `masc_tui_types.ml` 8, `masc_tui_editor_wire.ml` 3, `masc_tui_keeper_control.ml` 3, `masc_tui_mcp.ml` 2, `masc_tui_observer.ml` 2, 그리고 1곳씩인 13파일(`approval_value_reading`, `artifact_share_pending`, `frame_timing`, `input_reader`, `keeper_chat_projection`, `keeper_config`, `lane_broadcast_pending`, `local_read_observation`, `msx_tick`, `nav_trace`, `play_pending`, `render_tools`, `task_document_observation`).
