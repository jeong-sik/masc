---
rfc: "0071"
title: "Exhaustive Match Sweep Codemod — Eliminate N-of-M `_ -> false/None` Anti-Pattern"
status: Draft
created: 2026-05-12
updated: 2026-05-12
author: yousleepwhen
supersedes: []
superseded_by: null
related: ["0042", "0068"]
implementation_prs: []
---

# RFC-0071: Exhaustive Match Sweep Codemod — Eliminate N-of-M `_ -> false/None` Anti-Pattern

- **Drives**: closes the recurring `fix(exhaustive)` PR stream (19+ PRs in the last 200 commits) — see §1 inventory.
- **Anti-pattern target**: CLAUDE.md §AI 코드 생성 안티패턴 #4 (FSM Sparse Match / `_ -> false` Catch-all) + §워크어라운드 거부 기준 #3 (N-of-M 패치, abstraction 부재 admits).
- **Related**: RFC-0042 (closed sum for keeper turn terminal code — precedent for closed-variant migration), RFC-0068 (typed `Keeper_turn_disposition` — same family).
- **Non-goal**: this RFC does not ship the codemod itself. It claims the number, fixes the scan methodology, and pins the migration plan. Codemod implementation lands in a follow-up PR per §4.

## 1. Motivation

### 1.1 Observed N-of-M pattern

Over the last 200 commits on `origin/main`, the following `fix(exhaustive)`-family PRs landed — each closing a *single* match site over a *closed variant type* that had been silently masked by a wildcard arm:

| # | PR | Type covered | Sites closed |
|---|----|--------------|---------------|
| 1 | #14866 | `Chronicle_types.epoch_status` (followup) | 3 |
| 2 | #14864 | keeper phase-match | 2 |
| 3 | #14861 | `request_status × verdict` | 1 |
| 4 | #14857 | keeper phase (`is_running`) | 1 |
| 5 | #14853 | closed-sum event type | 9 |
| 6 | #14852 | `Chronicle_types.epoch_status` | 2 |
| 7 | #14849 | tool_name predicates | 3 |
| 8 | #14847 | `verdict × verdict` tuple | 1 |
| 9 | #14842 | `Resilience_outcome` predicates | 3 |
| 10 | #14829 | `Keeper_turn_terminal` (`is_unknown_empty`) | 1 |
| 11 | #14823 | `dashboard_attention.classify_agent` | n |
| 12 | #14819 | `is_oas_timeout_budget_error` (2nd N-of-M followup) | 1 |
| 13 | #14816 | `Autonomous_phase.can_transition` tag-pair | 1 |
| 14 | #14812 | `Goal_phase` (followup to #14790) | 1 |
| 15 | #14810 | `cascade_health_tracker.outcome_matches` | 1 |
| 16 | #14806 | `cascade_strategy.kind` tuple | 1 |
| 17 | #14790 | `Goal_phase` (`normalize_goal`) | 1 |
| 18 | #14779 | `tool_effect_class` | 1 |
| 19 | #14698 | `entry_actions_for` new_phase (/loop iter 2) | 1 |

총 19개 PR, 누계 ~40 사이트 close. 매 PR 본문은 동일한 형태로 "이 한 사이트만 막았다" — sibling site 가 있다는 사실은 *다음* PR 본문에서 드러난다.

이는 CLAUDE.md §워크어라운드 거부 기준 #3 (N-of-M 패치, abstraction 부재 admits) 의 정의 그대로다:

> "PR #X only fixed M/N sites"로 자인하며 나머지 사이트를 별도 PR로 메움. 같은 변환을 여러 사이트에서 따로 하는 것 자체가 abstraction 실패. 컴파일러가 모든 사이트를 강제 변환하지 못함.

memory `feedback_exhaustive_match_sweep_type_plus_arm.md` 의 진단도 동일하다: PR #14790 → #14812, PR #14716/#14762 → #14819 둘 다 sibling site 같은 *type + arm shape* 패턴을 4 iteration 후에야 발견. `rg 'TypeQualifier\.SpecificCtor' lib/` 0.1초 작업이 매 PR 마다 누락.

### 1.2 누적 규모

본 RFC 작성 시점 (`origin/main` HEAD `7fb63d3b5`) `lib/` 의 catch-all 통계:

| RHS | 사이트 수 | 비고 |
|-----|-----------|------|
| `\| _ -> false` | 242 | predicate 함수의 catch-all |
| `\| _ -> None` | 781 | partial 함수의 catch-all |
| `\| _ -> ()` | 21 | unit side-effect 의 catch-all |
| **합계** | **1044** | 387 개 파일에 분포 |

이 1044 사이트가 *전부* 위반은 아니다. 일부는 *open* 타입 (`string`, `int`) 매칭으로 catch-all 이 의미상 필수다. RFC §2 의 inventory triage 가 이 분류를 수행한다.

도메인별 분포 (상위):

| 디렉토리 | 사이트 수 | 파일 수 |
|----------|-----------|---------|
| `lib/keeper/` | 256 | 89 |
| `lib/cascade/` + `lib/cascade_decl/` | 63 | 18 |
| `lib/model_inference_metrics.ml` 단일 | 18 | 1 |
| `lib/telemetry_unified.ml` 단일 | 14 | 1 |

상위 hotspot 만 봐도 *변환 자체가 abstraction 으로 격상되어야 할* 규모.

### 1.3 왜 site-by-site 가 작동하지 않는가

1. **Sibling site 탐색은 사람 작업**: PR 작성자가 한 줄 고치고 sibling 을 찾을 의무가 없다. 컴파일러도 `_` 가 있으면 만족한다.
2. **새 catch-all 이 계속 추가됨**: 이전 fix(exhaustive) 와 동일 도메인에 새 `| _ -> false` 가 후속 PR 로 들어온다 (e.g. #14790 직후 #14812 는 같은 `Goal_phase` 의 다른 함수).
3. **AI 에이전트의 학습**: CLAUDE.md §워크어라운드 거부 기준 도입부 — "한 번 워크어라운드가 main 에 들어가면 이후 PR 은 그 패턴을 합리적 선례로 학습한다." 1044 사이트는 강력한 선례.

## 2. Scope

### 2.1 Inventory scan (RFC-mandated 진단)

작성/리뷰어가 사용할 단일 명령:

```bash
# 1) 전체 catch-all 사이트 enumerate
rg -n --type ocaml '^\s*\|\s*_\s*->\s*(false|None|\(\))\s*$' lib/ \
  > /tmp/rfc-0071-catchall.txt

# 2) 사이트의 enclosing match 의 scrutinee 타입 추출
#    (codemod 가 정식으로 OCaml AST 로 함; 진단 단계는 컨텍스트 grep 으로 충분)
rg -n --type ocaml -B 20 '^\s*\|\s*_\s*->\s*(false|None|\(\))\s*$' lib/ \
  | rg -A 1 'match\s+' \
  > /tmp/rfc-0071-context.txt

# 3) FSM-shaped 타입 (이름이 _state, _phase, _disposition, _class 로 끝나는 변종 + keeper_types.mli 안의 변종) 으로 좁히기
rg -n --type ocaml 'type\s+[a-z_]+_(state|phase|disposition|class)\s*=' lib/ \
  > /tmp/rfc-0071-fsm-types.txt
```

본 RFC 와 함께 lands 되는 inventory 산출물 (§4 Phase 0):

- `docs/rfc/RFC-0071-inventory.csv` — `(file, line, ctor_type_guess, rhs, triage_class)` 5-열. 1044 행. CSV 가 *RFC main spec 의 부속 자료* (RFC-0047 의 `RFC-0047-caller-inventory.txt` 선례).

### 2.2 Triage classification (RFC §3.1 가 규칙 정의)

각 사이트를 다음 셋 중 하나로 분류:

- **(a) Intentional open-variant catch-all** — scrutinee 가 `string`/`int`/외부 라이브러리 open variant. 유지하되 *반드시* `(* WORKAROUND: open-variant scrutinee, intentional catch-all *)` 주석 추가 (CLAUDE.md 워크어라운드 주석 규약). 예상 비율: 30–40%.
- **(b) Lazy catch-all over closed variant** — scrutinee 가 closed sum 인데 wildcard 로 닫음. *모든 arm 을 명시적으로 enumerate* 하는 codemod 대상. 예상 비율: 50–60%.
- **(c) Closed-set guard** — predicate 형태 (`fun x -> match x with | A | B -> true | _ -> false`). memory `feedback_exhaustive_match_sweep_type_plus_arm.md` 의 처방대로 *positive arm 의 sibling 전부 + 명시적 `false` 분기* 로 rewrite. 예상 비율: 10–20%.

### 2.3 Out of scope

- `try ... with _ -> None` — 예외 catch-all. 별도 anti-pattern (RFC-0070 §3.5 에서 일부 처리). 본 RFC 는 *value-level* match 만.
- Dashboard TypeScript 의 `switch (x) { default: }` — TypeScript 진영의 동일 패턴은 별도 RFC.
- `if-then-else` 사슬의 final `else` — 본 RFC 는 `match` 만.

## 3. Design

### 3.1 Triage rule (RFC §2.2 의 규칙 정식화)

코드모드는 사이트별로 다음 결정 트리를 따른다:

```
입력: (file, line, scrutinee_type)
│
├─ scrutinee_type 이 open type (string/int/외부) 인가?
│  ├─ yes → (a) Intentional. comment 삽입만, 변환 X.
│  └─ no  → 다음 단계
│
├─ enclosing match 가 predicate (RHS 가 true/false 만) 인가?
│  ├─ yes → (c) Closed-set guard. positive arm 의 sibling = scrutinee_type 의
│  │         모든 다른 ctor 를 명시적으로 `| Ctor _ -> false` 로 enumerate.
│  └─ no  → 다음 단계
│
└─ (b) Lazy catch-all. scrutinee_type 의 모든 ctor 를
       명시적으로 enumerate. `_ -> None` 은 `Some` arm 의 sibling 을
       전부 `| Ctor _ -> None` 으로 펼침.
```

예시 (Goal_phase #14790 회고):

```ocaml
(* BEFORE — N-of-M lazy catch-all *)
let normalize_goal phase =
  match phase with
  | Goal_phase.Awaiting_verification -> ...
  | _ -> None                                  (* (b) lazy *)

(* AFTER — codemod output *)
let normalize_goal phase =
  match phase with
  | Goal_phase.Awaiting_verification -> ...
  | Goal_phase.Active                -> None
  | Goal_phase.Verified              -> None
  | Goal_phase.Rejected              -> None
  | Goal_phase.Withdrawn             -> None
```

새 ctor 가 `Goal_phase` 에 추가되면 컴파일러가 *모든* normalize_goal-shaped site 를 reject — N-of-M 회피.

### 3.2 Codemod sketch

코드모드 자체는 본 RFC 의 후속 PR 에서 구현한다. API 윤곽:

```ocaml
(* tools/codemod/exhaustive_match_sweep.mli — sketch, NOT shipped in this PR *)

type site = {
  file        : string;          (* lib/keeper/keeper_registry.ml *)
  line        : int;             (* 1-based, catch-all 의 시작 줄 *)
  scrutinee   : ctor_type;       (* AST 로부터 추론 *)
  triage      : [ `Intentional | `Lazy_catch_all | `Closed_set_guard ];
}

and ctor_type = {
  type_path   : string;          (* Goal_phase.t *)
  ctors       : ctor_decl list;  (* [Awaiting_verification; Active; ...] *)
}

val scan      : root:string -> site list
(** RFC §2.1 의 rg 단계를 ppxlib 기반 AST 스캔으로 대체. *)

val rewrite   : site -> Diff.t
(** 단일 사이트의 unified diff. (a) 는 주석 삽입 diff,
    (b)/(c) 는 catch-all 제거 + sibling arm 펼침 diff. *)

val plan_pr   : site list -> Diff.t list
(** 동일 (file, scrutinee_type) 그룹을 묶어 PR 단위 diff 생성.
    한 PR = 한 type 의 모든 sibling site. memory feedback
    feedback_exhaustive_match_sweep_type_plus_arm.md 의 처방 그대로. *)
```

구현 기반: `ppxlib` Ast_iterator + `compiler-libs` 의 typed AST (Tast). scrutinee 타입 추론은 dune 의 `.cmt` 파일에서 읽는다 — `dune build @check` 이후 모든 `.cmt` 가 `_build/default/lib/.../foo.cmt` 에 위치.

codemod 출력 형식: 단일 unified diff per `(file, scrutinee_type)`. PR 작성자는 `git apply` 후 dune build 로 검증.

### 3.3 Pre-commit lint (`scripts/lint/exhaustive-guard.sh`)

CI 가 net-new catch-all 을 차단하기 위한 가드. 기존 `scripts/lint/no-unknown-permissive-default.sh` 와 동일 스타일 (allowlist 기반, symbol-anchored).

```bash
#!/usr/bin/env bash
# scripts/lint/exhaustive-guard.sh — sketch, NOT shipped in this PR
#
# Detect: net-new `| _ -> (false|None|())` catch-all over an FSM-shaped type
#         introduced in the current diff vs origin/main.
#
# FSM-shaped type =
#   - 타입명이 `_state | _phase | _disposition | _class` 로 끝남, 또는
#   - `lib/keeper/keeper_types.mli` 의 closed sum 정의 안에 있음.
#
# Allowlist entry forms:
#   path::symbol     — symbol-anchored, RFC-0071 inventory 의 (a) Intentional 사이트.
#
# Exit codes:
#   0 — clean
#   1 — net-new violation
#   2 — stale allowlist entry
```

allowlist (`scripts/lint/exhaustive-guard.allowlist`) 는 RFC-0071 inventory 의 (a) Intentional 사이트로 seed. (b)/(c) 사이트가 codemod 로 해소되면 allowlist 에 *들어가지 않는다* — lint 가 직접 차단.

#### 3.3.1 SSOT 한 곳에서 FSM-shaped 타입 enumerate

매 lint 실행마다 grep 으로 타입을 추론하면 false-negative 위험 (regex drift). 본 RFC 는 별도 manifest 를 둔다:

```
scripts/lint/exhaustive-guard.fsm-types.txt
# lib/keeper/keeper_types.mli::keeper_phase
# lib/keeper/keeper_types.mli::keeper_state
# lib/chronicle/chronicle_types.mli::epoch_status
# ...
```

manifest 갱신은 RFC-0071 의 inventory regeneration step (§4 Phase 5) 에서 자동.

### 3.4 Containment

| 기존 도구 | 본 RFC 와의 관계 |
|-----------|------------------|
| `scripts/lint/no-unknown-permissive-default.sh` | 인접 anti-pattern (unknown→permissive). 둘 다 catch-all 의 변종. `exhaustive-guard.sh` 는 *값 자체가 사라지는* (false/None/()) 케이스, `no-unknown-permissive-default` 는 *concrete ctor 가 silent 하게 선택되는* 케이스. 도구 셋이 보완적. |
| RFC-0042 (closed sum for keeper turn terminal code) | 동일 가족. RFC-0042 는 *특정 타입* 의 closed-sum 화. 본 RFC 는 *범용 sweep*. RFC-0042 결과로 생긴 닫힌 sum 위에서 본 RFC 의 codemod 가 동작. |
| RFC-0068 (typed `Keeper_turn_disposition`) | 동일 가족. 본 RFC 의 inventory 가 RFC-0068 가 정의한 disposition 타입의 모든 catch-all 사이트를 enumerate. |
| 기존 fix(exhaustive) PR 흐름 | Phase 0–5 머지 후 *흐름 자체가 사라진다*. CI 가 차단. |

## 4. Migration

| Phase | Deliverable | RFC dependency | Risk |
|-------|-------------|----------------|------|
| **0** | 본 RFC + `docs/rfc/RFC-0071-inventory.csv` 부속 자료 | none | LOW — docs only |
| **1** | `scripts/lint/exhaustive-guard.sh` + allowlist seed (inventory 의 (a)/(b)/(c) 분류 결과 전부 allowlist 에) — *advisory* (PR 머지 차단 안 함) | Phase 0 | LOW — 측정만 |
| **2** | `tools/codemod/exhaustive_match_sweep` 구현 (§3.2 sketch 의 실체) | Phase 0 | MEDIUM — ppxlib + .cmt 의존 |
| **3** | codemod 1차 적용: 단일 PR per `scrutinee_type`. *큰 도메인부터*: `Goal_phase`, `keeper_phase`, `epoch_status`, `Resilience_outcome`. 한 PR 안에 같은 타입의 sibling site 전부. | Phase 2 | MEDIUM — large diff, but compiler-verified |
| **4** | codemod 2차: 나머지 closed-variant 사이트 일괄 | Phase 3 | MEDIUM — 동일 패턴 |
| **5** | allowlist 의 (b)/(c) 항목 제거 → `exhaustive-guard.sh` 를 *blocking* CI 로 승격. 동시에 `fsm-types.txt` manifest 첫 commit. | Phase 4 | LOW — compiler 가 이미 enforce |

각 Phase 는 독립적으로 revertable. **Phase 3 는 한 PR 안에 같은 type 의 sibling site 전부를 묶는 것이 핵심** — 이게 정확히 N-of-M 의 반대.

### 4.1 Single-PR-per-type 의 근거

memory `feedback_exhaustive_match_sweep_type_plus_arm.md` 처방 그대로:

> Exhaustive-match cleanup 은 *type+arm shape* 으로 repo 전체 grep 필수, 함수명 기준 sweep 은 N-of-M 누락 위험.

따라서 Phase 3/4 의 단위는 *함수* 가 아니라 *scrutinee 타입*. PR 본문에 다음을 명시:

```
이 PR 은 <type_path> 타입에 대한 모든 catch-all 사이트를 닫는다.
RFC-0071 inventory CSV: <hash> 행 <range>.
Sibling site count: N.
컴파일러가 모든 사이트 변환을 검증.
```

## 5. Verification

### 5.1 Phase-별 검증

- **Phase 0**: `wc -l docs/rfc/RFC-0071-inventory.csv` 가 본 RFC §1.2 의 1044 와 일치 (±10 허용 — 머지 race).
- **Phase 1**: `bash scripts/lint/exhaustive-guard.sh` 가 0 false-positive (allowlist 가 inventory 와 동일).
- **Phase 2**: codemod 가 단일 (file, type) 입력에 대해 idempotent — 동일 입력 두 번 적용 시 두 번째 diff 가 empty.
- **Phase 3/4**: `dune build --root .` PASS, alcotest suite green, *그리고* codemod 적용 전후 `git diff --stat` 의 net catch-all 사이트 수가 PR 본문의 sibling count 와 일치.
- **Phase 5**: `rg -n '^\s*\|\s*_\s*->\s*(false|None|\(\))\s*$' lib/` 출력 행 수가 inventory 의 (a) Intentional 합계와 일치. 새 catch-all 시도 시 `exhaustive-guard.sh` 가 exit code 1.

### 5.2 Bug-Model TLA+ stub

본 RFC 는 TLA+ spec 자체를 ship 하지 않는다. 후속 spec PR 의 시드로 한 단락 sketch 만 제시한다:

> `KeeperSparseMatch.tla` — variant set `Phases = {p1, ..., pN}` 의 transition matrix. action `BugAction = ∃ p ∈ Phases : "FSM 가 _ -> false 로 p 를 silently 거부함"` 을 모델링한다. invariant `NoSparseCatchAll == ∀ p ∈ Phases : transition_handler[p] ∈ {Accept, ExplicitReject}` — wildcard 가 *어떤 ctor* 에 어떤 결정으로 mapping 되는지 명시 강제. clean spec (codemod 적용 후) 은 invariant 만족, buggy spec (`Next \/ BugAction`) 은 위반. CLAUDE.md §TLA+ Bug Model 패턴 그대로.

후속 spec PR (별도 RFC 또는 `docs/specs/` 추가) 가 실체 작성을 가져간다.

## 6. Risks

| Risk | Mitigation |
|------|------------|
| Phase 3/4 의 PR 이 거대 diff — 리뷰 부담 | scrutinee 타입 단위 분할, PR 본문에 sibling count 명시, codemod 가 *기계적* diff 만 생성 (의미 변경 없음). reviewer 는 `git diff --stat` 만 확인. |
| codemod 의 `.cmt` 의존성 — dune build 가 *선행* 되어야 함 | tool README 에 명시. CI 의 codemod 검증 job 도 `dune build @check` 선행. |
| (b) lazy / (c) closed-set-guard 분류의 false positive — codemod 가 의도된 default 를 변환할 위험 | 모든 codemod 적용 PR 은 dune build + alcotest + integration test 통과 필수. 의미 변경 없음을 컴파일러 + 테스트가 검증. 의심 사이트는 (a) Intentional 로 보수적 분류 → 사람 리뷰. |
| Allowlist 가 *새로운* (a) Intentional 사이트로 부풀어오를 위험 — anti-pattern 의 변종 | Phase 5 의 manifest (`fsm-types.txt`) 가 *type 단위* 로 제한. 새 entry 는 RFC waiver 가 필요. |
| FSM-shaped 타입 탐지가 manifest 기반 → silent miss 위험 | Phase 5 의 manifest 갱신을 inventory regeneration step 에 묶음. 분기당 1회 (또는 RFC body merge 시) 자동 재생성. |
| RFC 번호 충돌 (race) | push 직전 `git fetch origin main && ls docs/rfc/ \| grep 0071` 재확인. memory `feedback_rfc_number_reservation_needed` 의 처방. |

## 7. Out of Scope (v2 candidates)

- **TypeScript 진영 sweep** — `switch (x) { default: }` 와 `if-else` 사슬의 final `else`. 별도 RFC.
- **`try ... with _ -> X` 예외 catch-all** — 별도 anti-pattern, RFC-0070 §3.5 에서 sandbox subsystem 일부 처리.
- **Open-polymorphic variant 의 hash 충돌 가드** — 본 RFC 의 (a) Intentional 의 sub-case. 필요 시 후속 RFC.
- **codemod 의 자동 매주 실행 (cron)** — 본 RFC 는 *one-shot sweep + lint*. 정기 적용은 lint 가 blocking 으로 승격된 Phase 5 이후 의미 없음.

## 8. Open Questions

1. **`.cmt` 의존성 vs ppxlib 만으로 가능?** — scrutinee 타입 추론을 `.cmt` 없이 syntactic heuristic 으로 할 수 있나? Phase 2 구현 PR 에서 결론. Default: `.cmt` 사용 (정확도 우선).
2. **Phase 3 의 PR 단위가 *type* 인가 *file* 인가?** — Default: type. memory feedback 의 type+arm 처방 그대로. 단, 한 PR 의 diff 가 너무 크면 (>30 파일) file 분할 허용.
3. **(a) Intentional 의 주석 형식** — `(* WORKAROUND: open-variant scrutinee *)` vs `(* INTENTIONAL: ... *)`? Default: 전자 (CLAUDE.md 의 WORKAROUND 주석 규약 재사용).
4. **Inventory CSV 의 long-term 위치** — `docs/rfc/RFC-0071-inventory.csv` 부속 자료 vs `data/` 의 generated artifact? Default: 부속 자료. RFC-0047 의 `RFC-0047-caller-inventory.txt` 선례.

## 9. Rollback

각 Phase 는 독립 revertable. Phase 5 (`exhaustive-guard.sh` blocking 승격) 가 유일하게 *비대칭* — revert 는 lint 를 다시 advisory 로 내리는 한 줄 변경. Phase 3/4 의 codemod 적용 commit 은 *기계적 diff* 이므로 revert 가 깨끗.

Phase 2 의 codemod 도구 자체가 부정확한 것으로 판명되면 Phase 3 이전에 도구만 revert + Phase 1 의 advisory lint 만 유지하는 것도 가능. lint + 사람 리뷰로 점진 진행.
