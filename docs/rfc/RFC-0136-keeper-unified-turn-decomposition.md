---
rfc: "0136"
title: "Keeper Unified Turn — Stage Decomposition of run_keeper_cycle"
status: Draft
created: 2026-05-19
updated: 2026-05-19
author: vincent
supersedes: []
superseded_by: null
related: ["0051", "0056", "0085"]
implementation_prs: []
---

# RFC-0136 — Keeper Unified Turn Decomposition

본 RFC는 `lib/keeper/keeper_unified_turn.ml` (1943 LOC) 의 단일 함수 `run_keeper_cycle` 내부를 *stage-typed sub-module* 들로 분해하는 설계 문서다. 첫 추출 (Phase Gate) 은 본 RFC와 함께 시작하고, 나머지 stage 는 follow-up PR 로 진행한다.

---

## 1. 배경

### 1.1 현재 상태

`lib/keeper/keeper_unified_turn.ml` 은 `OAS Agent.run()` 경유 keeper turn 의 *단일 진입점* (3-path dispatcher 통합 후 RFC-? 산물). 1943 LOC 중 top-level let 정의는 단 2개 — `run_keeper_cycle` (L22-1941) + alias `run_unified_turn = run_keeper_cycle` (L1943).

interface (`.mli`, 319 LOC) 의 30+ surface 는 모두 *5 sub-module 가 정의* 하고 `keeper_unified_turn.ml` 이 `include` 로 re-export:

```ocaml
include Keeper_turn_helpers              (* 452 LOC *)
include Keeper_turn_liveness             (* 115 LOC *)
include Keeper_turn_cascade_budget       (*  873 LOC *)
include Keeper_unified_turn_types        (* 342 LOC *)
include Keeper_unified_turn_phase_plan   (*  84 LOC *)
```

총 1866 LOC 가 *이미 sub-module 로 분리*. `run_keeper_cycle` body (1920 LOC) 의 success/failure post-processing 도 이미 `Keeper_unified_turn_success` / `Keeper_unified_turn_failure` 로 분리됨 (L1904, L1920 호출).

### 1.2 남은 작업

`run_keeper_cycle` 내부에 single mega let-chain 형태로 남은 약 1813 LOC 가 본 RFC 대상이다. depth-2 nested let 8개 (setup phase L77-129) 이후 phase gate → cascade resolution → retry loop → success/failure dispatch 의 *4 stage* 가 *직렬 let-chain* 으로 펼쳐져 있다.

### 1.3 선례: RFC-0051

[RFC-0051](RFC-0051-run-named-closure-decomposition.md) 은 동일 패턴의 `keeper_turn_driver.ml` (1146 LOC) `run_named` 함수 내부 closure 3종 (`try_provider` 248 / `try_cascade` 580 / `cycle_loop` 47) 분해를 다룬다. *Draft only*, 구현 미시작. 본 RFC 는 RFC-0051 과 *parallel work* — 같은 *closure→typed-stage* 패턴을 keeper turn 의 다른 진입점에 적용한다. RFC-0051 의 동일 코드 baseline 측정 패턴 + closure dependency 분석 방법론을 차용한다.

---

## 2. Motivation

### 2.1 정량 측정

- `lib/keeper/keeper_unified_turn.ml` = 1943 LOC. 5위 godfile (top4 = keeper_registry 2131 / server_dashboard_http_keeper_api 2070 / keeper_agent_run 2044 / keeper_shell_bash 2009).
- `scripts/lint/godfile-size-regression.sh` cap = 3350 LOC. 현재 위반은 없으나 cap raise history (3000→3300→3350) 가 모두 prometheus.ml *흡수형* — *"다음 raise 는 decomposition plan 필수"* (lint script L22-26).
- *fundamental_roadmap.md Phase 5* 가 6 godfile 명시 (env_config_keeper, **keeper_unified_turn**, keeper_turn, cascade_catalog_runtime, backend_openai, keeper_prompt). 본 RFC 는 그 중 keeper_unified_turn 을 closure decomp 패턴으로 닫는다.
- conflict 빈도: `run_keeper_cycle` 가 retry/cascade/error 경로 모두 거치므로 *모든 keeper turn 관련 PR* 의 잠재 충돌 face. stage decomposition 후 *PR 단위 충돌 face* 가 stage 별로 분산.

### 2.2 구조적 결함

`run_keeper_cycle` 의 1920 LOC body 는 *3 가지 implicit early-exit + 1 main path* 를 *if/match 중첩* 으로 표현:

| Stage | Line range | LOC | Outcome |
|-------|------------|-----|---------|
| Setup | L77-129 | 53 | nested let bindings |
| **Phase Gate** | L130-242 | 113 | 3 typed outcomes (supervisor_stop / non_executable_phase / registry_missing → Ok meta or Error) |
| Cascade & tool resolution | L243-? | TBD | sets effective_cascade, tool_requirement, timeout_budget |
| Retry loop | ?-1900 | TBD | OAS Agent.run + cascade rotation + error classify |
| Success/Failure dispatch | L1904-1940 | 37 | already extracted to `Keeper_unified_turn_(success|failure)` |

Phase Gate 의 3 outcome 은 *implicit early-exit* — caller (외부 모듈) 가 *outcome 별 처리* 를 *볼 수 없다*. *Alexis King — Parse, don't validate* 의 정확한 위반: validation 결과가 *타입에 표현되지 않음*.

### 2.3 작성자 의도

mli 의 30+ helper export 는 "*Exposed for targeted tests*" / "*Exposed for regression tests*" 주석 — 작성자가 *분리 가치를 의식*하면서도 *single-file 유지*. 본 RFC 는 그 *interface 의도* 를 *file structure 에 reify*한다.

---

## 3. Scope

### 3.1 In scope

- `run_keeper_cycle` 의 1920 LOC body 를 *stage 별 typed boundary* 로 분해.
- Phase Gate 추출 (PR-1) — *closure-free typed outcome*.
- Cascade & tool resolution 추출 (PR-2) — 의존성 분석 후 결정.
- Retry loop body 추출 (PR-3+) — 잠재적으로 가장 복잡, 추가 RFC sub-doc 가능.
- 각 stage 의 dedicated `.ml` + `.mli`. caller (= keeper_unified_turn 자체) 가 *3 outcome match* 로 stage 결과 처리.

### 3.2 Out of scope

- 이미 분리된 5 sub-module (keeper_turn_helpers / liveness / cascade_budget / types / phase_plan) 의 추가 분리.
- 이미 분리된 success/failure post-processor 변경.
- mli surface 의 *행위* 변경 — *re-export 위치만* 변경.
- RFC-0051 (`keeper_turn_driver.ml` `run_named`) 동시 분해 — 본 RFC 는 keeper_unified_turn 만.

### 3.3 Non-goals

- godfile cap raise (분리 완료 후 자연 축소 기대).
- `run_keeper_cycle` 의 *행위* 변경 (semantics-preserving extraction only).
- `Agent_sdk.Agent.run` 호출 형태 변경.

---

## 4. Design

### 4.1 PR-1: Phase Gate

#### 4.1.1 현재 구조 (L130-242)

`run_keeper_cycle` 의 첫 113 LOC 본문 (depth-2 nested let setup 직후) 는 *3 가지 early-exit + main path 진입* 을 if/match 로 펼친다:

```ocaml
(* L129 *)
let supervisor_stop_at_entry =
  match Keeper_registry.get ~base_path:registry_base_path meta.name with
  | Some entry -> Atomic.get entry.fiber_stop
  | None -> false
in
if supervisor_stop_at_entry
then (
  (* L134-170: supervisor stop early-exit *)
  ...
  Ok meta)
else (
  match Keeper_registry.get_phase ~base_path:registry_base_path meta.name with
  | Some phase when not (Keeper_state_machine.can_execute_turn phase) ->
    (* L172-204: non-executable phase early-exit *)
    ...
    Ok meta
  | None ->
    (* L205-242: registry phase missing *)
    ...
    Error ...
  | Some _ ->
    (* L243+: main path *)
    ...
  )
```

#### 4.1.2 Typed boundary

Phase Gate 를 다음 sum 으로 표현:

```ocaml
(* keeper_unified_turn_phase_gate.mli *)

type phase_gate_outcome =
  | Phase_gate_proceed of Keeper_state_machine.phase
    (** Phase 가 turn 실행 가능; main path 진입. *)
  | Phase_gate_terminal_ok of Keeper_types.keeper_meta
    (** supervisor_stop 또는 non_executable_phase — `Ok meta` 반환. *)
  | Phase_gate_terminal_error of Agent_sdk.Error.sdk_error
    (** registry phase missing — `Error err` 반환. *)

val decide_and_record
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> generation:int
  -> keeper_turn_id:int
  -> append_phase_gate_decision:(turn_plan -> unit)
  -> registry_base_path:string
  -> phase_gate_outcome
```

caller (`run_keeper_cycle`) 가 *3 outcome 명시 match*:

```ocaml
match Keeper_unified_turn_phase_gate.decide_and_record
        ~config ~meta ~generation ~keeper_turn_id
        ~append_phase_gate_decision ~registry_base_path
with
| Phase_gate_terminal_ok meta -> Ok meta
| Phase_gate_terminal_error err -> Error err
| Phase_gate_proceed phase ->
  (* L243+: main path 진입 — phase 가 typed 로 전달됨 *)
  ...
```

#### 4.1.3 Closure dependency

추출 시 outer scope 의존성:

| Variable | 출처 | 처리 |
|----------|------|------|
| `config` | function arg | 인자로 그대로 전달 |
| `meta` | function arg | 인자로 그대로 전달 |
| `generation` | function arg | 인자로 그대로 전달 |
| `registry_base_path` | depth-2 let L82 | 인자로 전달 |
| `keeper_turn_id` | depth-2 let L89 | 인자로 전달 |
| `append_phase_gate_decision` | depth-2 let L103-128 | callback 인자 |
| `cycle_completed` ref | depth-2 let L77 | 추출 함수 *외부에 유지* — phase gate 는 cycle_completed 안 건드림 |

7개 closure 의존성 모두 *명시적 인자* 또는 callback 으로 변환. closure 누출 없음.

#### 4.1.4 Caller impact

- 내부 호출자 = `run_keeper_cycle` 본문 1곳.
- 외부 호출자 = 0 (Phase Gate 는 `run_keeper_cycle` 내부에서만 사용).
- mli surface 추가: `phase_gate_outcome` type + `decide_and_record` val. keeper_unified_turn.mli 에서 re-export 또는 phase_gate.mli 로 직접 노출 (decision).
- 테스트: 기존 *Exposed for regression tests* 주석에 부합하는 *직접 unit test* 추가 가능 (3 outcome 각각).

#### 4.1.5 LOC 효과

추출 후:
- `keeper_unified_turn.ml`: 1943 → 약 1830 LOC (-113).
- `keeper_unified_turn_phase_gate.ml`: 약 130 LOC (signature + 3 outcome impl + record 호출).
- `keeper_unified_turn_phase_gate.mli`: 약 30 LOC.

### 4.2 PR-N 후보 (deferred)

| PR | Scope | 예상 LOC delta | 우선순위 |
|----|-------|----------------|----------|
| PR-2 | Cascade resolution stage | -200 ~ -300 | M |
| PR-3 | Retry loop body — *separate RFC sub-doc 검토* | -800 ~ -1200 | L (복잡) |
| PR-4 | Error classification site | -100 ~ -150 | M |
| PR-5 | Setup phase cleanup (depth-2 lets → typed record) | -50 | L |

PR-2~5 의 구체 설계는 PR-1 머지 후 *follow-up RFC sub-doc* 으로 분리.

---

## 5. Risks

### 5.1 Behavior preservation

Phase Gate 추출은 *순수 mechanical* — 동일 code path 가 다른 module 에 거주. `Keeper_turn_fsm.emit_transition`, `record_pre_dispatch_terminal_observation`, `Log.Keeper.{info,error}` 호출 순서 모두 유지. 기존 test suite (현재 `summarize_turn_event_bus` 등에 *직접 test 없음* — 5장 검증 항목 참조) 가 *behavior break 시 fail* 해야 검증.

### 5.2 Test coverage gap

mli 의 *"Exposed for regression tests"* 주석에 대응하는 직접 test 가 현재 *없거나 indirect* (`run_unified_turn` 통한 transitive). 본 RFC 시작 *전* 에 *baseline test 보강* 가 별도 PR (PR-0) 으로 정당화 가능. PR-1 는 *behavior preservation* 만, *new test* 는 PR-1 includes 또는 PR-0.

### 5.3 Sub-RFC drift

PR-3 (retry loop body) 가 *전체 LOC delta 의 60%+ 차지* — 별도 RFC sub-doc 분리가 *합리*. PR-1/PR-2/PR-4 머지 후 잔여 LOC 와 closure 의존성 재측정 후 결정.

### 5.4 Workaround Rejection 자가 검사

본 RFC 는 CLAUDE.md §"워크어라운드 거부 기준" 7-체크 self-check:

| # | Pattern | 본 RFC 상태 |
|---|---------|-------------|
| 1 | Telemetry-as-fix | N/A — 구조 변경, telemetry 추가 없음 |
| 2 | String classifier | N/A — typed sum 도입 (반대 방향) |
| 3 | N-of-M migration | 부분 적용: PR 별 stage 추출 — 단, *Phase 5 godfile target 6개 중 1개* 닫기 (전체 closure) |
| 4 | Catch-all `_ ->` 추가 | N/A — Phase_gate_outcome 3 variant exhaustive |
| 5 | Cap/cooldown/dedup/repair | N/A |
| 6 | Test backdoor | N/A — mli 의 *Exposed for tests* 는 *기존* 패턴 |
| 7 | N-site mechanical fix | N/A — *1 file 내부 stage 분리*, sites 1 |

해당 없음 — 통과.

---

## 6. Validation

### 6.1 PR-1 done criteria

- [ ] `keeper_unified_turn_phase_gate.ml(i)` 생성.
- [ ] `run_keeper_cycle` 가 `decide_and_record` + 3 outcome match 로 변환.
- [ ] `dune build @check` 통과.
- [ ] `dune build @runtest` 통과 (기존 keeper turn integration test).
- [ ] *fundamental-check.yml* 의 모든 lint 통과 (no-inline-* + godfile-size).
- [ ] `wc -l lib/keeper/keeper_unified_turn.ml` 감소 ≥ 100 LOC.
- [ ] `gh pr ready` 전 *Best Programmer self-review* 수행 (workflow-pr.md §체크리스트).

### 6.2 Phase 완료 정의

- *Active*: PR-1 머지 후 status 갱신.
- *Implemented*: PR-2/3/4 모두 머지 + `run_keeper_cycle` 최종 LOC < 700 (orchestrator only).
- 본 RFC 의 `implementation_prs` frontmatter 에 머지 PR 번호 append.

---

## 7. References

- [RFC-0051](RFC-0051-run-named-closure-decomposition.md) — `run_named` closure decomposition (parallel work, draft only).
- [RFC-0056](RFC-0056-incremental-sub-library-extraction.md) — Sub-library extraction (이미 분리된 5 sub-module 패턴).
- [RFC-0085](RFC-0085-keeper-namespace-bulk-promotion.md) — keeper namespace bulk promotion (sub-module 명명 conventions).
- `lib/keeper/keeper_unified_turn.ml` — 1943 LOC, `run_keeper_cycle`.
- `lib/keeper/keeper_unified_turn.mli` — 319 LOC, 30+ surface.
- `scripts/lint/godfile-size-regression.sh` — cap 3350 LOC, decomposition mandate L22-26.
- `~/me/planning/claude-plans/joyful-tumbling-dragon.md` — fundamental_roadmap.md Phase 5 godfile target (6 files including keeper_unified_turn).
