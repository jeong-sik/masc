---
rfc: RFC-0052
title: Boot-time Required Invariants (typed)
author: jeong-sik
created: 2026-05-09
status: Draft (sketch)
supersedes: -
related:
  - RFC-0001 (det/nondet boundary harness — Eio env initialization)
  - RFC-0026 (admission wiring — assumes env initialized)
  - PR #13980 (fix: fail closed without LLM bridge clock — reference fix)
  - PR #14246 (wire health probe + permissive Unknown — same root anti-pattern)
---

# RFC-0052: Boot-time Required Invariants (typed)

> **Status**: Draft sketch. Caller-context inventory at §1 to be filled from `.tmp/rfc-0050-caller-context.md` once sub-agent completes.

## §0 Summary

OCaml 5.x + Eio 기반 always-on keeper runtime에서 boot-time 초기화가 누락된 invariant(예: `Masc_eio_env.clock = None`, `Keeper_health_probe.start_probe` never wired)가 silent liveness 위반/permanent lockout을 만든다.

본 RFC는 **boot-time required invariant를 type level로 표현**하여 컴파일러가 누락을 강제하도록 한다. `Initialized.t` phantom type + `Result.t` 반환으로 None branch silent fallthrough를 closed sum type로 대체.

## §1 Problem (caller-context inventory)

### §1.1 `Masc_eio_env.clock = None` silent timeout 우회

**현재 main 코드** (`origin/main` `3904e285b8`, `lib/keeper/keeper_llm_bridge.ml:23-26`):
```ocaml
let do_timeout fn =
  match clock_opt with
  | Some clock -> Eio.Time.with_timeout_exn clock timeout_s fn
  | None -> fn ()    (* ← silent timeout bypass *)
in
```

→ clock=None 시 advertised structural timeout이 우회됨. always-on runtime에서 silent liveness 위반.

**caller-context (sub-agent Topic A.2 결과)**:

`Masc_eio_env`는 server startup 시 1회 초기화되는 module-level atomic(`lib/server/server_runtime_bootstrap.ml:1414`). 8개 호출 사이트:

| 파일 | 라인 | 패턴 |
|------|------|------|
| `lib/masc_oas_bridge.ml` | 26 | `get_opt ()` → `None -> None` fallback |
| `lib/cascade/cascade_catalog_runtime.ml` | 463 | `get_opt ()` → `None -> Eio_context.get_clock_opt ()` |
| `lib/oas_worker_named.ml` | 591 | `get_opt ()` → `None -> Eio_context.get_clock_opt ()` cascade fallback |
| `lib/keeper/keeper_llm_bridge.ml` | 14 | **`get ()` (raising)** — `clock_opt` 추출 후 `None -> fn ()` |

→ **Dual global Eio context systems**: `Masc_eio_env`와 `Eio_context`가 병존. 같은 bootstrap 시점(`server_runtime_bootstrap.ml:308-314`)에 각각 `init`/`set_*` 되나 서로 다른 atomic store. Drift 가능.

→ `keeper_llm_bridge.ml:14`는 `get ()` (uninitialized 시 예외)를 사용하고, 대부분의 keeper 코드는 `Eio_context.get_clock_opt ()` (non-raising)를 사용. 두 시스템이 섞여 있어서 한쪽이 초기화되고 다른 쪽이 안 된 상태를 컴파일러가 감지 못함.

### §1.2 `Keeper_health_probe.start_probe` — 정의되었으나 0회 호출

```ocaml
(* lib/keeper/keeper_health_probe.ml:171-177 *)
let start_probe ~sw ~base_path ~interval_sec =
  if interval_sec <= 0.0 then ()
  else Eio.Fiber.fork ~sw (fun () -> ...)
```

**mli 주석**: "Currently unused — the supervisor calls `run_once` inline."

**실제 호출**: 0건. 대신 `run_once`가 `keeper_supervisor.ml:1271`에서 30s sweep마다 inline 호출.

→ `start_probe`는 boot-time에 한 번 호출되어야 할 함수인데, 정의만 되고 호출되지 않음. 이는 `Initialized.t` phantom type이 있었다면 `start_probe`가 `[`Initialized]` 상태에서만 호출 가능하도록 설계되었을 것이고, 그 설계가 없으니 "안 써도 되는 함수"로 방치됨.

### §1.3 시그니처 검색 — 같은 패턴 다른 모듈 (sub-agent Topic A.4)

`Eio_context.get_clock_opt ()` 사용처 12건:

| 파일 | 라인 | 패턴 |
|------|------|------|
| `keeper_turn_slot.ml` | 848, 896, 956 | `Some clock -> sleep/timeout` / `None -> yield/sleep 0.005` |
| `keeper_tag_dispatch.ml` | 20, 155 | `Some -> Ok clock` / `None -> Error "requires Eio clock"` |
| `keeper_exec_voice.ml` | 26 | switch/net/clock triple destructuring |
| `keeper_unified_turn.ml` | 402, 730, 886 | `Some -> sleep` / `None -> ()` |
| `keeper_turn_cascade_budget.ml` | 754 | `Some -> sleep` / `None -> ()` |
| `keeper_shell_bash.ml` | 748 | conditional clock access |
| `keeper_agent_run.ml` | 478 | optional arg to OAS callback |

**핵심**: 모든 keeper 모듈이 개별적으로 `match Some/None`을 처리. 중앙 집중식 enforcement 없음.

**Silent fallthrough 심각도**:
- `keeper_llm_bridge.ml:28` `None -> fn ()` — **timeout 완전 우회** (Medium)
- `keeper_turn_slot.ml:848` `None -> Time_compat.sleep 0.005` — **busy-wait degradation** (Low-Medium)
- `keeper_unified_turn.ml:402` `None -> ()` — **sleep skip** (Low)

## §2 Goals / Non-goals

### Goals
- Boot-time required invariant를 type level로 표현 (컴파일러 강제)
- `None branch silent fallthrough` 패턴 제거
- 기존 `Masc_eio_env`, `Keeper_health_probe` 두 모듈에 적용 (reference implementation)

### Non-goals
- Eio fiber-local storage 재설계 (별도 RFC)
- Health probe 자체 logic 재설계 (PR #14246이 이미 처리)
- 모든 `option` 타입 제거 (legitimate optional은 유지)

## §3 Design

### §3.1 `Initialized.t` phantom type pattern

```ocaml
module Masc_eio_env : sig
  type 'state t  (* phantom: 'state = [`Uninit] | [`Initialized] *)

  val empty : [`Uninit] t
  val initialize : clock:Eio.Time.clock_ty Eio.Resource.t -> [`Uninit] t -> ([`Initialized] t, init_error) Result.t

  (* clock accessor only available on Initialized *)
  val clock : [`Initialized] t -> Eio.Time.clock_ty Eio.Resource.t
end
```

→ caller가 `[`Initialized] t`를 받기 전에는 `clock` 접근 불가. boot-time invariant가 컴파일러 강제.

### §3.2 Result-based initialize

```ocaml
type init_error =
  | Eio_clock_unavailable
  | Health_probe_thread_failed of string
  | (...) (* sub-agent Topic A 결과로 확장 *)
```

→ initialize 실패는 `Result.Error init_error`로 명시. silent None 우회 불가.

### §3.3 Phase 가이드

- **Phase 1**: `Masc_eio_env`에 phantom type 도입. 기존 caller 마이그레이션
- **Phase 2**: `Keeper_health_probe`에 동일 패턴 적용. `start_probe` 호출이 type level 강제
- **Phase 3**: 다른 boot-time invariant 모듈 식별 후 확장 (sub-agent Topic A.4 결과 기반)

## §4 Implementation Plan

### PR-A: Type infrastructure (inert)
- `lib/typed/initialized.ml{i}` — phantom type helper
- 기존 코드 변경 없음. drift-guard tests만

### PR-B: `Masc_eio_env` 마이그레이션
- caller 인벤토리: <sub-agent Topic A.2 결과>
- `Masc_eio_env.t` → `[`Initialized] t` 강제
- PR #13980의 `fail_without_clock` 패턴이 reference

### PR-C: `Keeper_health_probe` 마이그레이션
- PR #14246의 tri-valued `health_status` 위에 `Initialized.t` 추가
- `start_probe` 호출 누락이 컴파일 에러

### PR-D: 다른 모듈 확장 (sub-agent Topic A.4 결과 기반)

## §5 Alternatives

| 접근법 | 강점 | 약점 | masc-mcp 적합도 |
|---|---|---|---|
| OCaml Phantom Types | Zero runtime cost, 익숙한 문법, Jane Street 검증 | Move semantics 없음, signature 추상화 필수 | **높음** — boot phase 2-3 상태에 최적 |
| Parse Don't Validate (newtype) | 정보 보존, 중복 검증 제거 | OCaml은 typeclass 없어 string-like 사용 불편 | **높음** — `Keeper_identity` canonicalization에 직접 적용 |
| Rust Typestate | Move semantics로 강제, IDE 지원 | OCaml에 없는 언어 기능 의존 | **중간** — 개념 참고, 직접 적용은 phantom type으로 대체 |
| GADTs | Exhaustive match, 타입 학습 | 복잡도, onboarding cost | **중간** — composite lifecycle 등 복잡한 경우만 |
| Idris Dependent Types | 완전한 타입 수준 보증 | OCaml 미지원, 학습 곡선 극단적 | **낮음** — 개념 참고만 |
| Erlang OTP `init/1` | Runtime supervisor, recovery | Type level 보증 없음, silent failure 가능 | **낮음** — 본 RFC가 대체하는 대상 |

### 권장 방향

**채택: Phantom Type + Parse-Don't-Validate 조합**
- `Keeper_identity`에 `Validated_keeper_name` 모듈 추가. `type t`는 abstract, 생성자는 `normalize_all_names` 통과 시에만 노출.
- `Masc_eio_env`에 `[`Uninit]` / `[`Initialized]` phantom type 도입. `clock` 접근은 `[`Initialized]`에서만.
- 단점: 기존 `string` 기반 코드와의 경계에서 projection 함수가 필요. 타입 안전성의 대가로 수용.

## §6 Open Questions

1. `Eio.Switch` 안에서 `Masc_eio_env.initialize` 시점은? (Switch 시작 전 vs 첫 fiber)
2. `[`Initialized] t`를 모든 caller에 전달하는 cost (signature pollution)
3. 기존 `Prometheus.metric_*` global state도 같은 패턴 적용? → RFC-0051 영역
4. sub-agent Topic A.4 결과로 phantom 적용 대상 추가

## §7 References

### 외부

- Jane Street — "HOWTO: Static access control using phantom types" (https://blog.janestreet.com/howto-static-access-control-using-phantom-types/)
- Alexis King — "Parse, Don't Validate" (https://lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/)
- Rust Typestate Pattern — Farazdagi (https://farazdagi.com/posts/2024-04-07-typestate-pattern/)
- Real World OCaml — GADTs (https://dev.realworldocaml.org/gadts.html)
- Eio Fiber API — "prefer passing arguments around explicitly" (https://ocaml-multicore.github.io/eio/eio/Eio/Fiber/index.html)

### 사내

- `instructions/software-development.md` §1 Unknown → Permissive Default anti-pattern
- PR #13980 — reference implementation (Masc_eio_env.get_opt + fail_without_clock)
- PR #14246 — same root, tri-valued health_status fix
- (sub-agent Topic A.2) `Masc_eio_env` 호출 사이트 인벤토리 — `.tmp/rfc-0052-caller-context.md`
- (sub-agent Topic A.4) `None ->` silent fallthrough 패턴 검색 결과 — `.tmp/rfc-0052-caller-context.md`

---

🤖 Generated by /loop session — sub-agent results pending integration
