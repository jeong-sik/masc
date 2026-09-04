---
rfc: "0409"
title: vendor 하네스를 타는 runtime — 도구를 싣지 않는 변종을 한 줄로 고른다
status: Draft
created: 2026-09-03
updated: 2026-09-03
author: Claude Opus 5 (1M context)
supersedes: []
superseded_by: null
related: ["0403"]
---

## 1. 무엇이 문제인가

official-client 레인(Codex, Claude Code, Antigravity)은 masc 도구를 **전부** 싣는다. 같은 시각 `analyst` 의 두 표면이다.

| 표면 | 도구 | 바이트 |
|---|---:|---:|
| official-client | 138 | 137,365 |
| agent-core | 57 | 64,262 |

agent-core 는 `keeper_tool_search` 하나를 더하고 82개를 뺀다 — 내장 47개(41,520 B)와 부착 35개(34,039 B), 합쳐 **요청당 75,559 B**. fleet 실측(2026-09-03 00:00–07:48Z, wire-capture 2,606행)으로 483건이 전체 배열(평균 118,791 B), 2,123건이 지연 배열(평균 63,086 B)이다. `code-reviewer` 는 몇 분 간격으로 47,047 B(glm)와 88,007 B(claude_code)를 번갈아 내므로 keeper 단위가 아니라 **요청 단위** 차이다.

그리고 vendor 도구와 겹친다. `keeper_codex_runtime.ml:425-448` 이 그 결과를 적어두었다.

> Codex ships its own file tools and neither it nor MASC can switch them off. Under `Native_read` ... the model holds a working `Write` and a refused `apply_patch` at the same time and **cannot tell them apart until one of them fails**. ... a keeper with an open write path **stopped for six hours** saying the workspace was read-only.

masc 도구가 도는 이유도 보증이 아니다. 같은 주석: Codex 가 MCP 제공 도구에 sandbox 를 적용하지 않는 것이며, 그건 "hole rather than a promise"(openai/codex#4152, 답 없이 닫힘)다. 그쪽이 막으면 `Native_read` keeper 는 쓰기 경로를 통째로 잃는다.

비용은 관측된다. 2026-09-03 `code-reviewer` 가 `codex_subscription.gpt-5.3-codex-spark` 에서 `input_rejected(bootstrap_floor_exceeded)` 로 멈췄고, operator 가 `restart_fresh` 로 풀 때까지 offline 이었다(23건, 4분 창).

## 2. 이미 시도된 것과 그 한계

**Codex 의 per-tool defer 플래그는 이미 켜져 있다.** `runtime_codex_app_server.ml:403` 이 모든 동적 도구에 `deferLoading: true` 를 단다(#31909, 2026-08-31). 같은 파일 주석이 한계를 적는다.

> The schemas **still cross this wire once at thread/start**; what changes is the context they are spent from. Measured 2026-08-30: 83 tools, 81,270 bytes of spec. The saving itself is not observable here — `turn/completed` carries no token usage.

즉 플래그를 켜도 배열은 그대로 건너가고, 절감량은 아무도 모른다. 위 `bootstrap_floor_exceeded` 는 그 플래그가 배포된 **뒤에** 났다.

**MCP `listChanged` 도 답이 아니다.** masc 는 official client 에게 MCP 서버로 붙으면서 `initialize` 에 빈 capability 를 낸다(`runtime_official_client_mcp.ml:289`, ``"tools", `Assoc []``). 다른 MCP 서버는 `listChanged: true` 를 선언하지만(`mcp_server.ml:143`) 그 알림을 **쏘는 코드가 없다** — `broadcast_tools_list_changed` 는 `mcp_server_eio_call_tool.ml:472` 의 인자로만 존재하고 본문에서 적용되지 않으며, 테스트 세 곳은 전부 `(fun () -> ())` 다. 그리고 세 레인 중 Codex 는 MCP 를 아예 안 쓰고(`thread/start` 파라미터), Antigravity 의 브리지는 POST 전용이라 서버발 알림을 나를 통로가 없다.

## 3. 제안

**도구를 싣지 않는 runtime 변종을 선언으로 고른다.**

`runtime.toml` 은 이미 같은 모양의 선례를 갖고 있다. `config/runtime.toml:418-431` 주석이 그대로 말한다.

> One model row per level is the whole mechanism — bind `claude-opus-5` three times at low/high/max and assign keepers to the level the work deserves.

reasoning-effort 를 그렇게 다루듯, 도구 표면도 그렇게 다룬다. 같은 모델을 두 번 바인딩한다.

```toml
[models.claude-code-opus-high]
api-name = "claude-opus-5"
max-context = 1000000

# 새 키. 이 모델로 바인딩된 runtime 은 masc 도구를 싣지 않는다.
[models.claude-code-opus-native]
api-name = "claude-opus-5"
max-context = 1000000
masc-tool-surface = "none"      # 기본값 "full" — 오늘의 동작

[claude_code.claude-code-opus-high]     # 지금 그대로
[claude_code.claude-code-opus-native]   # vendor 하네스만
```

keeper 를 변종에 붙이는 건 `runtime_id` 한 줄이다. 새 keeper 필드도, 새 상태도 없다.

### 왜 목록이 필요 없는가

번들 주석(`keeper_tools_agent_core_bundle.ml:552-556`)이 지연을 막는 근거는 "목록이 영영 못 부를 도구를 이름으로 올린다" 다. **목록을 주지 않으면 이름도 올라가지 않는다.** 그 도구는 지연된 게 아니라 **없다.**

그래서 이 제안은 §2 의 막힌 자리를 통째로 우회한다. `listChanged` 도, 알림 통로도, Codex 의 프로토콜 차이도 관계없다. 보내지 않을 뿐이다.

### 무엇을 보내는가

`always_loaded_builtin_tools` — 지연 선언이 없는 내장 도구다. 2026-09-03 기준 35~36개, 약 40 KB. board·task·memory·surface·time 이 여기 있으므로 keeper 는 MASC 에 계속 참여한다.

```
지금  : descriptor_tools @ composition_tools @ identity_agent_tools   138개 / 137 KB
변종  : always_loaded_builtin_tools                                    36개 /  40 KB
```

## 4. 값

**지연 대상 82개를 그 keeper 는 쓸 수 없다.** 지연이 아니라 부재다. schedule, delegate, run, ask, fusion, 부착된 github/slack 도구가 사라진다. 이건 숨겨진 열화가 아니라 **선언한 거래**다 — 변종을 고른 사람이 그걸 골랐다.

### 측정 (2026-08 + 2026-09, official-client 레인만)

`tool_calls` 를 `runtime_profile` 로 갈라, official-client 턴을 `(trace_id, keeper_turn_id)` 로 유니크하게 세고, 그 턴 중 지연 대상 도구를 하나라도 부른 비율이다. 분모는 각 keeper 자신의 official 턴 수다.

| keeper | official 턴 | 쓴 지연 도구 | **잃는 턴 비율** | 가장 자주 쓰는 것 |
|---|---:|---:|---:|---|
| `lab-sangsu` | 781 | 6 | **0.9%** | `masc_board_post_update` |
| `analyst` | 1,218 | 22 | 5.3% | `masc_config` 1% |
| `code-reviewer` | 2,578 | 28 | 5.4% | `masc_board_post_update` 1% |
| `kidsnote` | 672 | 18 | 9.2% | `masc_board_post_update` 2% |
| `rondo` | 1,319 | 21 | 13.4% | `masc_board_stats` 5% |
| `rw-e0-r9-20260820-review` | 388 | 4 | 14.9% | `masc_board_stats` 13% |
| `sangsu` | 1,746 | 25 | 22.2% | `keeper_skill` 7% |
| `taskmaster` | 1,232 | 20 | 26.8% | `masc_board_vote` 12% |
| `lane-smith` | 939 | 15 | **35.5%** | `masc_board_stats` 22%, `keeper_skill` 20% |

레인 전체로는 지연 대상 42개가 실제로 불린다(2,600+ 호출). **변종은 fleet 기본값이 될 수 없다.**

읽는 법:

- `lane-smith`(35.5%)와 `taskmaster`(26.8%)는 붙이면 안 된다. 세 턴에 한 번 잃는다.
- `lab-sangsu`(0.9%)는 붙여도 된다. 백 턴에 한 번이다.
- `code-reviewer`(5.4%)가 판단이 필요한 자리다. 열아홉 턴에 한 번 잃는 대신, 이 keeper 가 `bootstrap_floor_exceeded` 로 실제로 멈추는 쪽이다(2026-09-03, 23건, operator 가 `restart_fresh` 로 풀 때까지 offline). 무엇을 잃느냐와 아예 못 도느냐의 거래다.

`masc_board_stats`, `keeper_skill`, `masc_board_vote`, `keeper_broadcast`, `masc_config` 다섯이 상위를 차지한다. 이들만 `always_loaded` 로 되돌리면 대부분의 keeper 가 변종을 받아들일 수 있다 — 다만 그건 이 RFC 가 아니라 지연 선언 자체를 다시 재는 일이고, 그 판정은 `tool-deferral-has-a-break-even-turns-not-calls` 의 부등식을 레인별로 다시 적용해야 한다.

## 5. 하지 않는 것

- **도구 합치기.** `instructions/agent-tool-design.md` P6 이 god-tool(action 파라미터)을 금지한다.
- **`listChanged` 구현.** §2 가 그 길이 세 레인 중 둘에서만 가능하고 하나는 통로가 없음을 보인다. 이 제안이 필요 없게 만든다.
- **기존 동작 변경.** `masc-tool-surface` 의 기본값은 `"full"` 이다. 선언하지 않은 runtime 은 오늘과 같다.
- **`masc <path>` 셸 경로에 의존.** 배선 3개, 호출 0회다(2026-08~09 전체 `argv[0]=="masc"` 8건이 전부 미배선 경로 또는 `--help`). 호스트 `masc` CLI 도 답이 아니다 — 운영자용이며 board/task/memory 서브커맨드가 없다.

## 6. 구현

| 파일 | 무엇 |
|---|---|
| `lib/runtime/runtime_toml.ml` | `masc-tool-surface` 를 읽는다. `"full" \| "none"` 닫힌 합타입, 없으면 `Full` |
| `lib/runtime/runtime_schema.ml/.mli` | 모델 spec 에 필드 추가 |
| `lib/runtime/runtime_adapter.ml` | 런타임 capability 로 옮긴다 |
| `lib/keeper/keeper_tools_agent_core_bundle.ml` | `tools` 필드를 변종에서 `always_loaded_builtin_tools` 로. 분기 하나 |
| `docs/rfc/RFC-0403-*` | 관계 한 줄 — 0403 은 부착 서비스를 provider 단위로 끄고, 이건 레인 전체를 끈다 |

세 official-client runtime 은 **바뀌지 않는다.** 각자 `prepared.tools` 를 읽고, 그 값이 달라질 뿐이다.

### 테스트

- `test_keeper_attached_tools_lane_scope`: `masc-tool-surface = "none"` runtime 의 `tools` 가 `always_loaded` 와 같고, `"full"` 은 오늘 값과 같다
- `test_runtime_toml`: 키 부재가 `Full` 로 읽힌다. 알 수 없는 값은 **거절**한다 (기본값으로 조용히 떨어지지 않는다)
- `test_keeper_effective_tool_surface`: 변종의 표면 투영이 실제 배열과 일치한다

CI 는 `dune build @check` 뿐이므로 병합 전 위 셋과 `test_official_client_session_store`, `test_keeper_claude_code_runtime`, `test_runtime_codex_app_server` 를 사람이 돌린다.

## 7. 남은 미지

1. ~~어느 keeper 를 붙일지~~ — §4 가 답한다. 남는 판단은 `code-reviewer`(5.4%) 한 자리다.
2. **vendor 도구만으로 충분한가.** Codex 의 `Native_read` 는 읽기 전용 sandbox 라 쓰기가 자기 `apply_patch` 로만 가고, 그게 sandbox 에 막힌다(§1). 변종을 켜면 posture 도 같이 정해야 한다.
3. **`tool_surface_sha256`.** `keeper_official_client_session_store.ml:784-791` 이 `Settled` resume 분기에서만 `required_tool_surface_sha256` 를 `Some` 으로 둔다. 변종 전환은 sha 를 바꾸므로 그 분기에서 무슨 일이 나는지 확인이 필요하다. 11개 분기 중 1개다.
