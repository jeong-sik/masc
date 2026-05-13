---
rfc: "0075"
title: "Keeper Tools Smoke — Exhaustive Dispatch Coverage Regression Gate"
status: Draft
created: 2026-05-14
updated: 2026-05-14
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0062", "0071", "0072", "0073"]
implementation_prs: []
---

# Keeper Tools Smoke — Exhaustive Dispatch Coverage Regression Gate

## 1. Context

`keeper_exec_tools.ml:281-575` 의 dispatch 는 54개 도구를 name-string match 로 라우팅한다. 신규 도구 추가, handler 시그니처 변경, sandbox factory 시그니처 drift 등이 *런타임에야* fail 하며, MEMORY (2026-05-12 `masc-mcp CI Build and Test skips`) 에 따르면 핵심 lib 변경 PR 의 다수가 *Detect Changed Surfaces* gate 뒤에 묶여 test job 이 SKIPPED.

RFC-0071 (exhaustive match codemod) + RFC-0072 (keeper sub-FSM transitions typed) 가 *컴파일 타임 가드*를 도입했지만, tool dispatch table 은 아직 `Tool_name.t` exhaustive 가 enforce 되지 않는다.

## 2. Problem

- dispatch table 의 모든 leaf 가 reachable 한지 *런타임* 보장 없음.
- `Tool_name.t` 에 variant 추가 시 dispatch 의 누락은 fuzzy `did_you_mean` 분기로 silent fall.
- 변경된 keeper_exec_tools.ml 가 *Detect Changed Surfaces* gate 뒤에 있어 CI 에서 test SKIPPED.
- 결과: regression 이 latent 으로 누적 (예: PR #14395 → 1주일 후 #14927 에서야 발견).

CLAUDE.md §워크어라운드 거부 기준 시그니처 #1 (telemetry-as-fix) + #3 (N-of-M) 의 회귀 가드.

## 3. Proposal — Two-layer Smoke

### 3.1 Layer A: 메타 도구 `keeper_tools_smoke`

운영자/keeper 가 호출 가능한 read-only 메타 도구. 모든 54 도구를 dry-run dispatch.

```ocaml
(* lib/keeper/keeper_tools_smoke.mli *)
type smoke_outcome =
  | Dispatched_ok
  | Skipped of skipped_reason
  | Dispatch_error of string

and skipped_reason =
  | Precondition_blocked of Tool_capability.readiness_reason  (* RFC-0073 *)
  | Side_effect_class                                          (* destructive, run 안 함 *)

val run_smoke :
  ctx:Tool_exec_ctx.t -> (Tool_name.t * smoke_outcome) list
(* Tool_name.t 위 exhaustive fold *)
```

dry-run 의미:
- `Side_effect_class` (write/git/post) 는 *mock context* 로 dispatch 만 verify, real I/O 안 함.
- `Precondition_blocked` 는 RFC-0073 probe 결과 활용 — Sandbox/Credential 없으면 Skipped.
- 나머지 (read/idempotent) 는 real dispatch 후 outcome 분류.

### 3.2 Layer B: alcotest `test_keeper_tools_smoke`

CI 에 강제되는 단위 테스트. `Tool_name.t` variant 위 exhaustive match — 신규 variant 가 smoke 정의에 누락되면 컴파일 fail.

```ocaml
(* test/test_keeper_tools_smoke.ml *)
let test_all_tools_have_smoke_definition () =
  let outcomes = Keeper_tools_smoke.run_smoke ~ctx:Mock_ctx.empty () in
  let expected = Tool_name.all in   (* 전체 variant 열거 — exhaustive *)
  Alcotest.(check int) "coverage" (List.length expected) (List.length outcomes);
  ...
```

### 3.3 CI Gate 강화

`.github/workflows/ci-build-test.yml` 의 `Detect Changed Surfaces` job 에 다음 path glob 추가:

```yaml
keeper_dispatch:
  - 'lib/keeper/keeper_exec_tools.ml'
  - 'lib/tool_dispatch.ml'
  - 'lib/keeper/tool_name.ml'
  - 'lib/keeper/tool_capability_registry.ml'
```

해당 surface 변경 시 `test_keeper_tools_smoke` *강제 실행* — Build and Test job 의 conditional skip 우회.

## 4. Code Changes

| 파일 | 변경 종류 | 추정 LOC |
|---|---|---|
| `lib/keeper/keeper_tools_smoke.ml` + `.mli` | 신규 | ~200 |
| `test/test_keeper_tools_smoke.ml` | 신규 (exhaustive + outcome 분포) | ~120 |
| `lib/keeper/keeper_exec_tools.ml` | smoke 메타 도구 dispatch 1 branch | ~10 |
| `.github/workflows/ci-build-test.yml` | path glob + force-run condition | ~15 |
| `config/tool_policy.toml` | `keeper_tools_smoke` 를 Minimal 외 모든 preset 에 노출 | ~3 |

## 5. Phases

| Phase | 범위 | 머지 조건 |
|---|---|---|
| 0 | Mock_ctx 인프라 + `smoke_outcome` 타입 | 컴파일 |
| 1 | `run_smoke` 본체 — Tool_name.t exhaustive fold | 단위 테스트 통과 |
| 2 | alcotest 가드 + CI workflow 통합 | CI green, force-run 검증 |
| 3 | 메타 도구 `keeper_tools_smoke` dispatch + tool_policy.toml 노출 | RFC-0073 Phase 1 머지 후 (precondition 의존) |

## 6. Verification

- (a) `dune build` 통과 — Tool_name.t 신규 variant 추가 시 smoke 코드 컴파일 fail.
- (b) `dune exec test/test_keeper_tools_smoke.exe` — 54 도구 모두 outcome 분류됨, `Dispatch_error` 0건.
- (c) Local sangsu turn 에서 `keeper_tools_smoke` 호출 → 응답 JSON 에 54 entry, Skipped/Dispatched_ok 분포 확인.
- (d) CI 의 `Build and Test` job 이 keeper_exec_tools.ml 변경 PR 에서 *반드시 실행*되는지 확인 (현재 skip 패턴 close).

## 7. Workaround Rejection Self-Check

- ❌ smoke 결과 *WARN dedup* — 실패는 모두 alert, demote 금지
- ❌ `Skipped` 의 silent 누적 — `Skipped` 비율 > N% 시 단위 테스트 fail
- ❌ smoke 도구를 `keeper_internal_list` 에 추가하지 않음 — 사용자/keeper 양쪽 호출 가능
- ❌ counter-as-fix — smoke 가 *count* 가 아니라 *outcome variant* 반환
- ✅ structural: Tool_name.t exhaustive 가 N-of-M 회귀 방지

## 8. Related RFCs

- RFC-0042 Closed sum type for keeper turn terminal code — 같은 exhaustive 강제 패턴
- RFC-0062 Typed `Tool_result.t` — outcome 타입의 reuse 후보
- RFC-0071 Exhaustive Match Sweep Codemod — N-of-M 안티패턴의 일반 가드
- RFC-0072 Type-encoded keeper sub-FSM transitions — 같은 typed transitions 가드 패턴
- RFC-0073 Tool Readiness Probe — `Precondition_blocked` 의 reason source
