---
rfc: RFC-0051
title: Tool Dispatch Session-Local Handles
author: jeong-sik
created: 2026-05-09
status: Draft (sketch)
supersedes: -
related:
  - RFC-0035 (cognitive IDE — tool surface context)
  - RFC-0052 (boot-time invariants — same root: implicit contract)
  - PR #13987 (fix: remove global tool hook fallbacks — reference fix)
---

# RFC-0051: Tool Dispatch Session-Local Handles

> **Status**: Draft sketch. §1 caller-context inventory at `.tmp/rfc-0051-caller-context.md` pending sub-agent.

## §0 Summary

`keeper_exec_tools.ml`의 `default_tool_search_fn` (line 103), `default_tool_searcher` (165), `set_tool_search_fn` (170) 같은 process-global setter가 **silent no-op fallback**을 만든다. caller가 session-local `search_fn`를 전달하지 않으면 global no-op이 암묵적으로 사용됨. 이는 `Unknown → Permissive Default` 안티패턴의 다른 변형 (global state implicit default).

본 RFC는 process-global setter를 **session-local handle + explicit dependency** 로 대체한다. Tool dispatch는 항상 caller가 제공하는 `tool_search_handle` 또는 `Capability.t`를 받음. missing handle은 `Error Tool_search_not_provided`로 컴파일 에러 또는 명시 실패.

## §1 Problem (caller-context inventory)

### §1.1 `keeper_exec_tools.ml` process-global setter 현황

**현재 main 코드** (`origin/main` `3904e285b8`, `lib/keeper/keeper_exec_tools.ml`):

```ocaml
(* line 103 — process-global fallback definition *)
let default_tool_search_fn ~query ~max_results =
  (* 실제로는 no-op: "No tools match this static fallback query" *)
  ...

(* line 165 — global alias *)
let default_tool_searcher = default_tool_search_fn

(* line 170 — setter: runtime에 global override *)
let set_tool_search_fn (f : tool_searcher) =
  (* internal reference 교체 *)
  ...
```

**이 문제의 핵심**: `search_fn` 인자를 session 단위로 전달하는 caller와 그렇지 않은 caller가 공존할 때, 후자는 silent no-op 경로로 빠짐. 디버깅 불가.

**caller-context (sub-agent Topic B 결과 통합 영역)**:
<!-- TODO: Topic B.1 — default_tool_search_fn / set_tool_search_fn 호출 사이트 N건 -->
<!-- TODO: Topic B.2 — 같은 패턴 다른 모듈 (keeper_tool_hooks, Tool_registry Config 의존) -->
<!-- TODO: Topic B.3 — process-global setter 시그니처 검색 lib/keeper/ 전수 -->
<!-- TODO: Topic B.4 — 각 setter 호출 site와 unset/reset 사이트 -->
<!-- TODO: Topic B.5 — 이미 session-local handle로 전환된 모듈 (RFC-0046 keeper_detail FSM hub 등) -->

### §1.2 같은 root의 다른 현상

PR #13987 본문:
> remove process-global no-op keeper tool callbacks from `Keeper_exec_tools`
> make `keeper_tool_search` fail explicitly when direct dispatch omits a session `search_fn`

→ PR #13987의 fix가 이 RFC의 Phase A 수준. 본 RFC는 그것을 확장: process-global setter **자체를 제거**, session handle **메커니즘을 도입**.

### §1.3 `Unknown → Permissive Default` + `Global → Silent Default` 스택

`instructions/software-development.md` §AI 코드 생성 안티패턴 §2:
> Unknown → Permissive Default: 알 수 없는 입력을 에러 대신 "편의 기본값"으로 매핑

본 사례는 확장:
- Unknown input (session-local search_fn 누락) → permissive default (process-global no-op)
- Global state (setter)가 그 permissive default를 암묵적으로 inject
- 결과: two-level silent failure

## §2 Goals / Non-goals

### Goals
- `keeper_exec_tools.ml`의 process-global setter 제거
- `tool_search` → session-local handle / explicit dependency 패턴 도입
- missing handle 시 컴파일 에러 또는 `Error` 반환 (silent no-op X)
- `tool_registry.ml`의 `Config` dependency → catalog surface / explicit handle

### Non-goals
- OAS tool calling protocol 자체 변경 (typed dispatch는 RFC-0047이 처리)
- test mock 모델 변경 (test mock은 당연히 explicit handle 제공)
- cross-session tool cache 전면 재설계 (Phase D)

## §3 Design

### §3.1 Session-local handle type

```ocaml
module Tool_search_handle : sig
  type t = private {
    search : query:string -> max_results:int -> Tool_search_result.t;
    catalog : unit -> Tool_catalog.t;  (* static fallback 대신 명시 catalog *)
    source : Tool_search_source.t;  (* `internal | session | fallback` 명시 *)
  }

  val make : catalog:Tool_catalog.t -> t
  val make_with_search : search:(string -> int -> Tool_search_result.t) -> t
end
```

→ caller가 반드시 `t`를 제공해야 함. 없으면 signature mismatch.

### §3.2 Capability-based dispatch (RFC-0051 Phase C)

```ocaml
module Capability : sig
  type t
  val tool_search : t -> Tool_search_handle.t option
  (* capability를 보유한 caller만 tool search 가능 *)
end
```

→ 장기 방향. Phase A-B 먼저, Phase C는 논의 후.

### §3.3 Phase 가이드

- **Phase A**: `keeper_exec_tools.ml` 에서 process-global setter 제거. `search_fn` parameter 강제.
- **Phase B**: `tool_registry.ml` `Config` dependency 제거. catalog surface 도입.
- **Phase C**: capability-based dispatch 논의 (RFC-0052과 교차)
- **Phase D**: cross-session tool cache redesign

## §4 Implementation Plan

### PR-A: Reference implementation (single module)
- `keeper_exec_tools.ml` 에서 `default_tool_search_fn` / `set_tool_search_fn` 제거
- 모든 caller가 explicit `search_fn` 전달 (sub-agent Topic B.1 결과 기반)
- PR #13987의 test coverage 재사용

### PR-B: Registry dependency inversion
- `tool_registry.ml`의 `Config` → catalog surface
- `mcp_server_eio.ml`에서 catalog init → session handle 생성 → caller에 전달

### PR-C: Capability dispatch (optional, Phase C)

### PR-D: Cross-session cache redesign (optional)

## §5 Alternatives

<!-- TODO: research/2026-05-09-process-global-state-alternatives.md 의 비교 표 통합 -->

- Erlang OTP actor model — 각 keeper를 actor로, global state 없음 (아키텍처 변화 큼)
- Akka Behavior + Context — message-driven tool dispatch (앱 언어 mismatch)
- OCaml first-class module / functor — compile-time DI (main 선호)
- Algebraic effects (Eio) — context handler로 tool search 제공 (연구 중)
- Dependency injection framework (Spring/ZIO Layer) — 런타임 오버헤드 + 복잡도

## §6 Open Questions

1. `search_fn`의 parameter는 모든 tool call 함수에 추가? or functor / first-class module?
2. `Tool_search_handle`의 `catalog` 필드가 static fallback 대신에도 PR #13987의 test coverage 호환?
3. 기존 `Keeper_metrics.metric_keeper_*` global counter와 session-local handle 사이 cross-cutting concern (metric도 global → RFC-0052과 교차)
4. sub-agent Topic B.3 결과로 추가 setter 패턴 추가 여부

## §7 References

<!-- TODO: ~/me/knowledge/research/2026-05-09-process-global-state-alternatives.md 인용 -->

- (sub-agent Topic B) capability-based security, Joe-E, E language
- (sub-agent Topic B) Erlang OTP supervision tree
- (sub-agent Topic B) OCaml first-class modules / functors
- (sub-agent Topic B) Algebraic effects (Eio context handler)
- (사내) `instructions/software-development.md` §2 process-global setter anti-pattern
- (사내) PR #13987 — reference fix (global no-op 제거)

---

🤖 Generated by /loop session — sub-agent results pending integration
