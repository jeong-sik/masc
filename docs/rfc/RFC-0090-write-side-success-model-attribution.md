---
rfc: "0090"
title: "Write-side success-model attribution — finish N-of-M migration"
status: Draft
created: 2026-05-17
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0044", "0077", "0088"]
implementation_prs: [15651]
---

# RFC-0090 — Write-side success-model attribution: finish N-of-M migration

Status: Draft
Author: jeong-sik (vincent)
Date: 2026-05-17
Related: PR #15564 (read-side fallback, merged), PR #15578 (write-side partial fix, merged), RFC-0044 (read-side counterpart), RFC-0077 (write-side silent failure typed), RFC-0088 (counter-as-fix)

## 1. Problem

`lib/model_inference_metrics.ml` 의 success-path parser (line 462–468) 는 `telemetry.selected_model` 또는 `telemetry.model_used` 의 string 값을 기대한다. 둘 다 `null` 인 채로 emit 된 row 는 `Missing_success_model` 로 reject (parse drop) 된다.

증상 (메모리 `project_masc_system_log_audit_2026_05_16.md` §G):

```
decisions.jsonl parse drop: <keeper>:<line> reason=missing_success_model
```

burst 시 fleet-wide 11+ keeper, 3000 entries 안 18+ 발생. dashboard model attribution / cost accounting 에서 success turn 누락.

### 1.1 두 fix 가 이미 merge 됐다

- **PR #15564** (read-side fallback): success path 에서 `selected_model`/`model_used` 가 둘 다 없으면 `cascade_name` 을 `"{canonical_name} (cascade)"` 형태로 attribute. `instructions/software-development.md §Symptom 억제 - Fallback Resolution` 시그니처에 해당하는 **transitional workaround**.
- **PR #15578** (write-side partial): `keeper_turn_driver.ml` 의 success-path `cascade_observation_with_metrics` 호출 2 곳 (L878, L911) 에 `Some (Cascade_runtime_candidate.model_health_key candidate)` propagate. **root fix, 단 N-of-M.**

### 1.2 Audit — 8 사이트 중 3 사이트가 success/accept

| Site | outcome arg | path | model surface | fix status |
|---|---|---|---|---|
| L658 | `` `Failure `` | non-cascadable error | N/A (error path, attribution via `cascade_name`) | error-path marker 필요 |
| L878 | `` `Success `` | success | `Some model_health_key` | **fixed by #15578** |
| L911 | `` `Success `` | resume retry success | `Some model_health_key` | **fixed by #15578** |
| L939 | `` `Rejected `` | `Accept_rejected → Exhausted` | N/A (error path, `candidate_models` attribution) | error-path marker 필요 |
| **L969** | `` `Success `` | `Cascade_fsm.Accept` (unreachable-but-recorded branch) | **`None`** | **N-of-M leak — fix in this RFC** |
| L1098 | `` `Failure `` | `Call_err → Exhausted` | N/A (error path) | error-path marker 필요 |
| L1120 | `` `Failure `` | non-cascadable | N/A (error path) | error-path marker 필요 |
| L1180 | `` `Failure `` | `exhausted_after_filter` | N/A (error path) | error-path marker 필요 |

L969 branch 의 코드 주석은 *"Should be unreachable with accept_on_exhaustion:false, but handle gracefully"* — invariant violation counter (`Cascade_metrics.on_cascade_invariant_violation`) 가 tick 되지만 *실행은 계속* 한다. branch fire 시 `outcome=`Success`` 로 row 가 write 되고 `selected_model_raw=None` 인 채로 parse drop 발생.

### 1.3 Anti-pattern 매핑

- `instructions/software-development.md §시그니처 3 — N-of-M 패치`: "PR #X only fixed M/N sites" 자인. PR #15578 본문은 "두 호출 site (line 877, 908) 모두" 라 표현 — 8/8 audit 없이 partial 머지. 같은 type-level 변환을 다른 site 들에서 따로 하면 컴파일러가 누락을 잡지 못함.
- `instructions/software-development.md §Symptom 억제 - Fallback Resolution`: PR #15564 의 `"{cascade_name} (cascade)"` string concat 은 두 개념 (model id vs cascade route) 을 같은 string 타입에 압축. typed 분리가 root fix.
- `MEMORY.md feedback_fallback_constant_to_discriminated_union`: FALLBACK 상수 + silent default 3-pattern 은 discriminated union 으로 root-fix 후 legacy 박멸.

## 2. Non-goals

- **Append-only WAL / journal**: `decisions.jsonl` write durability 는 RFC-0077 의 scope. 본 RFC 는 *attribution surface* 만 다룬다.
- **Cascade FSM unreachable branch 제거**: L969 의 `Cascade_fsm.Accept` branch 가 정말 unreachable 인지 결정은 별도 audit (cascade 의 FSM 정확성). 본 RFC 는 *해당 branch 가 fire 됐을 때 row 가 silent corrupt 되지 않게* 만 한다.
- **Error-path attribution 재설계**: error path 5 사이트 (L658/L939/L1098/L1120/L1180) 가 `candidate_models` / `cascade_name` 로 attribute 되는 정책은 유지. *명시적 marker* 만 추가.
- **Read-side fallback 즉시 제거**: PR #15564 의 `cascade_model_attribution_of_fields` 는 production 안전망. 본 RFC 는 *sunset date 지정* 만 한다.

## 3. Design

### 3.1 PR-1 — L969 Some 변환 (single-site write-side fix)

`lib/keeper/keeper_turn_driver.ml:965-969` (L969 site):

```ocaml
(* before *)
let observation =
  Cascade_legacy_runner.cascade_observation_with_metrics
    ~cascade_name:error_cascade_name
    ?strategy:!cascade_strategy_name_ref ~configured_labels
    ~candidate_count ~selected_model_raw:None ~capture ()
in
```

```ocaml
(* after *)
let observation =
  Cascade_legacy_runner.cascade_observation_with_metrics
    ~cascade_name:error_cascade_name
    ?strategy:!cascade_strategy_name_ref ~configured_labels
    ~candidate_count
    ~selected_model_raw:
      (Some (Cascade_runtime_candidate.model_health_key candidate))
    ~capture ()
in
```

근거: 이 branch 는 `outcome=`Success`` 로 `record_cascade` 가 호출되고 (`record_candidate_success candidate ~latency_ms:attempt_latency_ms result;`), `candidate : Cascade_runtime_candidate.t` 가 scope 에 살아있다. PR #15578 L878/L911 과 동일 패턴.

### 3.2 PR-1 — error-path 5 사이트 명시적 marker

`L658`, `L939`, `L1098`, `L1120`, `L1180`:

```ocaml
~selected_model_raw:None  (* error path: attribution via cascade_name/candidate_models *)
```

근거: outcome 이 `` `Failure ``/`` `Rejected `` 일 때 read-side (`model_inference_metrics.ml:419-426`) 는 `candidate_models` 첫 element 또는 `cascade_name` fallback 으로 model attribute. None 이 *의도된* 값임을 코드 reader 가 즉시 인지하도록 inline comment 추가.

### 3.3 PR-2 — read-side fallback deprecation marker + hit counter

`lib/model_inference_metrics.ml` 의 `cascade_model_attribution_of_fields` 호출 site (line 462-468 success path):

1. 함수 본체에 deprecation 주석 추가:

   ```ocaml
   (* DEPRECATED: write-side RFC-0090 PR-1 closes the model attribution
      gap for success/accept paths.  This fallback exists for production
      safety during the transition window; it must reach zero hits before
      PR-3 removes it.  Hits are counted by
      [metric_cascade_model_attribution_fallback_hits]. *)
   ```

2. Prometheus counter 추가 (`lib/model_inference_metrics.ml` 또는 `keeper_metrics.ml`):

   ```
   metric_cascade_model_attribution_fallback_hits{cascade_name=...}
   ```

   read-side fallback 이 fire 될 때마다 increment. *RFC-0088 §counter-as-fix* 와의 구분: 본 counter 는 *fix 가 아니라 sunset gauge*. 0 이 되면 PR-3 의 trigger.

3. Test: `test_success_without_model_uses_cascade_attribution` 에 counter assertion 추가 (fallback hit 후 counter == 1).

### 3.4 PR-3 — read-side fallback 제거 (sunset)

조건 (모두 충족 시 머지):

1. PR-1 머지 후 **7 일 연속** `decisions.jsonl parse drop reason=missing_success_model` count = 0 (production log).
2. PR-2 머지 후 **7 일 연속** `metric_cascade_model_attribution_fallback_hits` rate = 0.
3. test `test_success_without_model_uses_cascade_attribution` 가 fail 하면 정상 (fallback 이 제거됐으므로). 해당 test 를 `test_success_without_model_returns_missing_success_model_error` 로 invert.

코드 변경:

```ocaml
(* removed *)
let cascade_model_attribution_of_fields = ...
```

read-side success path 는 `selected_model` / `model_used` 둘 중 하나만 받는 원래 형태로 복귀. write-side 가 invariant 를 보장.

## 4. Verification

### 4.1 정적 검증

```bash
# write-side 8/8 audit
rg -n '~selected_model_raw:None' lib/keeper/keeper_turn_driver.ml | wc -l
# PR-1 후: 5 (error path 5 사이트, 모두 inline comment marker 보유)
# PR-1 후 grep 'error path' 동반: 5
```

```bash
# read-side fallback audit
rg -n 'cascade_model_attribution_of_fields' lib/
# PR-3 후: 0
```

### 4.2 동적 검증

```bash
# parse drop count (production log)
grep -c "missing_success_model" "$MASC_BASE_PATH/.masc/logs/system_log_$(date +%Y-%m-%d).jsonl"
# PR-1 후 신규 row: 0 (legacy row 의 parse drop 은 history 에 남을 수 있음)
```

```bash
# fallback hit counter (Prometheus)
curl -s http://localhost:<port>/metrics | grep cascade_model_attribution_fallback_hits
# PR-2 머지 + 7 일 후: 0
```

### 4.3 Test 추가

- `test/test_model_inference_metrics.ml`: PR-1 의 L969 fix 가 새 row 를 cascade attribution 으로 처리하는 unit test 추가.
- `test/test_keeper_turn_driver.ml` (또는 동등): `Cascade_fsm.Accept` unreachable branch 가 fire 될 때 `selected_model_raw=Some` 로 record_cascade 호출되는지 검증.

## 5. Sequencing

| PR | Scope | Risk | 머지 조건 |
|---|---|---|---|
| PR-1 | L969 Some 변환 + 5 error site marker | LOW | local test green, lint green |
| PR-2 | read-side fallback deprecation marker + counter | LOW | local test green, counter 노출 검증 |
| PR-3 | read-side fallback 제거 | MEDIUM | 7-day production 0-hit + 0 parse drop 확인 |

PR-3 머지 시 PR #15564 의 `cascade_model_attribution_of_fields` 가 *codebase 에서 제거* 되므로 `MEMORY.md feedback_hardcoding_and_legacy_zero_tolerance` 의 "root-fix PR 같은 머지에서 legacy 함께 삭제" 원칙을 satisfy 한다. 단 본 RFC 의 PR-1 시점에는 production 안전망 (read-side fallback) 이 남아있고, PR-3 에서 한 commit 으로 legacy 박멸한다.

## 6. Anti-pattern self-check

`instructions/software-development.md §워크어라운드 거부 기준` 7 항목 self-check:

1. ❌ "makes X visible" / "instrument Y" 만 수행: 본 RFC 는 fix (PR-1) + sunset (PR-3) 까지 명시.
2. ❌ string/substring 분류기 추가: 추가 없음. 오히려 PR-3 가 string fallback 제거.
3. ✅ "PR #15578 only fixed 2 of 3 success sites" 자인 — 본 RFC 가 closure.
4. ❌ catch-all `_ ->` 추가: 없음.
5. ❌ cap/cooldown/dedup/repair symptom 억제: 없음.
6. ❌ test backdoor 노출: 없음.
7. ❌ codemod 미수행: 본 RFC 의 변경은 5 사이트 inline comment + 1 사이트 Some wrap + read-side 함수 제거. codemod 불필요 (8 사이트 enumerable).

자가 항목 충족 — RFC 로 흡수 가능.

## 7. Notes

본 RFC 는 PR #15564 가 main 에 *이미 들어간* 상태에서 사후 정리한다. PR #15564 본문에 `WORKAROUND:` 마커 + 본 RFC 링크가 없었음 — `instructions/software-development.md §Override 조건` 위반 (production-blocking 도 아니었음, parse drop 은 dashboard 누락이지 service outage 아님). 본 RFC 가 그 누락된 RFC 링크다.

향후 같은 패턴 재발 방지:

- PR review 시 "read-side fallback 추가 PR" 에 대해 write-side root 가 분리되었는지 자동 체크 (lint 규칙 또는 PR template 항목).
- `lib/model_inference_metrics.ml` 의 `_of_fields` 류 함수 추가는 RFC 의무 (frontmatter check).
