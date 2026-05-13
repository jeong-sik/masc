---
rfc: RFC-0053
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

# RFC-0053: Tool Dispatch Session-Local Handles

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

**caller-context (sub-agent Topic B 결과)**:

#### B.1 `keeper_exec_tools.ml` — `set_tool_search_fn`가 dead code

| 심볼 | 라인 | 상태 |
|------|------|------|
| `default_tool_search_fn` | 103 | static schema fallback, 외부 호출 0건 |
| `default_tool_searcher` | 165 | `default_tool_search_fn` alias |
| `tool_searcher` ref | 168 | global mutable ref |
| `set_tool_search_fn` | 170 | **정의되었으나 코드베이스 전체에서 0회 호출** |

→ setter는 존재하지만 아묏도 호출하지 않는다. 실제 데이터 흐름은 `~search_fn` optional parameter를 통해 전달됨. global ref는 **죽은 패턴**. `lib/keeper/keeper_exec_tools.ml:170`에서 정의만 되고 호출되지 않음.

#### B.2 이미 존재하는 session-local pattern (canonical example)

`keeper_run_tools.ml:202-237,322`:
```ocaml
let local_search_fn_ref : (query:string -> max_results:int -> Yojson.Safe.t) ref =
  ref (fun ~query:_ ~max_results:_ -> `Assoc [ "results", `List [] ])

(* line 237: explicit parameter 전달 *)
~search_fn:(fun ~query ~max_results -> !local_search_fn_ref ~query ~max_results)

(* line 322: initialization 후 재할당 *)
local_search_fn_ref := fun ~query ~max_results -> ...
```

→ closure-scope local ref + explicit `~search_fn` parameter + reassignment after init. 이것이 RFC-0053이 추구하는 패턴이며 **이미 작동 중**.

`.mli:122-124` 주석:
> "Prefer passing `~search_fn` to `execute_keeper_tool_call` for session-scoped search."

→ 인터페이스 주석이 이미 session-local을 권장. 코드가 주석을 따라잡지 못한 상태.

#### B.3 Global setter 전수 검색 (lib/keeper/ 8개 모듈)

| 모듈 | 심볼 | 사용 여부 | RFC-0053 관련 |
|------|------|----------|--------------|
| `keeper_exec_tools` | `tool_searcher` ref | **Dead** (fallback only) | **Primary target** |
| `keeper_exec_tools` | `keeper_tool_call_recorder` ref | Used (`mcp_server_eio.ml:130`) | Secondary |
| `keeper_tool_registry` | `masc_schemas_state` ref | Used | Out of scope |
| `keeper_exec_shared` | `tag_dispatch_fn` ref | Used | Out of scope |
| `keeper_event_bus` | `bus_ref` | Used | Out of scope |
| `keeper_keepalive_signal` | `grpc_client_ref` | Used | Out of scope |
| `keeper_compact_audit` | `store_ref` | Used | Out of scope |

→ RFC-0053 Phase A 범위는 `keeper_exec_tools`의 `tool_searcher` / `set_tool_search_fn` 제거에 집중.

### §1.2 같은 root의 다른 현상

PR #13987 본문:
> remove process-global no-op keeper tool callbacks from `Keeper_exec_tools`
> make `keeper_tool_search` fail explicitly when direct dispatch omits a session `search_fn`

→ PR #13987의 fix가 이 RFC의 Phase A 수준. 본 RFC는 그것을 확장: process-global setter **자체를 제거**, session handle **메커니즘을 도입**. 특히 `set_tool_search_fn`이 dead code임이 확인되어, 제거가 breaking change가 아님.

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

| 접근법 | 강점 | 약점 | masc-mcp 적합도 |
|---|---|---|---|
| Eio Capability Passing | Idiomatic OCaml 5, zero-cost, 공식 권장 | Compile-time 보증 없음, runtime convention | **높음** — 즉시 적용 가능, `ref` → capability 객체 |
| Erlang OTP Supervision | Process isolation, fault containment | Eio fiber는 cooperative, true isolation 없음 | **중간** — supervisor 패턴 참고, fiber isolation은 convention |
| Object-Capability (Joe-E) | 강력한 보증, least privilege | OCaml은 static verifier 없음, taming cost | **중간** — 개념 참고, module boundary로 approximate |
| Algebraic Effects (Koka) | 타입 수준 effect tracking | OCaml 5는 static tracking 미지원 | **낮음** — 개념 참고, explicit capability로 대체 |
| OCaml First-Class Modules | Compile-time DI, testability | Syntactic weight, 대규모 적용 churn | **중간** — policy/config 모듈에 점진적 적용 |
| Spring/ZIO Layer DI | 런타임 wire-up, 유연성 | 런타임 오버헤드, 복잡도, 언어 mismatch | **낮음** — OCaml ecosystem 미지원 |

### 권장 방향

**채택: Eio Capability Passing + Explicit Record Passing**
- `keeper_run_tools.ml`의 10+ `ref` 필드를 `Tool_execution_context.t` record로 통합. 실행 시작 시 생성, 완료 후 immutable snapshot으로 freeze.
- `keeper_tool_policy.ml`의 `policy_config ref`를 `Policy_capability.t`로 변환. 필요한 함수는 capability를 명시적 인자로 받음.
- 단점: 함수 시그니처가 길어짐. `~tool_context` labeled argument로 완화. explicitness의 대가로 수용.

## §6 Open Questions

1. `search_fn`의 parameter는 모든 tool call 함수에 추가? or functor / first-class module?
2. `Tool_search_handle`의 `catalog` 필드가 static fallback 대신에도 PR #13987의 test coverage 호환?
3. 기존 `Keeper_metrics.metric_keeper_*` global counter와 session-local handle 사이 cross-cutting concern (metric도 global → RFC-0052과 교차)
4. sub-agent Topic B.3 결과로 추가 setter 패턴 추가 여부

## §7 References

### 외부

- Eio Fiber API — "prefer passing arguments around explicitly" (https://ocaml-multicore.github.io/eio/eio/Eio/Fiber/index.html)
- Eio 1.0 paper — capability-passing style (https://kcsrk.info/papers/eio_ocaml23a.pdf)
- Erlang OTP Supervision Trees (https://adoptingerlang.org/docs/development/supervision_trees/)
- Joe-E NDSS 2010 — object-capability discipline (https://people.eecs.berkeley.edu/~daw/papers/joe-e-ndss10.pdf)
- Algebraic Handler Lookup Comparison — Koka vs OCaml 5 (https://interjectedfuture.com/algebraic-handler-lookup-in-koka-eff-ocaml-and-unison/)
- OCaml First-Class Modules (https://ocaml.org/manual/5.4/firstclassmodules.html)

### 사내

- `instructions/software-development.md` §2 process-global setter anti-pattern
- PR #13987 — reference fix (global no-op 제거)
- (sub-agent Topic B.1) `default_tool_search_fn` / `set_tool_search_fn` 호출 사이트 — `.tmp/rfc-0053-caller-context.md`
- (sub-agent Topic B.3) process-global setter 시그니처 검색 결과 — `.tmp/rfc-0053-caller-context.md`

---

🤖 Generated by /loop session — sub-agent results pending integration
