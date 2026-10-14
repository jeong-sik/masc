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
(`origin/main` 9e3acecb37).

| lane | HTTP 슬롯 | CLI 슬롯 (공식 클라이언트) | Muse Code |
|---|---|---|---|
| librarian_exact | 맡음 | 맡음 (`Keeper_lane_cli_oneshot.walk`) | 못 맡음 |
| board_attention_exact | 맡음 | 맡음 (같은 walk) | 못 맡음 |
| browser_stagehand_exact | 맡음 | 맡음 (같은 walk) | 못 맡음 |
| candle_appraiser | 맡음 (`Exact.execute_flow_once`) | 맡음 (같은 walk) | 못 맡음 |
| workspace_curator_exact | 맡음 | **못 맡음** (`prepare_execution` 이 거절) | 못 맡음 |
| verifier_exact | 맡음 | 맡음 (`cli_slots`, 판정은 tool call 이라고 `cli-runtimes-as-lane-slots` 가 적음. 걷는 코드는 읽지 못함) | 못 맡음 |
| hitl_auto_judge | 읽지 못함 | 읽지 못함 | 못 맡음 |

`hitl_summary_worker` 도 `Keeper_lane_cli_oneshot.run` 으로 CLI 슬롯을 걷는다. 이 worker 가
`hitl_auto_judge` lane 과 같은 것인지는 읽지 못했다. "못 맡음" 열은 `exact_slot_list_admitting`
이 Muse 를 어느 목록에도 넣지 않는 것에서 나온 결과다.

이유가 하나가 아니다. 서로 다른 세 가지가 한 덩어리로 막혀 있다.

1. **출력.** Muse Code 는 스키마를 건넬 채널이 없다는 이유로 어느 lane 에도 못 들어간다.
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
`hitl_summary_worker`, `browser_stagehand_model`). `Provider_schema` 를 요구하는 lane 은 없다.

HTTP 슬롯도 이 보장 수준에서는 프롬프트에 적힌 스키마만으로 돈다. 지금 Curator 가 glm 으로 도는 것이
그 예다. 그러면 스키마 채널이 없는 runtime 을 거절하는 것은 lane 의 요구보다 엄격하다.

### 2.2 Muse 거절은 `output_schema` 를 넘길 때만 일어난다

`Fusion_official_client` 의 muse 분기는 이렇게 생겼다.

- `Muse_serve _ when Option.is_some output_schema` → `Setup_failure`
- `Muse_serve execution` → 정상 실행

그리고 `Keeper_lane_cli_oneshot.run` 은 항상 `~output_schema` 를 runner 에 넘긴다. 스키마를 넘기지
않으면 muse 는 이미 한 번 질문하고 답하는 길(Fusion 패널)로 돌고 있다. 거절은 muse 를 실행하는 길의 한계가
아니라 "스키마를 넘겨야 한다"는 호출 규칙에서 나온다.

`Keeper_lane_cli_oneshot.prompt_with_schema` 의 문서도 Muse Code 를 "모델이 쓴 글을 돌려주는
클라이언트"로 이미 적고 있다.

muse 자체는 스키마를 받을 수 있다. 1.4.7 의 `muse exec --output-schema <FILE>` 이 있고, 도움말에
"meta provider only" 라고 적혀 있다. 반면 masc 가 쓰는 `muse serve` 의 `turn/start` 에는 그 필드가 없다
(바이너리에서 내려받은 스키마로 확인). 이 RFC 는 `exec` 경로를 쓰지 않는다. 4장을 본다.

### 2.3 창 크기를 묻는 함수가 이미 있다

`Runtime.resolve_max_context_of_runtime_id` 와 `Runtime.max_context_of_runtime_id` 는 runtime id 로
유효한 입력 창을 돌려준다. runtime id 의 종류(HTTP 든 CLI 든)를 가리지 않는다. 창 크기는 runtime.toml 의
모델 행 `max-context` 에서 온다.

그런데 `Runtime_exact_output_registry.resolved_lane.cli_slots` 는 `string list` 이다. runtime id 문자열
만 싣는다. 창을 모르는 것이 아니라, 그 목록이 창을 나르지 않고, Curator 가 위 함수를 부르지 않는다.

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

CLI 슬롯은 `Exact` 를 지나지 않는다. 그래서 CLI 슬롯에서는 그 증거가 없다. 지금 있는 장치는 둘이다.

- Codex 가 입력 초과를 거절하면 `Keeper_lane_cli_oneshot.input_capacity` 로 용량을 돌려준다.
- Librarian 은 읽다가 실패한 pass 다음에 한 번에 읽는 폭을 줄인다 (`keeper_librarian_queue_refresh`).

Claude Code, Antigravity, Muse 가 입력 초과를 어떤 모양으로 거절하는지는 읽지 못했다.

### 2.6 거절된 CLI 슬롯이 "admitted" 로 보인다

`masc_tui_lane_inventory.ml` 은 `admitted_slots` 와 `cli_slots` 의 길이를 더해 "N admitted slots"
로 표시한다. Curator 처럼 실제로는 못 도는 lane 이 도는 것처럼 보인다 (#41391 의 세 번째 항목).

## 3. 제안

### 3.1 lane 은 요구를 선언하고, runtime 은 능력을 갖고, 맡는지는 계산한다

lane 마다 코드에 닫힌 타입으로 요구를 둔다. 설정 문자열이 아니다. 요구는 둘뿐이다.

```ocaml
type input_requirement   = Window_must_be_known | Window_not_needed
type verdict_requirement = Verdict_as_text | Verdict_by_tool_call
```

runtime 의 능력은 이미 코드에 있는 `api_format` 과 `execution` 에서 계산한다.

```ocaml
type window_capability  = Window_known of int | Window_unknown
type verdict_capability = Can_answer_text | Can_call_dispatch_tool
```

출력 모양은 요구에 넣지 않는다. 지금 어느 lane 도 provider 의 스키마 채널을 요구하지 않고(2.1),
요구하는 lane 이 없는 타입을 미리 만들면 쓰이지 않는 분기가 생긴다. 3.2 를 본다.

맡을 수 있는지는 함수 하나가 정한다.

```ocaml
val admits : lane:lane_requirement -> runtime:runtime_capability -> (unit, refusal) result
```

모든 조합을 `match` 로 적고 와일드카드를 쓰지 않는다. 새 변이형이 생기면 컴파일이 멈춘다.

`verifier_exact` 는 판정을 tool call 로 받는다. 라이브 설정의 주석은 이 조건을 맞추는 공식
클라이언트가 Claude Code 뿐이라고 적고 있다. 코드가 이 조건을 어떻게 지키는지는 읽지 않았다.
`Verdict_by_tool_call` 이라는 요구를 두면 그 조건도 같은 틀 안에서 계산된다.

### 3.2 출력: 스키마 채널은 판정에 쓰지 않는다

`admits` 는 runtime 이 스키마 채널을 가졌는지 보지 않는다. 답을 JSON 으로 받아 로컬에서 엄격하게
파싱하고 소비자가 검증하는 것은 지금과 같다. 프롬프트에 스키마 문장이 붙는 것도 같다.

바뀌는 것은 호출 때 `output_schema` 를 넘기는 조건 하나다. 채널이 있는 runtime(Claude Code,
Codex, Antigravity)에는 지금처럼 채널로도 스키마를 건넨다. 답이 그 모양을 지키게 하는 보강이다.
채널이 없는 runtime(Muse Code)에는 `None` 을 넘기고, 그 runtime 은 HTTP 슬롯이 `Json_syntax` 에서
받는 것과 같은 보장(프롬프트 문장과 로컬 파싱)만 받는다. 채널은 보강이지 입장 조건이 아니다.

provider 의 스키마를 꼭 요구하는 lane 이 생기면 그때 요구 타입을 하나 더하고 `admits` 에 한 칸을
추가한다. 지금은 그런 lane 이 없다.

### 3.3 입력: CLI 슬롯이 창을 싣는다

`resolved_lane` 의 CLI 슬롯을 문자열에서 값으로 바꾼다.

```ocaml
type cli_slot =
  { runtime_id : string
  ; context_window : int option   (* Runtime.max_context_of_runtime_id *)
  ; envelope_reserve : int        (* CLI 가 붙이는 시스템 프롬프트 등 *)
  }
```

`Window_must_be_known` 인 lane 은 `context_window = None` 인 슬롯을 publication 때 거절하고, lane
inventory 에서는 "admitted" 로 세지 않는다. 이것이 #41391 의 세 번째 항목이다.

바이트 환산은 Curator 에 넣지 않는다. Curator 코드의 원칙("Curator does not convert a token window
into a byte budget")을 지킨다. 환산은 `Keeper_lane_cli_oneshot` 쪽에 한 곳을 두고 모든 lane 이
같이 쓴다. 환산 비율과 `envelope_reserve` 크기는 아직 정하지 못했다 (9장).

### 3.4 Curator 가 CLI 슬롯을 걷는다

Curator 가 `Keeper_lane_cli_oneshot.walk` 를 HTTP 슬롯이 모두 실패한 뒤에 부른다. 다른 lane 과
같은 순서다. 묶음 크기는 걷게 될 모든 슬롯 중 가장 작은 `창 − 출력 예산 − 예약` 에 맞춘다.
Curator RFC 의 Q2("가장 작은 값")를 CLI 슬롯까지 넓힌 것이다.

CLI 슬롯으로 성공하면 응답에 토큰 사용량이 없다 (`Keeper_lane_cli_oneshot.walk` 문서). run 기록의
`usage` 는 비게 된다.

## 4. 하지 않는 것

- **요구를 못 채우는 조합은 그대로 거절한다.** "어떤 runtime 이든"은 요구를 채우는 runtime 이면
  어느 것이든, 라는 뜻이다. verifier 의 tool call 판정은 dispatch tool 을 가진 클라이언트만 맡는다.
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

## 6. 비용과 위험

- 채널이 없는 runtime 은 비 JSON 답이 오면 walk 가 다음 슬롯으로 넘어간다. 슬롯마다 호출이
  한 번 낭비된다.
- 프로세스를 띄우는 비용이 호출마다 든다. `cli-runtimes-as-lane-slots` 의 비용 절을 따른다.
- 사용량이 기록되지 않으므로 provider 사용량 창에서 이 호출을 가려낼 수 없다.
- Curator 가 CLI 슬롯으로 넘어갈 때 묶음이 창 쪽으로 줄어, 같은 밀린 분량이 더 많은 호출로
  나뉜다.

## 7. 나눠 올리는 순서

이 RFC 가 병합된 뒤의 구현이다. 스택 하나로 올리고 맨 위 PR 로 한 번에 병합한다.

1. 요구와 능력 타입, `admits`, 조합표 테스트. Muse 가 `Json_syntax` lane 에 들어간다.
   `Keeper_lane_cli_oneshot.run` 이 요구에 따라 `output_schema` 를 넘기거나 넘기지 않는다.
2. `resolved_lane` 의 CLI 슬롯이 창과 예약을 싣는다. publication 거절과 inventory 표시를 맞춘다.
3. Curator 가 CLI 슬롯을 걷는다. 묶음 크기가 모든 슬롯 중 가장 작은 값에 맞는다.

각 PR 은 자기 테스트를 가진다.

## 8. 검증

- **조합표.** `admits` 의 모든 (요구 × 능력) 칸을 테스트한다. 와일드카드가 없으므로 새
  변이형은 컴파일로 잡힌다.
- **Muse.** `Window_not_needed` · `Verdict_as_text` lane 이 Muse 를 맡는다. runner 가 받는
  `output_schema` 는 `None` 이고, 채널이 있는 runtime 은 같은 lane 에서 스키마를 받는다.
- **Curator, CLI 슬롯.** 가짜 runner 로 HTTP 슬롯 전부 실패 → CLI 슬롯 성공 → 장부 갱신.
  CLI 슬롯이 JSON 이 아닌 답을 내면 walk 가 넘어가고, 모두 실패하면 슬롯별 실패 목록이 남는다.
- **창을 모르는 슬롯.** publication 에서 거절되고 inventory 가 "admitted" 로 세지 않는다.
- **묶음 크기.** 창이 다른 두 슬롯이 있으면 작은 쪽에 맞는다.
- **변이 검사.** `admits` 가 채널 없는 runtime 을 거절하게 바꾸면 Muse 케이스가 실패한다.
  묶음 크기에서 `min` 을 `max` 로 바꾸면 크기 케이스가 실패한다.
- **라이브.** 한 lane 의 뒤쪽에 CLI 슬롯 하나를 두고 하루 관찰한 뒤 넓힌다. 어느 lane 인지는
  운영자가 정한다.

## 9. 열린 질문

- **Q1. `envelope_reserve` 와 바이트 환산 비율을 어떻게 정하나.** CLI 클라이언트가 붙이는
  시스템 프롬프트와 도구 정의의 크기를 재지 못했다. 고정값으로 둘지 클라이언트마다 잴지 정해야
  한다. 9.4MB 입력 사고(구 Curator 의 `1261 Prompt exceeds max length` 83회)를 되풀이하지 않는
  쪽으로 보수적이어야 한다.
- **Q2. 말이 많은 클라이언트의 엄격 파싱.** Agent Core 는 코드 펜스를 벗기지 않는다. CLI 클라이언트가
  응답에 설명을 덧붙이면 실패율이 올라간다. 측정하고, 그 뒤에 규칙을 바꾸지 말고 순서로 푼다.
- **Q3. muse 일회성 경로의 한계.** `muse serve` 로 한 번 묻고 답을 받는 길이 lane 의 시간 한도,
  세션 내구성(`Session_not_durable`)과 맞는지 읽지 못했다. 실제로 JSON 이 돌아오는지도 실행해
  보지 못했다.
- **Q4. 입력 초과 거절의 모양.** Claude Code, Antigravity, Muse 가 입력 초과를 타입으로 구분되는
  실패로 내는지 읽지 못했다. 타입으로 나오지 않으면 3.3 의 사전 크기 조절이 유일한 방어다.
- **Q5. 요구를 코드에 두는 것이 맞는가.** 닫힌 변이형으로 두는 것을 권한다. lane 이 많지 않고
  요구가 바뀌면 코드 리뷰를 거쳐야 하기 때문이다. 설정으로 열어 두면 lane 마다 운영자가 다르게
  적을 수 있다.
- **Q6. 일회성 실행의 도구 권한.** Fusion 의 한 번 질문 경로는 도구를 막는 정책을 적용한다
  (antigravity 는 Plan 모드와 샌드박스, muse 는 `muse_default`). lane 호출에도 같은 정책이
  적용되는지 확인해야 한다. claude 와 codex 는 읽지 않았다.

## 10. 참고한 것

모두 `origin/main` 9e3acecb37 에서 읽었다.

- `packages/agent_core/lib/llm_provider/exact_output.mli`: `minimum_guarantee`, `Json_syntax`.
- `lib/keeper/keeper_lane_cli_oneshot.mli`: `runner`, `run`, `walk`, `prompt_with_schema`,
  `input_capacity`.
- `lib/fusion/fusion_official_client.ml`: muse 분기의 `output_schema` 조건.
- `lib/runtime/runtime_schema.ml`: `output_schema_channel`, `api_format_output_schema_channel`.
- `lib/runtime/runtime.ml`: `exact_slot_list_admitting`.
- `lib/runtime/runtime.mli`: `resolve_max_context_of_runtime_id`, `max_context_of_runtime_id`.
- `lib/runtime/runtime_exact_output_registry.mli`: `resolved_lane.cli_slots`.
- `lib/server/server_workspace_memory_curator.ml`: `prepare_execution`, `execute_http`,
  `execute_output`.
- `bin/masc_tui_lane_inventory.ml`: admitted 계수.
- `docs/rfc/RFC-cli-runtimes-as-lane-slots.md`, `docs/rfc/RFC-exact-lane-walks-one-slot-list.md`,
  `docs/rfc/RFC-workspace-curator-curates-changed-facts.md` (Q2).
- Issue #41391, PR #39622, #39858.
- muse 1.4.7: `muse exec --help`, `muse schema generate-json-schema`.
