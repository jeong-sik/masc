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
