---
rfc: "open-tool-carries-cohort-and-reach"
title: "열린 도구는 같이 도는 묶음과 닿는 곳을 싣는다"
status: Accepted
created: 2026-11-26
updated: 2026-11-26
author: claude
supersedes: []
superseded_by: null
related: ["turn-activity-is-open-work"]
---

# RFC open-tool-carries-cohort-and-reach: 열린 도구는 같이 도는 묶음과 닿는 곳을 싣는다

- 상태: **승인(2026-11-26).** 운영자가 범위를 「서버 분류까지 (RFC부터)」로 고르고 이 초안을 승인했다(「네네 시작!」). §5의 「Batch」는 agent core의 계획 묶음으로 읽은 대로 간다.
- 계기: 운영자가 키퍼 채팅을 보며 한 말이다. 「Tools, Thinkings, Parallel, Batch 등등 그리고 외부 Call 등등도… 진행이라는 게 UI로 명확하게 표시」.
- 코드 좌표는 `origin/main` `d764c5f6ac2f`에서 읽었다.
- 앞선 RFC `turn-activity-is-open-work`가 미리보기에 「지금 열려 있는 일」 목록을 실었다. 이 RFC는 그 목록의 도구 항목에 두 가지를 더한다.

## 0. 요약

- 지금 TUI는 열린 일을 상태 줄 한 줄로 접는다. 예: `도구 실행 중 · bash 외 2건`.
- 운영자가 알고 싶은 것은 다섯 가지다. 추론 중인지, 어떤 도구가 도는지, 몇 개가 동시에 도는지, 한 묶음으로 계획된 호출인지, 그 호출이 MASC 밖으로 나가는지.
- 앞의 둘은 이미 미리보기에 있다. 뒤의 셋은 없다.
- 이 RFC는 네 가지를 정한다.
  1. 열린 도구가 agent core가 계획한 묶음 위치를 싣는다(D1).
  2. 열린 도구가 닿는 곳을 싣는다. 도구 실행기에서 빠짐없는 `match`로 정한다(D2).
  3. 모르는 것은 모른다고 보낸다(D3).
  4. TUI가 열린 일을 한 줄씩 그린다(D4).

## 1. 지금 있는 것과 없는 것

### 1.1 미리보기의 열린 도구

- `open_tool`은 `tool_use_id`, `tool_name`, `stage`, `started_at`, `since`만 가진다(`lib/keeper/keeper_turn_preview.ml:14`).
- JSON은 `open_activity_to_json`이 만든다(같은 파일 :937). 도구는 `{"kind":"tool","tool_use_id","name","stage","started_at_unix","since_unix"}`이다.
- 이름은 스트림의 `ContentBlockStart.tool_name`이나 `PreToolUse` 훅의 `tool_name`에서 온다(:625, :708, :736).

### 1.2 묶음은 agent core에 타입으로 있다

- agent core는 이어진 `Concurrent` 호출을 한 묶음(`Concurrent_batch`)으로 계획한다(`packages/agent_core/lib/agent/agent_tool_batch_plan.ml:17`).
- 그 묶음을 `Eio.Fiber.List.map`으로 동시에 돌린다(`packages/agent_core/lib/agent/agent_tools.ml:1429`).
- 호출마다 `Tool_contract.schedule`이 있다. `planned_index`, `batch_index`, `batch_size`, `execution_mode`이다(`packages/agent_core/lib/base/tool_contract.mli:50`). 주석이 「같은 wave 좌표는 계획된 한 묶음이다」라고 적는다.
- `PreToolUse` 훅은 그 `invocation`을 받는다(`lib/keeper/keeper_hooks_agent_core.ml:362`). 지금은 `tool_use_id`만 꺼내 미리보기에 넘긴다.
- 그래서 병렬로 도는 도구 셋은 미리보기에 열린 도구 셋으로 따로 나온다. 셋이 한 묶음이라는 표시는 없다.

### 1.3 닿는 곳은 타입이 없다

- `Tool_catalog.metadata`의 축은 `readonly`, `idempotent`, `mcp_context_required`뿐이다(`lib/tool/tool_catalog.ml:21`, :31).
- `Keeper_tool_descriptor.policy.leaves_masc`는 승인 정책용이다(`lib/keeper/keeper_tool_descriptor.mli:180`). 「쓰기가 MASC 저장소 밖에 닿는가」를 묻는다. Execute·Grep은 true이고 WebSearch·WebFetch는 false다. 「밖으로 나가는 호출」 표시로 쓸 수 없다.
- 도구 실행기 `runtime_handler`는 닫힌 합이다(`lib/keeper/keeper_tool_descriptor.mli:117`). `Tool_web_search`, `Tool_web_fetch`, `Tool_browser_*`, `Tool_masc_fusion_dispatch`, `Tool_execute`, `Tool_lane_addon` 등이 있다.
- 클라이언트 내장 도구(native tool)는 이름과 `origin`(`Built_in | Mcp_wrapper`)만 있다(`lib/runtime/runtime_native_tools.mli:36`).
- 도구 이름으로 짐작하는 것은 헌법 `forbidden#string_matching`에 걸린다.

## 2. 결정

### D1. 열린 도구가 묶음 위치를 싣는다

- `open_tool`에 `cohort : cohort option`을 더한다.

```ocaml
type cohort =
  { batch_index : int   (* 한 모델 응답 안의 몇 번째 묶음인가. 응답마다 0부터 센다 *)
  ; batch_size : int    (* 그 묶음에 계획된 호출 수 *)
  ; concurrent : bool   (* 묶음을 동시에 돌리는가: execution_mode = Concurrent *)
  }
```

- 값은 `PreToolUse`의 `Tool_contract.Invocation.schedule`에서 그대로 옮긴다. 새로 세지 않는다.
- 스트림 블록으로만 연 도구(아직 훅이 오지 않은 요청 단계, native 블록)는 `None`이다. 훅이 오면 채운다.
- official client 런타임은 schedule을 주지 않는다. `None`이다.
- TUI는 같은 `batch_index`의 열린 도구를 한 묶음으로 그린다. 「병렬」은 `concurrent = true`이고 `batch_size > 1`인 묶음이다. 「묶음」은 같은 `batch_index`다.

### D2. 열린 도구가 닿는 곳을 싣는다

- `Keeper_tool_descriptor`에 `reach`를 둔다.

```ocaml
type reach =
  | Masc_state        (* MASC 저장소·다른 키퍼에만 닿는다 *)
  | Sandbox           (* 샌드박스 파일·프로세스. 그 프로세스가 네트워크를 쓰는지는 모른다 *)
  | Network           (* 웹 검색·가져오기·브라우저 *)
  | Model_provider    (* 다른 LLM 공급자를 부른다: fusion *)
```

- `reach_of_handler : runtime_handler -> reach`를 빠짐없는 `match`로 쓴다. `_ ->`를 쓰지 않는다. 새 실행기를 더하면 컴파일러가 빠진 갈래를 잡는다.
- `Tool_lane_addon of Lane_addon_tool_export.t`는 export가 닿는 곳을 선언해야 한다. 선언이 없으면 이 RFC의 구현 PR이 export에 필드를 더한다. 추정하지 않는다.
- 여러 도구를 받는 dispatch 실행기(`Tool_masc_misc_dispatch` 등)는 실행기 하나가 한 `reach`를 가진다. 같은 실행기 안에서 닿는 곳이 갈리면 실행기를 나누는 일로 본다. 구현 PR에서 갈래마다 확인한다.
- 미리보기는 `PreToolUse`에서 호출의 descriptor를 찾아 `reach`를 적는다. 이름으로 등록부(registry)를 찾는 것은 조회다. 이름 모양으로 분류하지 않는다.

### D3. 모르는 것은 모른다고 보낸다

- 열린 도구의 `reach`는 `reach option`이다. descriptor가 없는 호출(native 도구, descriptor 없는 MCP 도구)은 `None`이다.
- `None`을 `Masc_state`로 바꿔 보내지 않는다. TUI는 `None`에 닿는 곳 표시를 달지 않는다.
- ACP 클라이언트의 `tool_kind`(`Tool_fetch` 등, `lib/runtime/runtime_acp_client.ml:616`)가 native 블록까지 오는지는 확인하지 못했다. 온다면 native 도구의 `reach` 출처가 될 수 있다. 이 RFC의 범위 밖이다.

### D4. TUI가 열린 일을 한 줄씩 그린다

- 턴이 도는 동안 채팅 아래에 진행 블록을 그린다. 열린 일 하나가 한 줄이고, 줄마다 그 일의 `since`부터 센 시간을 붙인다.
- 묶음은 머리줄 하나 아래에 모은다. 병렬 묶음의 머리줄은 `동시 실행 N개`다.
- 닿는 곳이 `Network`·`Model_provider`인 도구에는 `외부` 표시를 단다. `Sandbox`에는 `샌드박스`를 단다.
- 상태 줄은 지금처럼 한 줄 요약으로 남는다. 블록은 그 요약을 펼친 것이다.

```
▍ 진행 · 41s
▍ ✦ 추론 중                              12s
▍ ┌ 동시 실행 3개
▍ │ ⚙ Execute 실행 중        샌드박스      4s
▍ │ ⚙ WebFetch 실행 중       외부 · 웹     2s
▍ └ ⚙ masc_board_post 실행 중               1s
```

- 헌법 `build_and_ci`에 따라 화면 문구·배치 테스트는 만들지 않는다. TUI 시험은 디코딩한 상태만 본다.

## 3. 바뀌는 곳

| 층 | 파일 | 바뀌는 것 |
|---|---|---|
| 서버 | `lib/keeper/keeper_turn_preview.ml(i)` | `open_tool`에 `cohort`·`reach`, JSON 두 필드 |
| 서버 | `lib/keeper/keeper_hooks_agent_core.ml`, `lib/keeper/keeper_run_tools_hooks.ml` | `PreToolUse`에서 schedule과 descriptor `reach`를 넘긴다 |
| 서버 | `lib/keeper/keeper_tool_descriptor.ml(i)` | `reach`, `reach_of_handler` |
| TUI | `lib/masc_tui/protocol/wire_fleet.ml(i)` | 두 필드 디코딩 |
| TUI | `lib/masc_tui/screens_ops/keeper_dive.ml`, `lib/masc_tui/store/chat_transcript.ml` | 진행 블록 |

## 4. 스택

1. 이 RFC.
2. 서버: `cohort`(D1). schedule을 옮기기만 한다.
3. 서버: `reach`(D2·D3).
4. TUI: 디코딩과 진행 블록(D4).

- wire는 필드 추가다. 새 서버와 옛 TUI, 옛 서버와 새 TUI가 모두 돈다. 옛 서버의 응답에는 두 필드가 없고 TUI는 `None`으로 읽는다.

## 5. 정하지 않은 것

- 「Batch」의 뜻. 이 RFC는 agent core의 계획 묶음으로 읽었다. 한 호출이 여러 항목을 처리하는 도구(`masc_batch_add_tasks`)를 따로 표시하려면 descriptor의 `tool_kind` 축을 써야 한다. 지금은 모든 도구가 `Atomic_tool`이다(`lib/keeper/keeper_tool_descriptor.ml:541`). 운영자가 그쪽을 원하면 D5로 더한다.
- `Sandbox` 안의 프로세스가 네트워크를 쓰는지. egress proxy(`lib/egress_proxy*`)가 호출 단위로 알려 주지 않는다. 지금은 `샌드박스`로만 표시한다.
