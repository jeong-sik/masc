---
rfc: "any-runtime-serves-an-exact-lane"
title: "exact lane 은 요구를 채우는 runtime 이면 어느 것이든 맡는다"
status: Draft
created: 2026-10-14
updated: 2026-10-14
author: claude
supersedes: []
superseded_by: null
related: ["cli-runtimes-as-lane-slots", "exact-lane-walks-one-slot-list", "workspace-curator-curates-changed-facts"]
---

# exact lane 은 요구를 채우는 runtime 이면 어느 것이든 맡는다

## 1. 문제

운영자는 2026-10-14 에 이렇게 말했다. 가능한 어떤 runtime 이든 Curator 든 Librarian 이든
맡을 수 있어야 한다.

지금은 runtime 종류마다 맡을 수 있는 lane 이 코드에 따로 정해져 있다. 같은 날 확인한 결과다
(`origin/main` 9e3acecb37 과 24ec99fb27, 2.7 에서 구분한다).

| lane | HTTP 슬롯 | CLI 슬롯 (공식 클라이언트) | Muse Code |
|---|---|---|---|
| librarian_exact | 맡음 | 맡음 (`Keeper_lane_cli_oneshot.walk`) | 못 맡음 (스키마 채널) |
| board_attention_exact | 맡음 | 맡음 (같은 walk) | 못 맡음 (스키마 채널) |
| browser_stagehand_exact | 맡음 | 맡음 (같은 walk) | 못 맡음 (스키마 채널) |
| candle_appraiser | 맡음 (`Exact.execute_flow_once`) | 맡음 (같은 walk) | 못 맡음 (스키마 채널) |
| hitl_auto_judge (`hitl_summary_worker`) | 맡음 | 맡음 (`try_cli_slots`, 같은 `Keeper_lane_cli_oneshot`) | 못 맡음 (스키마 채널) |
| workspace_curator_exact | 맡음 | **못 맡음** (`prepare_execution` 이 거절) | 못 맡음 (스키마 채널) |
| verifier_exact | 맡음 (인라인 도구와 시스템 프롬프트를 받는 binding 만) | **Claude Code 만** (`tools-support` 가 있을 때) | 못 맡음 (도구 억제, 아래) |

verifier 의 Muse 거절은 다른 lane 과 이유가 다르다. `verifier_runtime_admission` 은 Codex,
Antigravity, Muse 를 "native-tool suppression 을 지원하지 않는다"며 거절하고, Muse 는
`muse_none_supported = false`("MSP cannot remove all built-in tools")라서 정말 그렇다. 이쪽은
없애지 않는다(4장).

막힌 이유가 하나가 아니다. 서로 다른 세 가지가 한 덩어리로 보인다.

1. **출력.** Muse Code 는 스키마를 건넬 채널이 없다는 이유로 verifier 를 뺀 어느 lane 에도 못 들어간다.
   그런데 lane 이 스키마 채널을 요구하지는 않는다(2.1).
2. **입력 크기.** Curator 는 CLI 슬롯의 창 크기를 알 수 없다며 구성을 거절한다 (#41391).
3. **걷는 코드.** Curator 만 CLI 슬롯을 걷는 코드가 없다.

## 2. 코드가 이미 보여 주는 것

### 2.1 `Json_syntax` 는 채널이 필요 없고, 모든 lane 이 그것을 쓴다

`Exact_output.minimum_guarantee` 에는 둘이 있다.

- `Json_syntax`: "Prompt-only JSON contract." 프롬프트에 스키마 문장을 붙이고, 응답을 로컬에서
  엄격하게 파싱한다. provider 의 response-format 요청은 보내지 않는다.
- `Provider_schema`: provider 가 스키마를 직접 받는 쪽으로 명시해서 고른다.

`Exact_output` 를 쓰는 호출 지점은 모두 `Json_syntax` 다 (`server_workspace_memory_curator`,
`server_candle_appraiser`, `keeper_librarian_runtime`, `keeper_board_attention_exact_flow`,
`hitl_summary_worker`, `browser_stagehand_model`, 그리고 `bin/masc_lane_cli_probe.ml`).
`Provider_schema` 를 요구하는 곳은 없다.

HTTP 슬롯도 이 보장 수준에서는 프롬프트에 적힌 스키마만으로 돈다. 지금 Curator 가 glm 으로 도는 것이
그 예다. 그러면 스키마 채널이 없는 runtime 을 거절하는 것은 lane 의 요구보다 엄격하다.

### 2.2 Muse 거절은 `output_schema` 를 넘길 때만 일어난다

`Fusion_official_client` 의 muse 분기는 이렇게 생겼다.

- `Muse_serve _ when Option.is_some output_schema` → `Setup_failure`
- `Muse_serve execution` → 정상 실행

그리고 `Keeper_lane_cli_oneshot.run` 은 항상 `~output_schema` 를 runner 에 넘긴다. 스키마를 넘기지
않으면 muse 는 이미 한 번 질문하고 답하는 길(Fusion 패널)로 돌고 있다. 거절은 muse 를 실행하는 길의
한계가 아니라 "스키마를 넘겨야 한다"는 호출 규칙에서 나온다.

`Keeper_lane_cli_oneshot.prompt_with_schema` 의 문서도 Muse Code 를 "모델이 쓴 글을 돌려주는
클라이언트"로 이미 적고 있다.

muse 자체는 스키마를 받을 수 있다. 1.4.7 의 `muse exec --output-schema <FILE>` 이 있고, 도움말에
"meta provider only" 라고 적혀 있다. 반면 masc 가 쓰는 `muse serve` 의 `turn/start` 에는 그 필드가 없다
(바이너리에서 내려받은 스키마로 확인). 이 RFC 는 `exec` 경로를 쓰지 않는다. 4장을 본다.

### 2.3 창 크기를 묻는 함수가 이미 있다

`Runtime.resolve_max_context_of_runtime_id` 와 `Runtime.max_context_of_runtime_id` 는 runtime id 로
유효한 입력 창을 돌려준다. runtime id 의 종류(HTTP 든 CLI 든)를 가리지 않는다. 창 크기는 runtime.toml 의
모델 행 `max-context` 에서 온다.

그런데 `Runtime_exact_output_registry.resolved_lane.cli_slots` 는 `string list` 이다. 창을 모르는 것이
아니라, Curator 가 위 함수를 부르지 않는다.

### 2.4 Curator 는 CLI 슬롯을 걸었다가 걷지 않게 됐다

`git log -S'cli_slots'` 로 `server_workspace_memory_curator.ml` 의 `cli_slots` 문자열이 바뀐 커밋은
#39622("workspace curator 도 다른 lane 처럼 HTTP 다음에 CLI 슬롯을 걸어요")와 #39858("Run Workspace
Curator on bounded changed-fact ledger batches")이다. 지금 코드는 이렇다.

- `prepare_execution` 은 `cli_slots` 가 비어 있지 않으면 `"workspace curator requires exact-output HTTP
  slots"` 로 거절한다.
- `execute_output` 은 `execute_http` 만 부른다.

Curator RFC 의 Q2 는 이 거절을 "창을 알 수 없는 CLI 슬롯은 fail closed" 로 적는다.

### 2.5 입력 크기의 증거는 `Exact` 가 낸다

Curator 코드의 주석: "Exact owns provider admission and size evidence. Curator does not convert a
token window into a byte budget." HTTP 슬롯은 `Exact` 가 입력이 너무 크다는 거절 증거를 내고,
Curator 는 그 거절을 받아 묶음을 줄인다 (`Request.narrow`).

Curator 의 `attempt` 루프는 실패의 **분류** 하나로 다음 상태가 갈린다.

| `execute` 결과 | 다음 상태 |
|---|---|
| 성공 | 장부 저장, 남은 것이 있으면 다음 pulse 가 다시 깨움 |
| `Input_too_large` / `Output_too_large` | `Request.narrow` 로 더 작은 묶음으로 다시 `attempt` |
| `Execution_failed` | 이번 pulse 를 끝냄. 줄이지 않음 |
| `narrow` 가 `Ok None` | `Curation_failed` 로 끝 |

그 분류는 HTTP 슬롯에서 `Exact` 가 낸 크기 증거(`size_refusals`)로만 정해진다. CLI 슬롯은 `Exact`
를 지나지 않아서 그 증거가 없다. 지금 있는 장치는 이렇다.

- Codex 가 입력 초과를 거절하면 `Keeper_lane_cli_oneshot.input_capacity` 로 용량을 돌려준다.
  Codex 모듈은 이 일을 타입으로 구분한다(`Context_window_filled`).
- Claude Code 모듈에도 타입으로 구분된 변이형이 있다(`Context_window_exceeded`). 그런데
  `input_capacity` 는 Codex 만 다루므로, 이 변이형이 lane 의 크기 증거로 이어지지 않는다.
- Antigravity 와 Muse 는 `.mli` 에서 입력 초과를 구분하는 변이형을 찾지 못했다.
- Librarian 은 읽다가 실패한 pass 다음에 한 번에 읽는 폭을 줄인다 (`keeper_librarian_queue_refresh`).

### 2.6 거절된 CLI 슬롯이 "admitted" 로 보인다

`masc_tui_lane_inventory.ml` 은 `admitted_slots` 와 `cli_slots` 의 길이를 더해 "N admitted slots"
로 표시한다. Curator 처럼 실제로는 못 도는 lane 이 도는 것처럼 보인다 (#41391 의 세 번째 항목).

### 2.7 runtime 능력을 보고 슬롯을 거르는 함수가 verifier 에 이미 있다

`Runtime.verifier_runtime_admission`(`runtime.ml`)은 runtime 하나를 받아 "이 runtime 이 completion
review 를 판정할 수 있는가"를 답한다. 조건은 세 가지다.

- 인라인 도구를 받는 binding 일 것 (`Provider_tool_support.provider_supports_inline_tools`)
- 시스템 프롬프트를 받는 모델일 것 (`supports_system_prompt`)
- 네이티브 도구를 억제할 수 있는 클라이언트일 것 (Claude Code 만, `tools-support` 필요)

지금 모양은 #37395 가 만들었다(이슈 #37382). 그 전에는 같은 질문에 함수 둘(`verifier_runtime_admission`,
`verifier_api_slot_ready`)이 따로 답했고, 카탈로그 슬롯은 어느 쪽도 거치지 않았다. 그래서 판정을 못 하는
binding 이 dispatch 까지 갔다가 "리뷰마다 한 번씩 영원히" 거절됐다. #37395 는 두 판정을 이 함수 하나로
합치고 거절을 dispatch 앞으로 옮겼다. 이 RFC 가 제안하는 `admits` 는 새 발명이 아니라 이 모양을 모든
lane 으로 넓히는 것이다.

지금 admission 은 두 곳에 있다. verifier 는 이 함수로, 나머지 lane 은 `api_format` 에서
(`exact_slot_list_admitting`, `runtime.ml`)다. 둘이 서로 모르는 채 따로 바뀌면 어긋난다.

## 3. 제안

### 3.1 lane 은 요구를 선언하고, runtime 은 능력을 갖고, 맡는지는 계산한다

lane 마다 코드에 닫힌 타입으로 요구를 둔다. 설정 문자열이 아니다. 요구는 셋이다.

```ocaml
type window_requirement =
  | Window_not_needed
  | Window_at_least of int
      (* 이 lane 이 입력을 줄여 갈 수 있는 가장 작은 유효 입력. Curator 라면 Request.narrow 의 하한.
         알려진 창이 이보다 작으면 publication 때 Window_too_small 로 거절한다 *)

type overflow_requirement = Overflow_any | Overflow_must_be_typed
  (* 입력이 너무 크다는 거절을 타입으로 구분해 돌려주는 클라이언트만 받는다 (3.4) *)

type verdict_requirement = Verdict_as_text | Verdict_by_inline_tool
```

runtime 의 능력은 runtime 자체가 아니라 **호출 인자를 만드는 launch profile** 에서 계산한다.
"admits 는 통과인데 실행 때 도구가 없다"가 생기지 않게 하려는 것이다.

```ocaml
type window_capability   = Window_known of int | Window_unknown
type overflow_capability = Overflow_typed | Overflow_untyped
type verdict_capability  =
  { inline_tools : bool; system_prompt : bool; native_tool_suppression : bool }
  (* verifier_runtime_admission 의 세 조건 *)
```

맡을 수 있는지는 함수 하나가 정한다.

```ocaml
val admits : lane:lane_requirement -> runtime:runtime_capability -> (unit, refusal) result
```

모든 조합을 `match` 로 적고 와일드카드를 쓰지 않는다. 새 변이형이 생기면 컴파일이 멈춘다.
`verifier_runtime_admission` 은 `admits` 의 verdict 부분이 되어 사라지고, `api_format` 으로 거르던
admission 도 `admits` 로 바뀐다(7장).

### 3.2 출력: 스키마 채널은 판정에 쓰지 않는다

`admits` 는 runtime 이 스키마 채널을 가졌는지 보지 않는다. 답을 JSON 으로 받아 로컬에서 엄격하게
파싱하고 소비자가 검증하는 것은 지금과 같다. 프롬프트에 스키마 문장이 붙는 것도 같다.

바뀌는 것은 호출 때 `output_schema` 를 넘기는 조건 하나다. 채널이 있는 runtime(Claude Code,
Codex, Antigravity)에는 지금처럼 채널로도 스키마를 건넨다. 답이 그 모양을 지키게 하는 보강이다.
채널이 없는 runtime(Muse Code)에는 `None` 을 넘기고, 그 runtime 은 HTTP 슬롯이 `Json_syntax` 에서
받는 것과 같은 보장(프롬프트 문장과 로컬 파싱)만 받는다. 채널은 보강이지 입장 조건이 아니다.

같은 lane 안에서 슬롯마다 `output_schema` 가 있고 없고가 갈리므로, walk 의 슬롯별 실패 사유에
"스키마 채널을 썼는가" 한 필드를 남긴다. 그래야 9장 Q2 의 실패율을 채널 유무별로 잴 수 있다.

provider 의 스키마를 꼭 요구하는 lane 이 생기면 그때 요구 타입을 하나 더하고 `admits` 에 한 칸을
추가한다. 지금은 그런 lane 이 없다.

### 3.3 입력: CLI 슬롯의 창을 알고, 거절을 값으로 남긴다

`cli_slots` 는 설정에서도 와이어에서도 지금처럼 문자열 배열이다. 값 타입으로 바꾸지 않는다.
`cli_slots : string list` 를 직접 선언하거나 읽는 곳이 `browser_stagehand_model`,
`hitl_summary_worker`, `keeper_board_attention_exact_flow`, `dashboard_gate`, 두 probe 실행 파일,
TUI 의 와이어 해석(`masc_tui_exact_activity`, `masc_tui_types`, `masc_tui_keys`)까지 퍼져 있고,
값 타입으로 바꾸면 이들이 전부 바뀐다.

대신 `resolved_lane` 에 필드 하나를 더한다.

```ocaml
refused_cli_slots : (string * refusal) list   (* admits 가 거절한 CLI 슬롯과 이유 *)
```

`cli_slots` 는 **admitted 만** 담는다. `Browser_stagehand_model` 이 이미 `refused_slots` 를 따로 갖는
것과 같은 모양이다. 그러면 TUI 가 "admitted" 를 잘못 세는 문제(2.6)는 값 타입 변경 없이 풀린다.

- **창은 저장하지 않는다.** `Runtime.max_context_of_runtime_id` 를 publication 때(admission)와
  walk 때(묶음 크기) 각각 묻는다. 슬롯에 창을 싣고 runtime.toml 이 다시 읽히면 어긋날 수 있다.
  Curator 는 이미 run 마다 `Runtime_exact_output_registry.current ()` 를 새로 읽으므로, 낡은 창이
  남는 범위는 진행 중인 run 하나다.
- **창은 publication 의 일부다.** 모델 행의 `max-context` 가 바뀌면 publication generation
  (`catalog_generation`)이 바뀌어야 한다. 지금 그렇게 묶여 있는지는 읽지 못했다(9장 Q10).
- **inventory 는 계산을 다시 하지 않는다.** TUI 가 lane 의 요구를 알고 직접 세면 TUI 와 서버의
  빌드가 다를 때 답이 갈린다. `admits` 의 결과(슬롯마다 admitted 또는 거절 이유)를 publication
  JSON 에 싣고 TUI 는 그것을 세기만 한다.
- **거절의 단위.** 거절된 슬롯만 빼고 lane 은 남는다. admitted 슬롯이 하나도 없으면 그때
  lane 전체가 `No_admitted_lane_slots` 다. Curator 의 `configured ()` 는 이 상태를 "켜짐"이 아니라
  "맡을 슬롯 없음"으로 답해야 한다. 지금 `configured ()`
  (`server_workspace_memory_curator.ml`)는 `Ok _` 와 `No_admitted_lane_slots` 를 모두 `true` 로
  센다. 슬롯만 거절하는 쪽으로 가면 HTTP 슬롯 없이 창 모르는 CLI 슬롯만 있는 lane 에서 Curator 가
  "켜져 있는데 맡을 슬롯이 없는" 상태가 되어 매 wake 마다 실패한다.

| 상태 | lane | `configured ()` | inventory |
|---|---|---|---|
| admitted 슬롯 1개 이상 | 켜짐 | 켜짐 | admitted 만 센다. 거절된 슬롯은 이유와 함께 따로 보인다 |
| admitted 슬롯 0개, 거절된 슬롯 있음 | `No_admitted_lane_slots` | 맡을 슬롯 없음 | 0개, 거절 이유가 보인다 |
| 슬롯 선언 없음 | 선언 안 됨 | 꺼짐 | 선언 안 됨 |

**바이트 환산과 봉투 예약.** 환산은 Curator 에 넣지 않는다. Curator 코드의 원칙("Curator does not
convert a token window into a byte budget")을 지킨다. 환산과 예약은 `Keeper_lane_cli_oneshot` 쪽에
한 곳을 두고 모든 lane 이 같이 쓴다. 예약분은 클라이언트가 붙이는 시스템 프롬프트와 도구 정의의
크기이고, 이것은 우리가 만드는 호출 인자가 정한다. 그래서 재지 않고 **launch profile 을 고정한 뒤
(client family, profile) 에 상수를 붙인다.** 상수를 잰 클라이언트 버전은 테스트 fixture 에 적어서,
버전이 바뀌면 다시 재게 한다. 상수는 보수적으로 잡는다.

### 3.4 Curator 가 CLI 슬롯을 걷는다

**걷는 순서.** Curator 가 `Keeper_lane_cli_oneshot.walk` 를 HTTP 슬롯이 모두 실패한 뒤에 부른다.
다른 lane 과 같은 순서다.

**묶음 크기.** 걷게 될 모든 슬롯 중 가장 작은 `창 − 출력 예산 − 예약` 에 맞춘다. Curator RFC 의
Q2("가장 작은 값")를 CLI 슬롯까지 넓힌 것이다. 가장 작은 값을 고르는 이유는 예의상이 아니다.
`attempt` 는 provider 를 부르기 전에 묶음 전체를 run 기록에 내구 저장한다("Durable exact input
precedes every provider call"). HTTP 슬롯과 CLI 슬롯이 크기가 다른 묶음을 받으면 run 하나에 입력이
둘이 되어 "run 하나 = 입력 하나" 불변식이 깨진다. 누가 "HTTP 는 크게, CLI 만 작게"로 바꾸려 하면
무엇이 깨지는지는 이 문장이 보여 준다. 대신 호출 수가 늘어나는 비용이 든다(6장).

**크기 증거는 한 곳에 모은다.** CLI 슬롯이 입력 초과를 타입으로 돌려주면 HTTP 의 `size_refusals`
와 같은 칸에 모아서 분류한다. 둘을 따로 들면 분류가 HTTP 증거만 보게 되어, HTTP 가
`Execution_failed` 이고 CLI 가 크기 초과로 거절한 경우에 묶음이 줄지 않는다. 이를 위해
`Keeper_lane_cli_oneshot` 에 `refused_for_binding_rest` 옆으로 `refused_for_input_size :
failure -> bool` 를 둔다. Claude Code 의 `Context_window_exceeded` 와 Codex 의
`Context_window_filled` 가 여기로 이어진다.

**타입 없는 초과를 어떻게 다루나.** CLI 슬롯이 입력 초과를 타입 없는 실패로 내면 지금 분류는
`Execution_failed` 이다. 그러면 `narrow` 를 타지 않고 pulse 가 끝나고, 다음 pulse 의
`Request.prepare` 는 같은 장부에서 같은 크기의 묶음을 다시 만들 것으로 보인다(리뷰의 추정, 내가
`prepare` 본문을 읽지는 않았다). HTTP 가 한도나 장애로 모두 실패한 동안 CLI 가 창 초과로 실패하면,
매 wake 마다 같은 run 이 같은 이유로 실패하고 끝나지 않는다. Librarian 에서 한 번 있었던 일이다
(`12756 -> 6378 -> 3189` 를 96번 걷고 아무것도 커밋하지 못함, #37793).

두 가지 길이 있다. **이 RFC 는 A 를 따른다.** 운영자가 2026-10-14 에 A 로 정했다(제안에 "오케이").

| | 내용 | 얻는 것 | 잃는 것 |
|---|---|---|---|
| **A (기본)** | 입력 크기에 묶인 lane 은 `Overflow_must_be_typed` 를 요구한다. 타입 있는 초과를 내는 클라이언트(Claude Code, Codex)만 그 lane 의 CLI 슬롯으로 받는다 | 순환이 원천에 없다. 분류에 휴리스틱이 없다 | Antigravity 와 Muse 는 Curator 의 CLI 슬롯에 못 들어간다. 그 클라이언트가 타입 있는 초과를 내게 될 때까지 |
| B | 타입 없는 CLI 실패를 보수적으로 크기 초과로 취급한다. 한 번이라도 CLI 슬롯을 시도한 뒤 타입 없는 실패가 남으면 `narrow` 를 한 번 더 타고, `narrow` 가 `None` 이면 끝낸다 | "어떤 runtime 이든"에 더 가깝다 | 진짜 크기 문제가 아닌 실패(한도, 장애, 잘못된 JSON)에서 호출이 묶음 크기의 log2 번 늘고 매번 프로세스를 띄운다. 분류가 사실보다 낙관적이다 |

B 는 "증상을 억누르는" 규칙이다. 따르지 않는 이유다. A 의 대가는 Antigravity 와 Muse 가 이
lane 에서 빠지는 것이고, 운영자가 말한 "어떤 runtime 이든"과 어긋나는 부분이다. 이 어긋남은 두
클라이언트가 입력 초과를 타입 있는 실패로 내게 되는 날 풀린다. 그때 A 의 조건은 저절로
그 클라이언트를 받아들인다(9장 Q4 가 그 확인이다).

**이 RFC 가 다루는 범위.** `attempt` 루프 중 분류(classification) 쪽이다. briefing 쪽 루프는
`Output_too_large` 를 줄이지 않고 끝내는 등 규칙이 조금 다르다. 같은 `execute_http` 와 walk 경로를
타게 되는지는 아직 읽지 못했다(9장 Q9).

**성공했을 때의 기록.** CLI 슬롯으로 성공하면 응답에 토큰 사용량이 없다
(`Keeper_lane_cli_oneshot.walk` 문서). run 기록의 `usage` 는 비게 된다.

## 4. 하지 않는 것

- **요구를 못 채우는 조합은 그대로 거절한다.** "어떤 runtime 이든"은 요구를 채우는 runtime 이면
  어느 것이든, 라는 뜻이다. verifier 의 판정은 인라인 도구, 시스템 프롬프트, 네이티브 도구 억제를
  모두 가진 클라이언트만 맡는다. Muse 는 `muse_none_supported = false` 라서 지금은 맡을 수 없다.
- **맡을 수 있다는 것은 잘한다는 뜻이 아니다.** 말이 많은 클라이언트는 엄격한 파싱에서 자주
  실패할 수 있다. 측정하기 전에는 기본 순서의 앞에 두지 않는다.
- **`muse exec --output-schema` 경로를 새로 만들지 않는다.** 새 실행 경로를 만드는 일이고, 효과는
  답이 스키마를 지키게 하는 보강에 그친다. 필요하다고 판단되면 별도 RFC 로 한다.
- **슬롯 목록을 하나로 합치는 일은 하지 않는다.** `exact-lane-walks-one-slot-list` 가 다룬다. 이 RFC 의
  `admits` 는 목록 구조와 무관하게 쓸 수 있다.
- **구독 계정의 이용 조건은 판단하지 않는다.** 구독형 클라이언트로 lane 트래픽을 흘려도 되는지는
  운영자가 정한다.
- **라이브 `runtime.toml` 은 건드리지 않는다.**

## 5. 대안

| 대안 | 왜 아닌가 |
|---|---|
| 지금처럼 runtime 종류마다 lane 목록을 코드에 적는다 | runtime 이 늘 때마다 lane 수만큼 고친다. 이번에 보인 세 가지 막힘이 그 결과다 |
| Muse 쪽 MSP `turn/start` 에 필드를 더해 달라고 요청한다 | 우리 통제 밖이다. 요청은 따로 할 수 있지만 기다릴 수 없다 |
| Muse 만 예외로 `output_schema` 를 `None` 으로 넘긴다 | 같은 막힘이 다음 runtime 에서 되풀이된다. 요구와 능력으로 나누는 쪽이 한 번에 끝난다 |
| Curator 의 CLI 거절을 없애고 창을 문자열 id 에서 다시 찾는다 | 거절이 publication 에 보이지 않고 inventory 가 계속 틀린다 |
| `cli_slots` 를 `{ runtime_id; context_window; envelope_reserve }` 값으로 바꾼다 | 소비자가 열 곳 넘게 바뀌고, 슬롯에 창을 저장하면 runtime.toml 재독 뒤 어긋난다. `refused_cli_slots` 한 필드로 같은 문제가 풀린다 |

## 6. 비용과 위험

- 채널이 없는 runtime 은 비 JSON 답이 오면 walk 가 다음 슬롯으로 넘어간다. 슬롯마다 호출이
  한 번 낭비된다.
- 프로세스를 띄우는 비용이 호출마다 든다. `cli-runtimes-as-lane-slots` 의 비용 절을 따른다.
- 사용량이 기록되지 않으므로 provider 사용량 창에서 이 호출을 가려낼 수 없다.
- Curator 가 CLI 슬롯으로 넘어갈 때 묶음이 창 쪽으로 줄어, 같은 밀린 분량이 더 많은 호출로
  나뉜다. 가장 작은 창에 맞추는 대가다.
- **관측이 HTTP 쪽에만 있다.** `Runtime_exact_lane_backpressure.observe` 는 HTTP flow 만 본다.
  CLI 슬롯의 연속 실패와 쉼은 그 쪽에 쌓이지 않아, 매 run 에서 같은 CLI 슬롯을 끝까지 다시 걷게
  된다. CLI 슬롯의 실패와 쉼이 어디에 기록되는지 정해야 한다(9장 Q9).
- **입력 상한이 창만이 아닐 수 있다.** 리뷰가 인용한 Claude Code 문서에는 `claude -p` 에 파이프로
  넣는 입력이 10MB 로 막혀 있다고 한다. 내가 문서를 직접 확인하지는 못했다. 사실이면 9.4MB 입력
  사고(구 Curator 의 `1261 Prompt exceeds max length` 83회)와 같은 종류의 입력은 창 계산 이전에
  실패한다(9장 Q1).

## 7. 나눠 올리는 순서

이 RFC 가 병합된 뒤의 구현이다. 스택 하나로 올리고 맨 위 PR 로 한 번에 병합한다.

1. **admission 을 한 곳으로.** 요구와 능력 타입, `admits`, 조합표 테스트. 그리고 지금 `api_format` 과
   verifier 에 흩어진 admission 을 `admits` 로 바꾼다. 같은 판단을 쓰는 곳이 모두 대상이다.
   - `exact_slot_list_admitting`
   - `exact_lane_cli_slot_gaps`
   - `exact_slot_list_of_new_slot` (lane 인자가 없으므로 lane 쓰기 경로, 곧 TUI 와 CLI 편집 쪽의
     시그니처가 바뀐다)
   - `no_output_schema_channel_refusal` (문구가 "every exact-output call hands its client a JSON
     Schema" 라서 3.2 이후에는 사실이 아니다)
   - `set_first_run_runtime` 의 `None -> [], []` 갈래 ("Muse 는 어느 슬롯에도 쓰이지 않고 기본이 된다")
   - `verifier_runtime_admission`
   이것을 명시하지 않으면 admission 이 채널 기준과 요구×능력 기준 두 곳에 남아 서로 어긋난다.
   이 단계에서 Muse 가 `Json_syntax` lane 에 들어간다. `Keeper_lane_cli_oneshot.run` 이 `output_schema`
   를 넘기거나 넘기지 않는다. Curator 의 `configured ()` 가 admitted 슬롯 0개에서 "맡을 슬롯 없음"으로 답하게
   여기서 고친다.
2. **거절을 값으로.** `resolved_lane` 에 `refused_cli_slots` 를 더하고 `cli_slots` 를 admitted 만으로
   좁힌다. publication JSON 에 `admits` 결과를 싣고 TUI inventory 는 그것을 세기만 한다.
   `Window_at_least` 로 `Window_too_small` 거절이 publication 에서 나온다.
3. **Curator 가 CLI 슬롯을 걷는다.** `refused_for_input_size`, 크기 증거를 한 칸에 모으기, 가장 작은 창에
   맞춘 묶음 크기, 3.4 의 선택(A 또는 B)에 따른 분류.

각 PR 은 자기 테스트를 가진다.

## 8. 검증

- **조합표.** `admits` 의 모든 (요구 × 능력) 칸을 테스트한다. 와일드카드가 없으므로 새
  변이형은 컴파일로 잡힌다.
- **admission 단일 출처.** 1단계 뒤에 `api_format` 기준으로 거르는 코드가 남지 않았음을 `rg` 로
  확인하는 테스트나 점검을 둔다.
- **Muse.** `Window_not_needed` · `Verdict_as_text` lane 이 Muse 를 맡는다. runner 가 받는
  `output_schema` 는 `None` 이고, 채널이 있는 runtime 은 같은 lane 에서 스키마를 받는다.
  verifier 는 여전히 Muse 를 거절한다.
- **verdict 능력은 argv 와 같은 값에서 나온다.** `admits` 가 Ok 인 runtime 의 호출 인자에 그 lane 이
  요구하는 도구 구성이 실제로 들어 있음을 단언한다.
- **Curator, CLI 슬롯.** 가짜 runner 로 HTTP 슬롯 전부 실패 → CLI 슬롯 성공 → 장부 갱신.
  CLI 슬롯이 JSON 이 아닌 답을 내면 walk 가 넘어가고, 모두 실패하면 슬롯별 실패 목록이 남는다.
- **크기 증거 합치기.** HTTP 가 `Execution_failed` 이고 CLI 가 타입 있는 크기 초과를 내면 묶음이
  줄어든다. 3.4 에서 A 를 고르면, 타입 없는 초과를 내는 클라이언트는 Curator 의 CLI 슬롯으로
  admitted 되지 않는다. B 를 고르면 `narrow` 가 `None` 에서 끝나고 호출 수가 묶음 크기의 log2
  이하임을 단언한다.
- **창이 작은 슬롯.** `Window_at_least` 보다 작은 창은 publication 에서 `Window_too_small` 로
  거절되고, `refused_cli_slots` 에 이유가 남는다.
- **inventory.** 거절된 슬롯은 admitted 로 세지 않는다. TUI 는 publication 결과만 읽는다.
- **묶음 크기.** 창이 다른 두 슬롯이 있으면 작은 쪽에 맞는다. run 기록의 입력이 하나다.
- **변이 검사.** `admits` 가 채널 없는 runtime 을 거절하게 바꾸면 Muse 케이스가 실패한다.
  묶음 크기에서 `min` 을 `max` 로 바꾸면 크기 케이스가 실패한다. `refused_cli_slots` 를 `cli_slots`
  에 합치면 inventory 케이스가 실패한다.
- **라이브.** 한 lane 의 뒤쪽에 CLI 슬롯 하나를 두고 하루 관찰한 뒤 넓힌다. 어느 lane 인지는
  운영자가 정한다.

## 9. 열린 질문

- **Q1. 봉투 예약분과 입력 상한.** 3.3 의 방향은 launch profile 을 고정하고 (client family,
  profile) 에 보수적 상수를 붙이는 것이다. 정해야 할 것은 상수의 값이다. 리뷰가 인용한 문서에 따르면
  Claude Code 의 `--bare` 는 OAuth 자격 증명을 읽지 않아 구독 로그인 CLI 슬롯에서 쓸 수 없고, `-p` 의
  파이프 입력은 10MB 로 막혀 있다. 둘 다 내가 직접 확인하지는 못했다. 바이트 상한이 사실이면
  `admits` 가 창과 함께 lane 의 최대 입력 바이트도 받아야 하는지 정해야 한다.
- **Q2. 말이 많은 클라이언트의 엄격 파싱.** Agent Core 는 코드 펜스를 벗기지 않는다. CLI 클라이언트가
  응답에 설명을 덧붙이면 실패율이 올라간다. 3.2 에서 남기는 "스키마 채널 사용 여부" 필드로 채널
  유무별 실패율을 재고, 그 뒤에 규칙을 바꾸지 말고 슬롯 순서로 푼다.
- **Q3. muse 로 Curator 의 출력 모양을 지키게 할 수 있는가.** 2026-10-14 에 muse 1.4.7 의
  `muse exec` 로 Curator 프롬프트(가짜 사실 3개, 4,642바이트)와 스키마 문장을 모델
  `muse-spark-1.3` 에 3번 보냈다. 3번 모두 lane 과 같은 엄격 규칙(코드 펜스 제거 없음, 필드 정확히
  일치, 사실마다 정확히 한 번)을 통과했다. 소요는 17~59초였다. 분류 내용은 매번 달랐다. 같은 뜻의
  두 사실은 세 번 모두 같은 주장이나 같은 충돌로 묶였고, 반대되는 사실을 충돌로 잡지 못한 시도가
  한 번 있었다.
  한계: 사실 3개짜리 합성 입력, 모델 하나, 시도 3번이다. masc 가 실제로 쓰는 `muse serve` 경로가
  아니라 `exec` 였고, 실제 배치(약 59만 토큰)는 시험하지 않았다. 세션 내구성(`Session_not_durable`)과
  lane 의 시간 한도에 맞는지도 읽지 못했다. 이 결과는 "프롬프트 문장만으로 모양을 지키는가"에 대한
  것이고, 분류의 질을 다른 runtime 과 견준 것은 아니다.
- **Q4. 입력 초과 거절의 모양.** 부분적으로 답했다(2.5). Claude Code 와 Codex 는 타입으로
  구분한다. Antigravity 와 Muse 는 `.mli` 에서 찾지 못했다. 이 둘이 실제로 어떤 실패로 돌려주는지는
  읽지 않았다. 이 답이 3.4 의 A 와 B 중 무엇이 의미 있는지를 정한다.
- **Q5. 요구를 코드에 두는 것이 맞는가.** 닫힌 변이형으로 두는 것을 권한다. lane 이 많지 않고
  요구가 바뀌면 코드 리뷰를 거쳐야 하기 때문이다. 설정으로 열어 두면 lane 마다 운영자가 다르게
  적을 수 있다.
- **Q6. 일회성 실행의 도구 권한.** 읽은 것: 클라이언트별 기본 posture 는 Claude Code 가
  `Native_none`, Codex·Antigravity·Muse 가 `Native_read` 이다(`runtime_native_tools.ml`). 읽기용
  내장 도구를 가진 클라이언트가 lane 호출에서 어느 작업 폴더를 보는지는 읽지 않았다. Fusion 은
  antigravity 에 비공개 작업 폴더를 주는데, lane 호출도 같은지 확인해야 한다. 이 질문은 3.1 에서
  능력을 launch profile 로 계산하는 이유와 같은 곳에 닿아 있다.
- **Q7. 타입 없는 초과의 정책.** 정했다. 3.4 의 A(타입 있는 초과를 내는 클라이언트만 받는다)로
  간다. 운영자가 2026-10-14 에 제안 A 에 "오케이"라고 답했다. 이 결정의 대가(Antigravity 와 Muse 가
  Curator 의 CLI 슬롯에서 빠진다)를 알고 한 선택이라고 읽었는지는 확인하지 못했다. 되돌리려면
  B 를 제거 조건과 함께 다시 제안한다.
- **Q8. 사실 한 건이 가장 작은 창보다 클 때.** 가장 작은 창에 맞춘 `prepare` 가 "예산을 넘는 한 건"을
  어떻게 다루는지 읽지 못했다. 그 한 건에서 lane 전체가 영구히 멈추면, HTTP 는 맡을 수 있는데도
  CLI 때문에 멈추는 일이다. 그 묶음에서만 CLI 슬롯을 빼고 HTTP 만 걷는 탈출구가 필요한지 정해야
  한다.
- **Q9. briefing 루프와 CLI 슬롯의 관측.** briefing 쪽 루프가 같은 walk 경로를 타는지, CLI 슬롯의
  연속 실패와 쉼이 backpressure 말고 어디에 기록되는지 정해야 한다.
- **Q10. 창 변경이 publication 을 바꾸는가.** `max-context` 변경이 publication generation 을 바꾸는지
  읽지 못했다. 묶여 있지 않으면 낡은 창이 다음 재시작까지 간다. 3.3 의 요구("바뀌어야 한다")가
  이미 만족되는지, 아니면 이 RFC 가 고쳐야 하는지 확인한다.

## 10. 참고한 것

2.7 과 verifier, HITL 칸은 `origin/main` 24ec99fb27 에서, 나머지는 9e3acecb37 에서 읽었다. 같은
함수의 본문이 두 시점 사이에 바뀌었는지는 비교하지 않았다.

- `packages/agent_core/lib/llm_provider/exact_output.mli`: `minimum_guarantee`, `Json_syntax`.
- `lib/keeper/keeper_lane_cli_oneshot.mli`: `runner`, `run`, `walk`, `prompt_with_schema`,
  `input_capacity`, `refused_for_binding_rest`.
- `lib/fusion/fusion_official_client.ml`: muse 분기의 `output_schema` 조건.
- `lib/runtime/runtime_schema.ml`: `output_schema_channel`, `api_format_output_schema_channel`.
- `lib/runtime/runtime.ml`: `exact_slot_list_admitting`, `verifier_runtime_admission`,
  `verifier_cli_slot_admission`.
- `lib/runtime/runtime.mli`: `resolve_max_context_of_runtime_id`, `max_context_of_runtime_id`.
- `lib/runtime/runtime_exact_output_registry.mli`: `resolved_lane.cli_slots`.
- `lib/runtime/runtime_claude_code.mli` (`Context_window_exceeded`),
  `lib/runtime/runtime_codex_app_server.mli` (`Context_window_filled`),
  `lib/runtime/runtime_native_tools.ml` (클라이언트별 기본 posture, `muse_none_supported`).
- `lib/server/server_workspace_memory_curator.ml`: `prepare_execution`, `execute_http`,
  `execute_output`, `classify` 의 `attempt`.
- `lib/keeper/hitl_summary_worker.ml`: `lane_id`, `try_cli_slots`.
- `bin/masc_tui_lane_inventory.ml`: admitted 계수.
- `docs/rfc/RFC-cli-runtimes-as-lane-slots.md`, `docs/rfc/RFC-exact-lane-walks-one-slot-list.md`,
  `docs/rfc/RFC-workspace-curator-curates-changed-facts.md` (Q2).
- Issue #41391, #37382, #37793. PR #39622, #39858, #37395.
- 이 PR 의 리뷰 댓글: context-reviewer 의 상태 흐름 의견(`attempt` 루프, 크기 증거, 가장 작은 창의
  이유, publication 의 낡은 상태)과 ocaml-agent-ic 의 타입 설계 의견(admission 교체 목록,
  `Window_at_least`, `cli_slots` 영향 범위, 봉투 예약). 두 댓글 모두 판정이 아니고, 그들이 읽지 않았다고
  밝힌 곳은 위에서 "읽지 못함"으로 옮겼다.
- muse 1.4.7: `muse exec --help`, `muse schema generate-json-schema`.
