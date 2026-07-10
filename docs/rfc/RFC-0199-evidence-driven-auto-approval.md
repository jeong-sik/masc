# RFC-0199: Evidence-Driven Auto-Approval for Deterministic Verification Tasks

**Status**: Draft
**Date**: 2026-05-27
**Builds on**: [RFC-0109](./RFC-0109-cdal-goal-integration-contract.md) (typed CDAL verdict gate)
**Related**: [RFC-0088](./RFC-0088-counter-as-fix-result-propagation.md) §"String/Substring 분류기" anti-pattern (이 RFC 가 정확히 해소하는 영역)
**Tracking issue**: #19129
**Memory anchors**: `project_masc_cdal_evidence_gate_internal_antipatterns_2026_05_27`

## Implementation status update (2026-06-03): Phase A `required_evidence_typed` field removed

Phase A (below) added `task_contract.required_evidence_typed : Evidence_claim.t list`
alongside the legacy `required_evidence : string list`. That parallel typed field
has been **removed** from `task_contract` (`lib/types/types_core.ml`).

Reason: fan-in was 0. No producer ever populated it — every record literal in
`lib/` and `test/` wrote `required_evidence_typed = []`. No consumer ever read it
(`.required_evidence_typed` appears only in doc comments). Phase B's
`Deterministic_evidence_evaluator`, the sole intended consumer, was never
implemented. Keeping a permanently-empty, never-read parallel field is itself the
split-brain the RFC warns against (RFC-0088 §"String 분류기" lives on the *string*
side, but an unwired typed twin invites drift and false "already typed" signals).

What is retained: the `Evidence_claim` closed-sum schema module
(`lib/types/evidence_claim.ml{,i}`) and its schema test
(`test/test_evidence_claim_schema.ml`). The schema is correct and ready; only its
unwired attachment point on `task_contract` was dropped.

What stays live: `required_evidence : string list` remains the source of truth.
It feeds `Cdal_evidence_gate.decide` (`lib/cdal_evidence_gate.ml`), which
substring-matches each entry against completion notes / handoff refs. No gate
behavior changed.

**Phase B deferred.** When Phase B is built, it must re-introduce a typed field
*together with* the migration that resolves the open question in §"미해결 질문"
below (line: "codemod 가 기존 `required_evidence` string 을 자동 parse 할 수
있는가?"). Re-adding an empty typed field ahead of a working evaluator + migration
would just recreate the fan-in-0 scaffolding removed here. The free-form legacy
strings (e.g. `completion_notes`, `reviewable_evidence_ref`, `board post`) have no
lossless parse into the closed sum, so the migration is a real design task, not a
mechanical codemod.

The Phase A description below is kept for historical context; treat the
`required_evidence_typed` field it introduces as removed.

## Context

Verifier keeper 가 single point of bottleneck. Day 3+ stall: 33 unowned backlog tasks, 0 awaiting_verification, verifier idle. Tool policy fix (verifier denylist clear, 2026-05-27) 는 *capability* 회복일 뿐 *bottleneck 구조* 는 그대로 — 한 keeper 가 모든 verification 을 처리해야 한다는 가정이 root.

RFC-0109 가 절반 깔아둠: `Cdal_evidence_gate.decide` 가 typed CDAL verdict + `task.contract` 으로 Pass/Reject 결정 (`lib/cdal_evidence_gate.mli`). 게이트는 존재. 빠진 것은 **verdict 의 source** — 현재는 verifier 가 사람/LLM 판단으로 만들어야 함. 본 RFC 는 verdict source 를 *deterministic evidence evaluator* 로 확장한다.

## Prior art audit

`task_contract` (lib/types/types_core.ml:484-492) 가 이미 정의됨:

```ocaml
type task_contract = {
  strict : bool;
  completion_contract : string list;
  required_tools : string list;
  required_evidence : string list;   (* ← raw string list, RFC-0088 §"String 분류기" *)
  inspect_gate_evidence : string list;
  verify_gate_evidence : string list;
  links : task_execution_links;
}
```

`required_evidence : string list` 가 *raw string* — typed sum 이 아니라 자유 텍스트. 평가 path 가 string match 로 분기될 수밖에 없는 구조. RFC-0088 §1 "Counter-as-Fix" 변종: typed 분기 가능한 자리에 substring match.

## Three-phase remediation

### Phase A (P0): Typed `evidence_claim` sum schema

**Principle**: RFC-0088 §"String 분류기" 해소 — closed sum type 으로 평가 path 강제.

신설 type:

```ocaml
(* lib/cdal/evidence_claim.ml *)
type evidence_claim =
  | PR_merged of { repo : string; pr_number : int }
  | CI_pass of { repo : string; pr_number : int }
  | Tests_pass of { command : string; expected_exit : int }
  | Artifact_exists of { path : string; min_bytes : int option }
  | File_changed of { path : string; min_bytes : int option }
  | Custom_check of { id : string; payload : Yojson.Safe.t }
    (* escape hatch for evolving evidence kinds; subject to allowlist *)
[@@deriving show, yojson { strict = false }]
```

`task_contract.required_evidence` 는 backward-compat 위해 *둘 다* 받는다:

```ocaml
type task_contract = {
  ...
  required_evidence : string list;        (* legacy, deprecated *)
  required_evidence_typed : evidence_claim list; [@default []]  (* new *)
  ...
}
```

Migration: 신규 task 는 `required_evidence_typed` 사용. 기존 `required_evidence` 는 사용자가 명시 migrate (codemod 제공). 6 month sunset.

**Anti-pattern guards**:
- ❌ `_ -> Pass` catch-all 금지 — `match claim with` 은 exhaustive
- ❌ `Custom_check` 가 *string id 로 분기* 하면 안 됨 — id allowlist + payload schema 명시
- ❌ 신규 evidence kind 추가 시 *모든 evaluator* 가 컴파일 에러로 누락 감지

### Phase B (P1): `Deterministic_evidence_evaluator`

**Principle**: pure function — side effect 분리 (외부 호출은 명시적 injection).

```ocaml
(* lib/cdal/deterministic_evidence_evaluator.ml *)

type evaluation_result =
  | All_satisfied
  | Partial of { satisfied : evidence_claim list; missing : evidence_claim list }
  | Inconclusive of { reason : string; transient : bool }
    (* transient=true → backoff retry path (CI in progress 등) *)

type evaluator_deps = {
  repo_pr_check :
    repo:string -> pr_number:int ->
    [ `Merged of string (* mergedAt ISO8601 *) | `Open | `Closed | `Not_found ];
  gh_ci_check :
    repo:string -> pr_number:int ->
    [ `All_pass | `Any_fail of string list | `In_progress | `Not_found ];
  exec_command :
    command:string -> timeout_sec:int ->
    [ `Exit of int | `Timeout | `Spawn_error of string ];
  file_stat : path:string -> [ `Exists of int (* bytes *) | `Missing ];
}

val evaluate :
  deps:evaluator_deps -> claims:evidence_claim list -> evaluation_result
```

**Output → CDAL verdict 매핑** (`Cdal_evidence_gate` 가 이미 consume):

| evaluation_result | CDAL verdict |
|---|---|
| `All_satisfied` | `Satisfied` |
| `Partial { missing; _ }` | `Inconclusive { completeness_gaps = missing |> List.map render }` |
| `Inconclusive { transient = true }` | (verdict emit 보류, retry) |
| `Inconclusive { transient = false }` | `Inconclusive { completeness_gaps = [reason] }` |

`Violated` 는 evaluator 가 *직접 만들지 않음* — deterministic evidence 의 "실패" 는 보통 *gap* (CI fail = Partial / In_progress) 으로 표현. Violated 는 verifier judgment 가 명시적으로 emit 하는 verdict 로 유지 (semantic 보존).

**Anti-pattern guards**:
- ❌ Counter-as-Fix: evaluator 가 "evaluation_attempts_total" counter 만 늘리고 verdict emit 안 하면 안 됨 — 모든 branch 가 verdict 또는 명시적 retry-decision 으로 종결
- ❌ String 분류기: `gh_ci_check` 결과를 *substring match* 로 pass/fail 분기 금지 — typed variant 그대로 사용
- ❌ N-of-M: PR_merged + CI_pass 두 evidence kind 만 구현하고 나머지 후속 PR 로 미루기 금지 — Phase B 첫 PR 에서 6 kind *전부* + Custom_check escape hatch

### Phase C (P1): `workspace_task_transitions` hook

**Principle**: submit time 에만 평가. heartbeat / polling 추가 금지 (runtime budget pressure 방지).

Hook point: `lib/workspace/workspace_task_transitions.ml` 의 submit_for_verification path.

```ocaml
(* Pseudo-code *)
let handle_submit_for_verification ~task ~submitter_keeper ~notes =
  match task.contract with
  | None ->
      (* analysis-only task — 기존 RFC-0109 bypass path 유지 *)
      transition ~task ~to_state:Awaiting_verification
  | Some contract ->
      match contract.required_evidence_typed with
      | [] ->
          (* judgment-only task — verifier 필수 *)
          transition ~task ~to_state:Awaiting_verification
      | claims ->
          let result =
            Deterministic_evidence_evaluator.evaluate ~deps:evaluator_deps ~claims
          in
          match result with
          | All_satisfied ->
              emit_synthetic_verdict ~task ~verdict:Satisfied ~source:"auto_evaluator";
              (* RFC-0109 gate 가 즉시 decide → Pass → auto-transition *)
              transition ~task ~to_state:Done ~auto_approved:true
          | Partial { missing; _ } | Inconclusive { transient = false; _ } ->
              emit_synthetic_verdict ~task ~verdict:Inconclusive ~source:"auto_evaluator";
              (* gate 가 reject 또는 awaiting_verification 으로 두기 → verifier 가 본다 *)
              transition ~task ~to_state:Awaiting_verification
          | Inconclusive { transient = true; reason } ->
              (* CI in progress 등 — task 상태 유지, submitter 에 hint 만 *)
              return_to_submitter ~hint:reason
```

**Audit trail**: `auto_approved:bool` field 를 task transition event 에 명시. Dashboard / `masc_task_history` 에서 *누가 (verifier human / verifier LLM / auto evaluator)* 결정했는지 항상 식별 가능.

**Verifier veto path** (governance escape hatch): auto-approved task 가 `Done` 상태여도 verifier 가 `transition reject` 로 사후 거부 가능. Reject 시 task 가 `Done_rejected` (신설) 상태로 전이 — *complete-but-disputed* semantic. RFC-0109 의 verdict 흐름 변경 없음.

### Phase D (P2): Default policy + opt-out

- **Default**: task 가 `required_evidence_typed = []` 면 *judgment-only* 로 취급 — 기존 verifier-필수 path. Safe default.
- **Opt-in friction 완화**: `masc_add_task` 에 evidence claims 를 *task description 에서 추출* 하는 syntactic sugar (예: `[evidence: pr#19108, ci#19108]`). LLM 이 task 작성 시 자연스럽게 명시.
- **Opt-out**: task 작성자가 deterministic claim 을 명시했어도 `verifier_required: true` 로 인간 검증 강제 가능.

## Boundaries (4)

1. **Auto-approve 대상**: `required_evidence_typed` 가 *비어있지 않고* `evaluate` 가 `All_satisfied` 인 task 만
2. **Verifier 필수 대상**: `required_evidence_typed = []` 또는 `evaluate` 가 `Partial`/`Inconclusive` 인 task
3. **Default**: 미지정 = `[]` = judgment-only (안전 default)
4. **Veto**: verifier 가 사후 `transition reject` 로 auto-approved 도 거부 가능

## Open questions

1. `required_evidence_typed` migration — codemod 가 기존 `required_evidence` string 을 자동 parse 할 수 있는가? 또는 manual rewrite 만?
2. `exec_command` 의 sandbox boundary — auto evaluator 가 keeper sandbox 와 같은 격리에서 실행? 별도 dedicated sandbox?
3. `repo_pr_check` rate limit — 33 backlog × N evidence/task 가 한 burst 로 평가되면 API 한도 문제. Cache TTL (RFC-0109 의 `[gh_cache]` 와 통합 가능)?
4. Audit trail 의 persistence — `dated_jsonl` 사용? 별도 store?

## Phase 의존성

```
Phase A (typed schema)
   │
   ├─→ Phase B (evaluator)
   │       │
   │       └─→ Phase C (transition hook)
   │              │
   │              └─→ Phase D (default policy + DX)
   │
   └─→ (parallel) codemod for migration
```

각 Phase 는 *독립 PR* 가능. Phase A 가 가장 작음 (type 추가, evaluator 없이 just compile-clean). Phase B 가 가장 큼 (deps wiring + 6 evidence kinds).

## Workaround Signature Gate

본 RFC 는 *anti-pattern 해소* 이지 추가 아님:
- Counter-as-Fix ❌ — evaluator 가 *decision* 을 emit, counter 만 늘리지 않음
- String 분류기 ❌ — `evidence_claim` 이 closed sum, string 평가 path 전부 제거
- N-of-M ❌ — Phase B 첫 PR 에서 6 evidence kind *전부* 구현
- cap/cooldown/dedup/repair ❌ — transient retry 는 *typed result variant* 로 명시, magic timeout 없음

## Memory & follow-up

- `<MASC_BASE>/.masc/config/personas/verifier/profile.json` 의 denylist clear (2026-05-27) 는 본 RFC 와 *독립* 으로 즉시 효과
- 본 RFC 머지 후 `verifier` persona 의 expected throughput 이 *판단 task* 만으로 줄어듦 → active-goal assignment와 runtime policy 재검토 필요 (별도 issue)
- RFC-0109 의 `cdal_evidence_gate.evidence_entry_satisfied:94-129` 의 dead Inconclusive arm (3일 fleet 0건) — 본 RFC 의 evaluator 가 *그 arm 을 활성화* (deterministic Inconclusive 가 새 source) → Issue #18840 의 priority 재평가 필요
