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

**caller-context (sub-agent Topic A.2 결과 통합 영역)**:
<!-- TODO: Topic A.2 — Masc_eio_env.get () 호출 사이트 N건의 file:line + 30-50줄 발췌 -->
<!-- TODO: Topic A.5 — Keeper_health_probe.start_probe wiring 결과 (PR #14246 후) -->

### §1.2 PR #14246 (`fix(keeper): wire health probe + permissive Unknown for auto-resume`) 후속

PR #14246 본문 자기 인용 (`docs/rfc/RFC-0052-source-pr14246-quote.md`):
> This is the `Unknown → Permissive Default` anti-pattern from `instructions/software-development.md` §1, applied with the wrong polarity (Unknown → Restrictive). Same root: compressing a tri-valued health state into a boolean.

**같은 root**:
- `Masc_eio_env.clock` — `option` 타입이 boot-time 미초기화 가능성을 표현하나 caller가 `None` branch를 silent하게 처리
- `Keeper_health_probe` — `start_probe` 호출 누락 시 cache cold forever
- 둘 다: **boot-time required invariant가 type level로 강제되지 않음**

### §1.3 시그니처 검색 — 같은 패턴 다른 모듈

<!-- TODO: Topic A.4 — `match X.get ().none -> 우회` 패턴 시그니처 -->

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

<!-- TODO: research/2026-05-09-boot-time-typed-invariants.md 의 비교 표 통합 -->

- Idris dependent types (proof-carrying initialization) — OCaml 미지원
- Rust typestate pattern (newtype + builder) — OCaml에서는 phantom type으로 흉내
- "Parse, don't validate" (Alexis King) — 본 RFC의 핵심 원칙
- Erlang OTP `init/1` callback — runtime check, type level X

## §6 Open Questions

1. `Eio.Switch` 안에서 `Masc_eio_env.initialize` 시점은? (Switch 시작 전 vs 첫 fiber)
2. `[`Initialized] t`를 모든 caller에 전달하는 cost (signature pollution)
3. 기존 `Prometheus.metric_*` global state도 같은 패턴 적용? → RFC-0051 영역
4. sub-agent Topic A.4 결과로 phantom 적용 대상 추가

## §7 References

<!-- TODO: ~/me/knowledge/research/2026-05-09-boot-time-typed-invariants.md 인용 -->

- (sub-agent Topic A) OCaml phantom type / GADT 패턴
- (sub-agent Topic A) "Parse, don't validate" Alexis King
- (sub-agent Topic A) Rust typestate pattern
- (sub-agent Topic A) Idris dependent types
- (사내) `instructions/software-development.md` §1 Unknown → Permissive Default anti-pattern
- (사내) PR #13980 — reference implementation (Masc_eio_env.get_opt + fail_without_clock)
- (사내) PR #14246 — same root, tri-valued health_status fix

---

🤖 Generated by /loop session — sub-agent results pending integration
