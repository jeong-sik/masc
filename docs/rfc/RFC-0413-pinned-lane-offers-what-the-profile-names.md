---
rfc: "0413"
title: 넓힐 수 없는 레인은 프로필이 지명한 것만 싣는다
status: Draft
created: 2026-09-04
author: Claude Opus 5
supersedes: []
superseded_by: null
related: ["0403"]
---

## 0. 한 줄 요약

공식 클라이언트 레인(codex app-server, antigravity CLI, claude code)은 도구를
프로세스 시작 시점에 고정하고 도중에 넓히지 못한다. 그래서 이 레인은 붙은 도구를
전부 스키마로 싣는다. 실측으로 그 바이트의 33.0%는 여드레 동안 한 번도 불리지 않은
도구가 차지한다. 유예(deferral)는 이 레인에서 원리적으로 불가능하므로, 남은 답은
"보낼 것을 세션이 시작되기 전에 정한다" 하나다. 이 문서는 RFC-0403이 붙임 도구에
만든 지명 축을 내장 도구까지 넓히고, 그 선언이 바뀌면 세션이 새로 시작한다는 것을
값으로 적는다.

## 1. 측정 출처

이 문서의 숫자는 세 곳에서 나왔다. 출처가 없는 숫자는 이 문서의 결함이다.

| 무엇 | 어디서 | 창 |
|---|---|---|
| 받은 도구 집합 | `~/me/.masc/wire-capture/2026-09/*.jsonl` 의 `kind:"request"` 행. 배열은 `tools_ref._blob.sha256` 로 `~/me/.masc/tool_blobs/<sha[:2]>/<sha>` 에서 복원 | 2026-09-03T04:06:42Z .. 2026-09-04T01:43:49Z, 21.6시간. 6,182행, 미해결 blob 0 |
| 호출 | `~/me/.masc/logs/system_log_<date>.jsonl` 의 `keeper:<name> tool_call tool=<name>` 행 | 2026-08-28 .. 2026-09-04, 여드레 |
| 캐시·귀속 | `~/me/.masc/keepers/*/metrics/2026-09/0[1-4].jsonl`, `record_kind:"turn"` 8,669행 | 2026-09-01 .. 04 |

측정 시점의 기계 부하(`uptime`): 2026-09-04 10:40 KST 110.14 / 150.04 / 166.92,
같은 날 10:51 376.31 / 371.62 / 290.43. 이 문서에는 벽시계 수치가 없으므로 부하가
결론을 좌우하는 자리는 없다. 부하를 적는 이유는 재측정하는 사람이 같은 조건을
가정하지 않게 하기 위해서다.

**창이 서로 다르다는 점을 먼저 적는다.** 받은 집합은 하루치, 호출은 여드레치다.
wire-capture 는 이미 회전으로 `03.000`·`03.001` 을 지웠고, 오늘 다시 재면 더 적게
나온다. 그래서 "이 Keeper 가 지난 여드레 내내 같은 배열을 받았다"는 말은 할 수 없다.

## 2. 문제

### 2.1 목록 없는 요청이 전체 도구 스키마 바이트의 28.2%를 나른다

2026-09-04 측정: `keeper_tool_search` 가 배열에 없는 요청 —— 즉 유예 목록이 없는
요청 —— 이 전체 도구 스키마 바이트의 **28.2% (162,412,956 / 575,346,108)** 를
차지한다. (138개, 목록 없음) 요청 374건, (150개, 목록 없음) 요청 177건. Keeper 별로
자기 도구 바이트 중 이 레인이 차지하는 몫은 lane-smith 98.1%, code-reviewer 71.7%.

같은 날 몇 시간 뒤 같은 방법으로 다시 세면 총량이 439,558,046 바이트(유예 288,513,551
/ 고정 151,044,495)로 줄어든다. 두 값의 차이는 측정 오류가 아니라 회전 보존이 앞쪽
파일을 지운 결과다. 비율을 재현하려면 같은 시각의 파일 목록이 필요하다.

### 2.2 그 절반은 불리지 않는다

요청 가중으로 다시 센 값 —— 각 요청 행의 복원된 배열 바이트를 그대로 합한 값:

```
고정 레인 도구 스키마 바이트, 09-03T04:06Z..09-04T01:43Z:  152,764,547
  여드레(08-28..09-04) 동안 한 번도 안 불린 도구 몫:        50,369,025  (33.0%)
  사흘(09-01..03) 창으로 좁히면:                            68,627,535  (44.9%)
```

창을 사흘에서 여드레로 넓히면 "죽었다"는 몫이 44.9%에서 33.0%로 줄어든다. 이
차이가 이 문서에서 가장 중요한 숫자다. 사흘짜리 관찰로 자르면 이틀 전에 1,229번
불린 도구를 지운다(§3.4).

Keeper 별, 여드레 기준:

| keeper | 런타임 | 받는 도구 | wire KB | 여드레 미호출 KB | % | 사흘 기준 % |
|---|---|---|---|---|---|---|
| kidsnote-pr-jira-checker | claude_code | 137 | 6,420 | 4,592 | 71.5 | 71.5 |
| lane-smith | antigravity | 139 | 36,586 | 13,527 | 37.0 | 57.5 |
| analyst | antigravity | 138 | 4,705 | 1,627 | 34.6 | 42.5 |
| edgar.a.poe | antigravity | 151 | 26,981 | 8,898 | 33.0 | 46.4 |
| sangsu | antigravity | 139 | 24,578 | 7,988 | 32.5 | 44.7 |
| rondo | antigravity | 139 | 25,600 | 7,592 | 29.7 | 39.6 |
| code-reviewer | antigravity | 95 | 24,313 | 4,965 | 20.4 | 23.6 |

kidsnote-pr-jira-checker 의 71.5%는 다른 여섯과 같은 값이 아니다. 이 Keeper 는
08-28..08-31 에 `tool_call` 행을 하나도 남기지 않았다(돌지 않았다). 여드레와 사흘
값이 같은 것이 그 증거다. 사흘짜리 근거를 여드레 이름표로 쓴 값이다.

### 2.3 무엇이 실제로 죽었나 —— 그리고 무엇이 죽은 것처럼 보이나

일곱 Keeper 중 누구도 여드레 동안 부르지 않은 도구는 182개 중 64개, 219.0 KB 중
**98.2 KB** 다.

| 계열 | KB | 미호출 / 받은 수 |
|---|---|---|
| atlassian | 44.0 | 25 / 31 |
| slack | 32.5 | 10 / 12 |
| github | 11.9 | 16 / 44 |
| masc_fusion | 2.6 | `masc_fusion` (형제 `_status` 는 불렸다) |
| masc_board | 2.4 | `_cleanup`, `_curation_submit`, `_profile` |
| keeper_ide | 1.8 | `keeper_ide_annotate` |
| keeper_voice | 1.3 | 4 / 4 |
| keeper_person | 0.6 | `keeper_person_note_set` |
| masc_keeper | 0.4 | `masc_keeper_delegate_cancel` |
| masc_gc | 0.3 | `masc_gc` |
| keeper_composition | 0.3 | `keeper_composition_cancel` |

계열 전체가 함대 차원에서 죽은 것은 넷뿐이고(`keeper_ide`, `keeper_person`,
`masc_gc`, `masc_fusion` 본체) 합쳐 5.1 KB 다. 무게는 다른 데 있다.

**`github_*` 는 이 문제를 계열 단위로 풀 수 없다는 증거다.** 44개 46.9 KB, 일곱 중
다섯이 받는다. 받는 Keeper 전원이 매일 쓴다(rondo 8/8일, edgar.a.poe·lane-smith·sangsu
7/8일). 그런데 **44개 중 23개보다 많이 쓰는 Keeper 가 없다**(rondo 23, lane-smith 21,
sangsu 20, edgar.a.poe 19, analyst 16). Keeper 별 미호출 github 바이트는 lane-smith
46.9 중 35.8 KB, edgar.a.poe 28.6 KB. 계열은 살아 있고 각 Keeper 가 받는 사본의 절반은
죽어 있다. 계열 단위로 자르면 46.9 KB 를 통째로 남기거나 레인을 망가뜨린다.

## 3. 왜 유예로는 안 되는가

### 3.1 코드가 그렇게 적어 두었다

`lib/keeper/keeper_tools_agent_core_bundle.ml:569-572`:

> Attached tools, as schemas. What the lanes that cannot widen a running turn
> are given: they pin their tool set at process spawn or thread start, and that
> set is part of a resumable session's identity, so a listing would name tools
> they can never make callable.

같은 파일 :637-639:

> The lanes that cannot widen a turn get every tool as a schema: holding one
> back there would name a tool nothing can load.

그리고 :641 이 실제 배열이다.

```ocaml
{ tools = descriptor_tools @ composition_tools @ identity_agent_tools
; agent_core_tools = always_loaded @ (listing :: already_used)
```

`tools` 는 고정 레인이 보내는 것이고, `defer_loading` 으로 나뉜
`always_loaded_builtin_tools` / `deferred_builtin_tools` 구분(:595-603)을 통과하지
않는다. `agent_core_tools` 만 그 구분을 읽는다.

`lib/tool_surface/tool_loading_declarations.mli` 도 같은 말을 한다.

> It reaches the Agent Core lane only. The codex, antigravity and claude_code
> runtimes are handed the whole tools array and never read this key.

### 3.2 그래서 선언이 한쪽에서만 읽힌다

이 worktree 의 `config/tools/` 는 145개 파일 중 **55개가 `defer_loading = true`** 를
선언한다. 일곱 Keeper 가 공통으로 받는 내장 95개 중 이 선언을 가진 것이 **54개,
50,125 바이트**다(라이브 `config/tools/` 트리 기준). 런타임은 라이브 트리가 아니라
바이너리에 박힌 사본을 읽고(`tool_loading_declarations.ml:12-14` "they are crunched
into the binary"), 2026-09-04 기준 두 트리는 파일 하나 차이가 났다. 그래서 54는 ±1로
읽는다.

정리하면 **고정 레인 내장 95개 중 54개(50,125 B)는 운영자가 이미 "유예해도 된다"고
써 두었는데 이 레인이 그 파일을 읽지 않는다.** `attached_allow` 는 설계상 붙임 도구
전용이라 이 54개에 닿지 않는다(`keeper_identity_tool_allow.mli:29-33`).

남은 빈자리는 하나다: **Keeper 별 × 내장 도구**. 이 축은 지금 존재하지 않는다.

### 3.3 고정은 MCP 가 만든 것이 아니다

masc#33065 감사는 §3.1 의 "넓히지 못한다"가 masc 스스로 만든 제약 아니냐고 물었다.
근거는 `runtime_official_client_mcp.ml:289` 가 MCP capability 를
``"tools", `Assoc []`` 로 내면서 `listChanged` 를 선언하지 않는다는 점이다. 확인해 보니 **아니다.** 그
capability 를 켜도 도는 세션의 도구 집합은 바뀌지 않는다. 네 가지가 각각 독립적으로
막는다.

**하나, 보낼 통로가 없다.** `Runtime_official_client_mcp.handle_message` 는
`(dispatch, error) result` 를 돌려주고 `dispatch` 는 `{ response : Yojson.Safe.t
option; tool_called : bool }` 이다. 이 모듈은 답만 하고 먼저 말하지 못한다. HTTP 쪽은
`runtime_official_client_mcp_http.ml:389` 의 `` `GET `` 가지가 405 `"SSE is not
enabled for this endpoint"` 를 돌려주므로 서버발 알림을 실을 스트림 자체가 열리지 않고,
Claude Code 쪽 통로는 control_response 만 되돌린다.

**둘, 바뀔 목록이 아니다.** `tool_specs` 는 thunk 지만 턴 시작 때 묶인 불변 리스트를
닫는다(`runtime_claude_code.ml:494`,
`keeper_antigravity_runtime.ml:830`). 두 번 불러도 같은 값이다. 지연 계산이지 동적이
아니다.

**셋, 선언은 지킬 수 없는 약속이 된다.** MCP 2025-11-25 `server/tools` 는
`listChanged` 를 선언한 서버가 `notifications/tools/list_changed` 를 보내야 한다고
(SHOULD) 적는다. 위 둘 때문에 masc 는 그 알림을 보낼 수 없으므로, 선언하는 순간 매
세션 SHOULD 를 어기는 쪽으로 넘어간다. 반대 방향은 MUST 다 —— lifecycle 의 "Only use
capabilities that were successfully negotiated".

**넷, 유일하게 그 선언을 읽는 클라이언트가 읽고도 아무것도 안 한다.** claude 2.1.260
은 `_setupListChangedHandlers` 를 서버의 `listChanged` 선언에 걸어 두지만, CLI 가
클라이언트를 만들 때 넘기는 값이 `listChanged:{tools:{autoRefresh:!1,debounceMs:0,
onChanged:()=>{}}}` 이고 핸들러 본체는 `if(!d){_(null,null);return}` 로 빠진다.
`autoRefresh` 가 꺼져 있고 `onChanged` 가 빈 함수라 `tools/list` 재조회를 하지 않는다.
바이너리 안 `onChanged:` 여덟 자리가 전부 `()=>{}` 다.

그래서 §3.1 의 문장은 유지되지만 **근거로 MCP capability 를 들 필요는 없다.** 실제
고정 지점은 레인마다 따로 있고, 셋 다 `listChanged` 로는 풀리지 않는다.

| 레인 | 무엇이 고정하나 | 어디 |
|---|---|---|
| claude_code | argv. `--allowedTools` 가 execve 시점에 이름을 못 박고 `--strict-mcp-config` 가 설정을 잠근다. 목록에 없는 이름은 MCP 로 노출돼도 호출되지 않는다 | `runtime_claude_code.ml:1265`, `:1275`, `mcp_config` `:1188` |
| codex | MCP 를 아예 쓰지 않는다. 도구는 `thread/start`·`thread/resume` 의 `dynamicTools` 파라미터로 간다 | `runtime_codex_app_server.ml` (파일 전체에 `mcp` 문자열 0건) |
| antigravity | 턴의 `Eio.Switch.run` 안에서 브리지를 새로 띄우고 릴리스 때 config 를 지운다. MCP 세션 수명이 곧 한 턴이다 | `keeper_antigravity_runtime.ml:815-860` |

RFC-0409 §2 가 같은 결론에 다른 경로로 닿아 있다(그 문서는 `mcp_server.ml:143` 이
`listChanged: true` 를 선언하고도 쏘는 코드가 없다는 점을 짚는다). 이 절은 그 관찰을
공식 클라이언트 세 레인 쪽에서 확인한 것이다.

따라서 이 RFC 의 전제는 그대로 선다. 바뀐 것은 근거뿐이고, 코드 변경은 없다 ——
`runtime_official_client_mcp.ml` 에는 왜 선언하지 않는지를 적은 주석만 들어갔다.

## 4. 제약

### 4.1 세션 재개 —— #27992 의 "출구 없음" 은 이미 닫혔다

`lib/keeper/keeper_official_client_session_store.ml:805-824` 를 직접 읽었다.

```ocaml
let reconcile_tool_surface plan ~tool_surface_sha256 =
  match plan.required_tool_surface_sha256 with
  | None -> plan
  | Some stored when String.equal stored tool_surface_sha256 -> plan
  | Some _ ->
    { previous_settlement = None; turn_count = 1; required_tool_surface_sha256 = None }
```

바로 위 주석이 #27992 을 이름으로 부르며 "a refusal here strands every settled
session on the next release" 라고 적는다. 지금은 거절이 아니라 **새 세션** 가지로
간다. `client_kind`·`runtime_id` 가 바뀌었을 때와 같은 가지다. 세 어댑터가
`claim` 전에 적용하고(`keeper_codex_runtime.ml:543`,
`keeper_antigravity_runtime.ml:444`, `keeper_claude_code_runtime.ml:500`),
`claim` 자신도 :830 에서 한 번 더 적용해서 호출자가 건너뛸 수 없다.

라이브 확인: `~/me/.masc/logs/system_log_2026-09-0{2,3,4}.jsonl` 에서
`tool surface changed before session resume` 0건. 그 문자열은 코드에 더 없다.

**금지하는 것**: "표면을 좁히면 세션이 좌초한다"를 근거로 이 설계를 막는 것.
그 상태는 존재하지 않는다. 다만 아래 §4.2 의 값은 그대로 남는다.

해시가 무엇에 반응하는지(`keeper_official_client_session_store.ml:187-217`):
도구 이름·서술·입력 스키마를 이름순으로 정규화한 JSON, `native_posture`,
`context_message_schema` 셋. 도구 순서와 필드 순서는 해시를 움직이지 않는다.
**도구를 하나 빼는 것은 해시를 움직인다.**

### 4.2 그 대신 값이 있다 —— 그리고 그 값은 아직 갚을 사람이 있다

새 세션 가지의 값은 셋이다.

1. `previous_settlement` 이 사라지고 `turn_count` 가 1로 돌아간다.
2. 다음 턴이 목표만 보내는 대신 투영된 대화 전체를 bootstrap 으로 다시 보낸다
   (`keeper_claude_code_runtime.ml:539-544`; codex 는 `thread/inject_items`,
   `keeper_codex_runtime.ml:569-576`).
3. 그 bootstrap 이 안 맞으면 `Recovery_required { failure = Input_rejected _ }`
   로 떨어지고, `plan_claim:770-785` 는 이 상태만은 자동 재진입을 거절한다.
   운영자 resolve 없이는 안 열린다.

3번은 죽은 코드가 아니다. `bootstrap_floor_exceeded` 는 2026-09-03 에 27건,
09-02 와 09-04 에 0건이다(같은 로그 파일들).

반대 방향도 같은 세션 저장소가 적어 둔다(`:10-21`): floor 를 넘긴 세션이 다시 맞게
되는 길은 "시스템 프롬프트, 목표, 도구 표면, 런타임 변경" 넷뿐이다. **도구 표면을
줄이는 것은 그 막다른 골목에서 나가는 인정된 출구 중 하나다.**

라이브 `turn_count` 는 1, 1, 1, 5, 6, 17, 36 이다(일곱 Keeper 의
`~/me/.masc/keepers/<k>/official-client-runtime/session.json`). 이 레인의 세션은
짧고, 그래서 한 번 버리는 값도 작다.

**금지하는 것**: 표면 변경을 무료로 취급하는 것. 그리고 세션을 자동으로 자주
갈아 끼우는 어떤 장치도.

### 4.3 프로바이더 캐시 —— 오늘의 값으로 매길 수 없다

`packages/agent_core/lib/llm_provider/backend_anthropic.ml:441-462` 는 마지막 도구에
`cache_control` 을 얹는다. 배열이 바뀌면 시스템 프롬프트와 히스토리의 캐시 읽기까지
같이 잃는 모양이다. 그런데 **이 파일에 묶인 라이브 프로바이더가 없다.**
`~/me/.masc/config/runtime.toml:730-790, 2285-2290` 의 모든 provider 는
`openai-compatible-http` / `ollama-http` / `codex-app-server` / `claude-code` /
`antigravity-cli` 다. Anthropic 네이티브 바인딩은 0개다. 살아 있는
`backend_openai.ml:78` 은 `supports_prompt_caching = false` 이고 `cache_control` 을
아예 내보내지 않는다.

라이브 와이어에서 직접 본 것(`usage_scope = "per_request"` 행만):

| 런타임 | 버킷 | n | cache_read 중앙값 | input 중앙값 | 0 읽기 % |
|---|---|---|---|---|---|
| glm-coding.glm-5.3 | 배열 그대로 | 284 | 47,968 | 56,946 | 0.4 |
| glm-coding.glm-5.3 | 배열 바뀜 | 38 | 37,984 | 58,808 | 0.0 |

배열이 캐시 접두사를 통째로 지배한다면 "바뀜" 38건이 전부 0을 읽어야 한다. 0건이
그랬다. 관찰이지 통제 실험이 아니고 n=38 이다.

모델별 캐시(8,669 turn 행, 09-01..04):

| runtime_id | 턴 | cache_read>0 | 중앙값 | usage_scope |
|---|---|---|---|---|
| glm-coding.glm-5.3 | 1,452 | 99.7% | 48,000 | per_request |
| claude_code.claude-sonnet-5 | 703 | 91.6% | 510,422 | per_request |
| ollama_cloud.deepseek-v4-flash-0731 | 2,829 | 0.0% | — | per_request |
| ollama_cloud.minimax-m3 | 1,424 | 0.0% | — | per_request |
| codex_subscription.gpt-5.6-luna | 254 | 0.0% | — | unavailable/none |
| antigravity_subscription.gemini-3-7-flash-high | 948 | 81.5% | 4,267,814 | conversation_cumulative |
| antigravity_subscription.gemini-3-8-flash-high | 929 | 61.7% | 225,974 | conversation_cumulative |

아래 두 행의 중앙값은 CLI 가 가진 누적 카운터의 차분이라 masc 가 계산한 값이 아니다.
`codex_subscription` 의 0은 "캐시 안 됨"이 아니라 "보고 안 됨"이다(`usage_scope`
가 `unavailable`). 둘 다 근거로 쓰지 않는다.

**그리고 이 레인에서는 질문 자체가 틀렸다.** #33009 병합 뒤 고정 레인의 지문은
세션 시작 행에만 남는다. 재개는 도구 배열을 아예 보내지 않고, 그래서
`Client_session_holds_input` 으로 기록된다(09-04 새 모양 110행 중 antigravity
attributed 6 / not_measured 58, 6건 전부 `basis.position = "fresh"`).
고정 레인의 도구 배열은 **턴 변수가 아니라 세션 상수**다.

**금지하는 것**: 이 레인의 표면 변경을 "턴마다 잃는 캐시"로 값 매기는 것. 값은
§4.2 의 세션 하나다. 그리고 `backend_anthropic` 의 `cache_control` 을 현재 값의
근거로 인용하는 것.

### 4.4 RFC-0403 이 이미 만든 축 —— 그리고 그 축의 채택률은 0이다

#32679 는 Keeper 가 자기 서비스의 전체 목록이 아니라 프로필이 지명한 붙임 도구만
받게 했다. 기전은 `Keeper_identity_tool_allow.apply ~allow offered` 하나이고
(`keeper_run_tools_setup.ml:429-431`), 이름 정확 일치만 한다. 접두사도 provider
묶음도 없다. `allow = None` 은 전부, `Some []` 은 없음 —— 두 값이 반대다.
`unnamed` 로 오타를 경고한다.

이 `.mli` 는 이 RFC 가 하려는 일을 미리 적어 두었다.

> Static also sidesteps what stops the official-client lanes from deferring at
> all -- those pin their tool set at process spawn, and a selection made before
> spawn is a set they can pin.

**그런데 라이브 함대에서 이 선언을 쓰는 Keeper 는 0개다.**
`rg -l attached_allow ~/me/.masc/config/` 결과 없음. 어떤 keeper TOML 에도
`[keeper.tools]` 블록이 없다. 즉 #32679 는 배포됐고 한 번도 작동한 적이 없다.

이것이 두 번째 제약이다. **#31728 은 정확히 같은 모양의 축을 지웠다** —— RFC-0389
의 `keeper.tools.groups` 는 "살아있는 Keeper 9개 중 선언 0개" 라서 타입·변환·필터·
meta 필드·프로필 기본값·TOML 분기·`keeper_up` 인자·영속화·투영 셋을 통째로
들어냈다.

**금지하는 것**: 기전만 넣고 선언은 나중에 넣는 PR. 이 저장소는 그런 PR 을 이미
한 번 지웠다.

### 4.5 항상 실리는 핵심은 지방이 아니다

47개 도구가 모든 Keeper 에게 가고, 사흘 동안 함대 차원에서 하나도 미호출이 아니었다.

다만 숫자 하나를 그대로 옮기지 않는다. **고정 레인 일곱 Keeper 가 실제로 공통으로
받는 집합은 94개 87.3 KB** 이고, 이 94개 중 21개(14.4 KB)는 사흘 창에서 미호출이다.
여드레로 넓히면 `keeper_ide_annotate`, `keeper_person_note_set`, `masc_gc`,
`masc_fusion`, `masc_keeper_delegate_cancel`, `keeper_composition_cancel`,
`masc_board_cleanup`, `masc_board_curation_submit`, `masc_board_profile`,
`keeper_voice_*` 4개가 남는다. 47과 94는 같은 집합이 아니다. 이 RFC 는 47을
건드리지 않고, 94 중 `defer_loading` 을 선언한 것에만 닿는다(§5.1).

## 5. 설계

### 5.1 무엇을 바꾸나

`keeper_tools_agent_core_bundle.ml:641` 의 `tools` 를 이렇게 바꾼다.

```
현재:  descriptor_tools @ composition_tools @ identity_agent_tools
제안:  always_loaded_builtin_tools
       @ named_of deferred_builtin_tools
       @ identity_agent_tools
```

`deferred_builtin_tools` / `always_loaded_builtin_tools` 분할은 이미 :595-603 에
있다. `named_of` 는 `Keeper_identity_tool_allow.apply` 와 같은 정확 이름 일치
필터이고, 같은 `unnamed` 보고를 낸다. **새 기전을 만들지 않는다.**

프로필 필드는 한 컷으로 이름을 바꾼다.

```
tools.attached_allow  ->  tools.allow
```

의미: "기본으로 유예되는 도구 중 이 Keeper 가 받을 것". 붙임 도구는 자기 tool 파일이
없어 언제나 유예 대상이고, 내장 도구는 `defer_loading = true` 를 선언했을 때만
유예 대상이다. 두 계열이 한 문장으로 설명된다. 호환 리더·변환기는 쓰지 않는다
(masc 의 hard cut 규칙). 라이브 선언이 0개이므로(§4.4) 이 컷의 값은 측정상 0이다.

`allow = None` 은 지금과 같은 바이트, `Some []` 은 유예 대상 전부 제외. 항상 실리는
핵심은 이 필드의 사정권 밖이다 —— 정책이 아니라 구조로. `always_loaded_builtin_tools`
는 필터를 지나지 않는다.

**두 레인 모두에서 읽는다.** 유예 레인에서도 지명 안 된 도구는 목록에서 빠진다.
한 선언이 레인마다 다른 뜻을 갖게 하지 않기 위해서다. 같은 파일 :595-599 가
같은 이유로 두 계열을 함께 나눈다.

> a declaration is either read wherever it can be written or it is a trap

유예 레인에서 아끼는 것은 스키마가 아니라 요약 한 줄이므로 이득은 작다. 대신
"이 Keeper 는 이 도구를 안 쓴다"가 한 곳에만 적힌다.

### 5.2 누가 정하나

운영자가 `<base_path>/config/keepers/<name>.toml` 에서 정한다. 그 파일 하나가
유일한 출처다.

- `masc_keeper_up` 인자가 없다. 코드가 그렇게 적어 두었다
  (`keeper_turn_up_config_persistence.ml:376-378`: "this axis has no
  `masc_keeper_up` argument, so the file is its only source").
- 대시보드에 읽기·쓰기 어느 쪽도 없다.
- 런타임은 호출 기록에서 이 목록을 **유도하지 않는다.** 유도하면 파생 값 위에
  게이트를 세우는 것이고(masc 규칙), 세션이 도는 중에 집합이 바뀐다. §2.2 의
  창 민감도가 그 유도가 왜 위험한지를 보여준다.

이 RFC 는 목록을 정하는 자리에 사람을 둔다. 여드레 호출 기록은 그 사람이 읽는
근거이지 런타임의 입력이 아니다.

### 5.3 언제 효력이 생기나 —— 그리고 도는 세션은 어떻게 되나

선언은 턴 준비 시점에 읽히지만(`keeper_run_tools_setup.ml:429-431`), 고정 레인에서
**효력이 생기는 순간은 세션 claim 이다.** 배열이 달라지면 `tool_surface_sha256` 이
움직이고, `reconcile_tool_surface` 가 새 세션 가지를 탄다(§4.1).

**정직한 답: 변경은 새 세션을 요구한다.** 도는 세션을 좁힐 방법은 없고, 만들지도
않는다.

운영자가 하는 일:

1. TOML 을 고친다.
2. 아무것도 더 하지 않는다. 다음 claim 이 새 세션으로 시작한다. 되돌리는 명령도,
   지우는 명령도 없다 —— `keeper_official_client_session_store.mli` 에 reset 이
   없고, `POST /api/v1/runtime/sessions/official-client/resolve` 는 `recovery_id`
   를 요구하는데 `Settled` 세션에는 그 id 가 없다.
3. 그 Keeper 의 다음 턴이 `bootstrap_floor_exceeded` 로 떨어지는지 본다(§4.2).
   떨어지면 그때는 운영자 resolve 가 필요하다. 이 값은 이 설계가 만드는 것이
   아니라 이미 있는 것이고, 표면을 줄이는 것 자체가 그 상태에서 나가는 출구다.

세션 하나를 버리는 값이 작다는 근거는 §4.2 의 `turn_count` 1,1,1,5,6,17,36 이다.

### 5.4 전제 조건 하나 —— 그리고 그것은 고침이 아니다

`reconcile_tool_surface` 는 **아무것도 기록하지 않는다.** 형제 경로인 자동 supersede
는 `:849-856` 에서 로그를 남기는데 이 가지는 남기지 않고, 턴마다 지문을 적는 곳도
없다. 그래서 지금 표면을 좁히면 N개의 대화를 버리고 그 사실의 증거를 0건 남긴다.

claim 시점에 지문과 "새로 시작/재개" 둘 중 무엇이었는지를 한 번 적는다.

**이것은 이 RFC 의 고침이 아니다.** 고침은 §5.1 이다. 이 기록이 없으면 §6 의 판정을
할 수 없어서 같은 변경에 함께 들어갈 뿐이고, 이 한 줄만 넣고 표면을 그대로 두는
단계는 없다.

### 5.5 단계 —— 각 단계가 동작을 바꾼다

**1단계.** §5.1 코드 컷 + §5.4 기록 + **여섯 antigravity Keeper 의 TOML 선언을
같은 변경에 넣는다.** 기전만 넣고 선언을 나중으로 미루지 않는다(§4.4, #31728).
선언은 여드레 호출 기록으로 사람이 고르고, 사흘 기록으로는 고르지 않는다(§2.2).
세션 여섯 개가 한 번 새로 시작한다.

**2단계.** kidsnote-pr-jira-checker 의 커넥터 선언. slack 12개 중 미호출 34.0 KB,
atlassian 31개 중 미호출 44.0 KB. 이 Keeper 를 뒤로 미루는 이유는 하나다 —— 여드레
기록 중 나흘이 비어 있어(§2.2) 근거가 가장 얇고, 유일한 `claude_code` 레인이라
bootstrap 여유를 1단계에서 먼저 보고 싶기 때문이다. 코드 변경은 없고 파일만 바뀐다.

## 6. 무엇을 재서 성공을 판정하는가

### 6.1 움직여야 하는 값

| 값 | 지금 | 재는 법 |
|---|---|---|
| 고정 레인 요청당 스키마 바이트 (Keeper 별) | lane-smith 137,391 / edgar.a.poe 151,769 / code-reviewer 89,345 | wire-capture `kind:"request"` 행, blob 복원 |
| 여드레 미호출 몫 | 50,369,025 / 152,764,547 = 33.0% | §1 의 두 창을 조인 |

이 축이 닿을 수 있는 천장: 공통 내장 95개 중 `defer_loading` 을 선언한 54개
50,125 바이트(±1, §3.2), 더하기 붙임 쪽 lane-smith ≤48,002 B(34.7%),
edgar.a.poe ≤62,374 B(41.1%), code-reviewer 0(붙임 카탈로그 없음). 실제로 얼마가
줄어드는지는 선언이 정하므로 여기에 목표 %를 적지 않는다. 아직 안 잰 값이다.

### 6.2 움직이면 안 되는 값

| 값 | 지금 | 왜 |
|---|---|---|
| 유예 레인 연속 턴 배열 변화율 | glm-coding 12.7% (55/433쌍), ollama_cloud 3.4% (43/1265쌍) | 이 선언은 후보를 줄일 뿐이므로 변화율은 그대로거나 내려간다. 올라가면 선언이 읽히면 안 되는 자리에서 읽히고 있다 |
| 표면 불일치로 인한 `config_error` 턴 | 0 (09-02..04, 문자열 자체가 코드에 없음) | #28002 이후 거절 가지가 없다. 0이 아니게 되면 §4.1 이 되돌아온 것이다 |
| `bootstrap_floor_exceeded` | 09-03 27건, 09-02·09-04 0건 | 컷 직후 일회성 증가는 예상값이다. 이후 창에서 기준선으로 안 돌아오면 표면 축소가 bootstrap 을 못 맞춘 것이고, 그 Keeper 의 선언을 되돌린다 |
| 항상 실리는 47개의 미호출 수 | 0 (사흘, 함대 전체) | 이 축의 사정권 밖이어야 한다. 0이 아니게 되면 필터가 잘못된 집합에 걸렸다 |
| `keeper_attached_tool_allow_unnamed` 경고 | 0 (선언 0개) | 선언을 넣은 뒤 이 값이 0이 아니면 오타이거나 provider 가 꺼져 있다 |

### 6.3 판정에 쓰면 안 되는 것

`GET /api/v1/dashboard/tools?keeper=<name>` 의 `effective_keeper_surface` 를
근거로 쓰지 않는다. 2026-09-04 10:51 라이브에서 이 투영은 네 Keeper 에게
바이트까지 같은 95개 / 84,854 B / 같은 다이제스트를 돌려주는데, 저장소의
`tool_surface_sha256` 은 code-reviewer 만 일치하고 lane-smith·rondo·sangsu 는
다르다. 이 투영은 붙임 도구를 아예 담지 않아서(`tool_origin` 이
`Descriptor | Instruction_skill | Composition_skill | Composition_control` 넷뿐)
lane-smith 실제 표면의 34.9%인 48,002 바이트가 보이지 않는다. 파생 값 위에
게이트를 세우지 않는다는 규칙이 그대로 적용된다.

## 7. 하지 않는 것

- **항상 실리는 47개를 줄이지 않는다.** 사흘 동안 함대 차원에서 미호출이 0이다.
  "20개쯤으로" 줄이자던 이전 계획은 철회한다. 구조적으로도 §5.1 의 필터는
  `always_loaded_builtin_tools` 를 지나지 않는다.
- **고정 레인에 목록(listing)을 만들지 않는다.** 부를 수 없는 도구의 이름을
  부르는 일이 된다(§3.1).
- **계열 단위로 자르지 않는다.** `github_*` 44개는 매일 쓰이고 Keeper 당 절반이
  죽어 있다(§2.3). 계열 단위는 두 답 다 틀린다.
- **호출 기록에서 목록을 유도하지 않는다.** 사흘 창에서 미호출이던 것 중
  17~33%가 그 앞 나흘에 불렸다(§8). 런타임이 이걸 하면 파생 값 위의 게이트다.
- **도구 개수·바이트 상한을 두지 않는다.** 상한은 증상을 덮고 어느 도구가
  사라졌는지 말하지 않는다.
- **두 번째 로스터·투영·그룹 축을 만들지 않는다.** #31728 이 지운 자리다.
- **세션을 자동으로 갈아 끼우지 않는다.** 표면 변경의 값은 사람이 파일을 고칠
  때만 발생한다.

## 8. 미해결

1. **고정 레인의 세션 간 배열 변화율.** #33009 이 지문을 남기기 시작했지만 세션
   시작 행에만 남는다. 71분 창에 6행이다. turn-record 쪽 표본은
   `tool_surface_ref` 가 2,221 공식 클라이언트 턴 중 121건(5.4%)에만 있고, 그
   표본 안에서는 연속 77쌍 전부 변화 0이다. 이 값이 정말 0인지, 못 본 94.6%
   안에서 바뀌는지 구분할 수 없다. 정하는 법: 모든 공식 클라이언트 턴에
   `tool_surface_ref` 를 기록한다.
2. **받은 집합과 호출 창의 비대칭.** 받은 쪽은 21.6시간, 호출 쪽은 여드레다.
   회전이 앞쪽 파일을 지우므로 이 조인은 오늘 이후 재현되지 않는다. 정하는 법:
   `keeper` + `tools_ref._blob.sha256` 를 하루 한 번 작은 파일로 남긴다.
3. **`tool_call` 행에 레인 표시가 없다.** 유예 턴에서 부른 도구가 그 Keeper 의
   "불렸음"으로 잡힌다. 방향은 안전하다(지방을 과소 신고한다). 가장 영향이 큰
   것은 analyst 로, 창 안에서 고정 38 요청 대 유예 816 요청이다. 정하는 법:
   `tool_call` 행에 턴의 레인을 적거나 `turn_id` 로 turn-record 와 조인한다.
4. **공식 클라이언트 네이티브 호출이 전부 로그에 남는지.** `core_builtin`
   (Execute/Read/Write/Edit/Grep/WebFetch/WebSearch) 은 남는 것을 확인했다. MCP
   브리지를 거치지 않는 호출이 있다면 그 도구들을 과대 신고한 것인데, 그 도구들은
   자르지 않는 집합이라 방향은 안전하다.
5. **17~33% 라는 창 민감도의 정확한 근거.** Keeper 별로 사흘 미호출 집합 중 그
   앞 나흘에 불린 것: analyst 9/72, code-reviewer 6/33, edgar.a.poe 18/81,
   lane-smith 28/85, rondo 17/71, sangsu 12/69. kidsnote-pr-jira-checker 는
   앞선 기록이 없어 0/92 다. 여드레보다 긴 창에서 이 비율이 어디로 수렴하는지는
   모른다.
6. **47 과 94 중 어느 집합을 §7 의 첫 줄이 지키는가.** 두 숫자가 가리키는 집합이
   다르다(§4.5). 47을 낸 명령을 확인하기 전까지 이 RFC 는 두 집합 모두 안
   건드리는 쪽으로 설계했다.
7. **`Keeper_effective_tool_surface` 가 왜 붙임 도구를 빠뜨리는가.** 빠뜨린다는
   것과 정확히 44개 `github_*` 라는 것만 확인했고, 어느 호출에서 떨어지는지는
   추적하지 않았다. 이 RFC 와 별개로 이슈 하나가 필요하다.
8. **Z.AI·Ollama Cloud 가 캐시 접두사에 도구 배열을 넣는지.** §4.3 의 관찰은
   glm-5.3 에서 "아니오"라고 말하지만 통제 실험이 아니다. 정하는 법: 라이브 설정을
   복사한 스크래치 base 에서 같은 Keeper·같은 히스토리로 배열을 고정한 턴과 스키마
   하나를 더한 턴의 `cache_read_tokens` 를 비교한다.

## 9. 워크어라운드 기준 대조

masc 의 거부 기준 일곱 항목에 대해:

- 텔레메트리-as-fix 아님: 고침은 §5.1 의 배열 변경이다. §5.4 의 기록은 판정
  전제 조건이고, 그것만 넣는 단계는 없다고 §5.4 에 적었다.
- 문자열 분류기 추가 없음: 정확 이름 일치이고, 접두사 규칙을 명시적으로 거부한다.
- N-of-M 부분 패치 아님: 한 필터가 두 계열 전부에 걸린다.
- catch-all 추가 없음.
- 증상 억제형 상한 없음: 개수·바이트 상한을 두지 않는다(§7).
- 테스트 백도어 없음.
- 같은 오타를 N곳에서 N번 고치는 형태 아님.

이 설계가 스스로 인정하는 위험은 하나다. **#31728 이 지운 축과 모양이 같다.**
답은 §4.4 와 §5.5 다 —— 기전과 선언이 같은 변경에 들어가고, 선언 없는 기전은
이 RFC 의 산출물이 아니다.
