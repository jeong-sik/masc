---
rfc: "0073"
title: "Tool Readiness Probe — Typed Precondition + Runtime Gap Disclosure"
status: Draft
created: 2026-05-14
updated: 2026-05-14
author: vincent
supersedes: []
superseded_by: null
related: ["0005", "0019", "0057", "0062", "0074", "0075", "0076"]
implementation_prs: []
---

# Tool Readiness Probe — Typed Precondition + Runtime Gap Disclosure

## 1. Context

`Keeper_exec_tools.execute_keeper_tool_call_with_outcome` (lib/keeper/keeper_exec_tools.ml:281-575) 의 5-gate dispatch 는 Stage 3 에서 policy allowlist 통과를 확인한다. 그러나 Stage 4 의 sandbox/credential precondition 은 *실행 시점에야* fail 한다. dashboard `/api/v1/keepers/:name/tools` (server_dashboard_http_keeper_api.ml:112-128) 의 `resolved_allowlist` 는 policy 통과 사실만 노출하므로, "허용되었으나 호출 불가" 도구를 turn 진입 전에 감지할 수 없다.

대표 케이스 (sangsu keeper, preset=coding, 54 tools):
- `keeper_fs_*`, `keeper_bash*`, `keeper_shell` — `turn_sandbox_factory=None` 시 error (lines 430-456)
- `keeper_bash` git 하위 명령 — `turn_sandbox_factory_git` 추가 필요 (line 445)
- `keeper_pr_*` — GitHub credential 미바인딩 시 fail (lines 480-497)

## 2. Problem

현재 코드의 구조적 결함:
- "허용 도구" 와 "실행 가능 도구" 가 *같은 set* 으로 노출된다.
- runtime precondition 은 handler 내부의 ad-hoc `match factory with None -> Error ...` 로 *산재*한다.
- 새 도구 추가 시 precondition 명세가 *암묵*이다 — 컴파일러가 미선언 도구를 catch 하지 못한다.

이는 CLAUDE.md §워크어라운드 거부 기준 시그니처 #2 (typed variant 가능한 자리에 string/match) + #3 (N-of-M 패치) 의 누적 결과다.

## 3. Proposal — Typed Precondition Registry

각 도구의 precondition 을 *컴파일 타임* 에 declare 한다. `Tool_name.t` exhaustive variant 위에서 fold.

### 3.1 신규 모듈

```ocaml
(* lib/keeper/tool_capability.mli *)
type sandbox_kind =
  | Fs_sandbox
  | Bash_sandbox
  | Git_sandbox
  | No_sandbox_required

type credential_kind =
  | Github_token
  | Slack_token
  | Web_search_key
  | No_credential_required

type readiness_precondition = {
  sandbox: sandbox_kind list;        (* AND-list. 모두 충족 필요. *)
  credentials: credential_kind list;
  config_keys: string list;          (* cdal config 의 키 존재 여부 *)
}

type readiness_state =
  | Ready
  | Blocked of readiness_reason

and readiness_reason =
  | Sandbox_missing of sandbox_kind
  | Credential_missing of credential_kind
  | Config_invalid of string
  (* Empirically discovered (2026-05-14 fleet-tool-allocation-proof probe) — see §3.4 *)
  | Lane_unavailable of {
      lane_name: string;
      missing_in_materialize: Tool_name.t list;
    }
  | Tool_naming_inconsistency of {
      requested_name: string;          (* MCP-native name, e.g. "masc_web_search" *)
      visible_surface_names: string list; (* e.g. Claude Code builtins "WebSearch" *)
    }
  | Verifier_blocked_no_open_request of {
      goal_id: string;
      goal_phase: string;
    }

val precondition_of : Tool_name.t -> readiness_precondition
(* exhaustive match. Tool_name.t 신규 variant 추가 시 컴파일러가 누락 catch. *)

val probe :
  ctx:Tool_exec_ctx.t -> Tool_name.t list -> (Tool_name.t * readiness_state) list
```

### 3.2 Runtime Probe 통합 지점

`Keeper_run_tools.prepare_agent_setup` (lib/keeper/keeper_run_tools.ml:96-127) 의 `computed_tool_surface` 산출 직후 한 번 호출. 결과를 `agent_setup.readiness_snapshot` 필드에 보관 (신규 필드, 옵셔널).

### 3.3 Dashboard API 응답 확장

`/api/v1/keepers/:name/tools` 응답에 새 객체 추가:

```json
{
  "resolved_allowlist": [ ... 54 ... ],
  "tool_denylist":      [ ... ],
  "active_masc_tool_count": 17,
  "runtime_readiness": {
    "ready":   [ "keeper_time_now", "keeper_memory_search", ... ],
    "blocked": [
      { "tool": "keeper_pr_create",
        "state": "Blocked",
        "reason_kind": "Credential_missing",
        "reason_detail": "Github_token not bound to keeper context" }
    ]
  }
}
```

기존 필드는 변경 없음 (backward-compatible additive change).

### 3.4 Empirically Discovered Variants (2026-05-14 fleet probe evidence)

위 `readiness_reason` 의 3 신규 variant (`Lane_unavailable`, `Tool_naming_inconsistency`, `Verifier_blocked_no_open_request`) 는 *spec 단계의 예상*이 아니라 *런타임 fleet probe 에서 발견된 실증 evidence*다. goal `goal-tool-allocation-proof-fleet-20260514` 의 4 keeper probe 가 다음 typed gap 을 산출:

| variant | Trigger | Evidence ref |
|---|---|---|
| `Lane_unavailable` | sangsu keeper (active+keepalive) 의 cascade=tier-group.glm-coding-with-spark 이 lane=runtime_mcp 로 진입할 때 *materialize 단계*에서 sandbox-요구 도구가 LLM 표면에서 제거. dashboard `resolved_allowlist` 는 통과했으나 materialize 단계 silent strip 으로 `masc_code_git` 미존재 → `required_tool_lane_unavailable` error. | board `p-6502d7dbfaaf89ae24e6ff749a06f914` |
| `Tool_naming_inconsistency` | tech_glutton keeper 의 cascade 가 lane=runtime_mcp 가 아니라 *local Claude SDK pass-through* 로 routing. `visible_tools` 가 `[Bash, Edit, Grep, WebSearch, Write]` 같은 Claude Code 내장 이름이라 `masc_web_search` 같은 MCP-native 이름과 매칭 실패. 같은 의미, 다른 surface naming. | board `p-15634a8257cd0c1db8092677de5a3ee2` |
| `Verifier_blocked_no_open_request` | verifier keeper 가 *자율적으로* 발견. goal phase=executing 에서 `active_verification_request_id=null` 이면 verifier 가 reject 조차 vote 불가 — `conflict: goal has no active verification request`. RFC-0074 의 paused-blocked variant 와 *직교*. | board `p-38c3289abd46b765bee74ca765c9c2ea` (verifier 가 직접 post) |

이 variant 들은 *RFC body 변경 자체가 그것의 acceptance test*: probe 가 실패하면서 variant 가 *드러났고*, 그 발견이 본문에 정식화되며, 이후 구현이 *컴파일러로 강제* 된다. 이는 RFC-0073 의 *probe-driven discovery* 패턴이 자기 자신을 검증한 첫 사례.

추가 가능한 후속 variant (직접 probe 없이도 fleet inference 로 예측):
- `Persona_profile_missing of string` — cascade 시작 자체 실패 (missing persona JSON), masc-improver / nick0cave / qa-king / janitor 의 audit 결과.
- `Registry_not_present` — keeper toml + persona 는 있으나 runtime registry 에 등록 안 됨 (autoboot 비활성 또는 boot 자체 실패), audit 결과 16/18 keeper 가 해당.

## 4. Code Changes

| 파일 | 변경 종류 | 추정 LOC |
|---|---|---|
| `lib/keeper/tool_capability.ml` + `.mli` | 신규 | ~110 |
| `lib/tool_capability_registry.ml` | 신규 (exhaustive match on Tool_name.t) | ~150 |
| `lib/keeper/keeper_run_tools.ml` | probe 호출 1곳 | ~10 |
| `lib/server/server_dashboard_http_keeper_api.ml` | JSON 응답 1 객체 추가 | ~30 |
| `dashboard/src/api/keepers.ts` | 응답 타입 1 필드 | ~5 |
| `test/test_tool_capability_registry.ml` | exhaustive 가드 + probe 단위 | ~80 |

## 5. Phases

| Phase | 범위 | 머지 조건 |
|---|---|---|
| 0 | `tool_capability` + registry skeleton — exhaustive 컴파일 가드만 | dune build 통과 |
| 1 | `precondition_of` 모든 54 도구에 대해 정의 | RFC-0075 smoke cross-check |
| 2 | dashboard API JSON 확장 + FE typing | snapshot test 통과 |
| 3 | (선택) RFC-0076 의 readiness event 와 연결 | RFC-0076 머지 후 |

## 6. Verification

- (a) `dune build` 통과 — exhaustive match 강제. 새 `Tool_name.t` variant 추가 시 컴파일 fail.
- (b) `dune exec test/test_tool_capability_registry.exe` — registry 모든 variant cover 검증.
- (c) Local sangsu boot → `curl http://localhost:8935/api/v1/keepers/sangsu/tools | jq '.runtime_readiness.blocked | length'` 가 sandbox 미부착 환경에서 ≥6 (fs_read, fs_edit, bash, bash_output, bash_kill, shell).

## 7. Workaround Rejection Self-Check

- ❌ string `is_ready` 플래그 — typed `readiness_state` variant 사용
- ❌ metric counter for "blocked tool calls" — `runtime_readiness` 는 *현재 상태* 1회성 응답
- ❌ N-of-M precondition 산재 — `Tool_name.t` exhaustive 가 모든 사이트 강제
- ❌ catch-all `_ ->` in `precondition_of` — wildcard 금지
- ✅ structural: precondition declaration 이 1 모듈에 집중

## 8. Related RFCs

- RFC-0005 Typed Capability Substrate — sandbox 추상의 base layer
- RFC-0019 Keeper Credential Unification — credential SSOT
- RFC-0057 Tool Descriptor Codegen — 장기적으로 `[@@deriving tool]` PPX 로 precondition 도 자동 생성 가능
- RFC-0062 Typed `Tool_result.t` — error channel 의 typed reason 과 통합
- RFC-0074 Sandbox & Credential Auto-provision — Blocked 도구의 실행 보장 (이 RFC 가 *진단*, 0074 가 *치료*)
- RFC-0075 Smoke Self-Test — `precondition_of` 의 exhaustive coverage 회귀 가드
- RFC-0076 Dashboard Notification — readiness 상태 변화의 표면화
