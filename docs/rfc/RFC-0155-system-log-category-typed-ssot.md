---
rfc: "0155"
title: "System_log_category Typed SSOT — emit-side closed sum for ops log taxonomy"
status: Draft
created: 2026-05-21
updated: 2026-05-21
author: vincent
supersedes: []
superseded_by: null
related: ["0088", "0089", "0148", "0149", "0154"]
implementation_prs: []
---

# RFC-0155: System_log_category Typed SSOT

## §0 한 줄 요약

운영 로그 (`Log.warn` / `Log.error`) 의 *category* 가 현재 emit-side 에서 untyped — 분류는 외부 도구 (`memory/masc-oas-log-reduction-measure.py`) 의 post-hoc string match 로만 수행. 이로 인해 `other` bucket 이 **12,160 events / 72h** 누적되어 RFC `error-warn-reduction-goal-2026-05-18` Pass-1 목표 (<20,000) 도달이 구조적으로 차단. 본 RFC 는 emit boundary 에 closed-sum **`System_log_category.t`** 도입하여 *enforcement* 로 root-fix 한다.

> Anti-pattern §1 self-check: 본 RFC 는 *counter 추가* (visibility) 가 아니라 *emit boundary 의 parse-don't-validate* (enforcement) 다. 새 카테고리 추가 시 OCaml 컴파일러가 모든 reader 갱신을 강제하므로 string drift 가 자라지 않는다.

## §1 문제: post-hoc string match 카테고리화

### 1.1 측정 도구 측 (read-side)

`memory/masc-oas-log-reduction-measure.py:76` `system_category(message: str) -> str` 는 **lowercase substring match** 로 14 카테고리 추정:

```python
def system_category(message: str) -> str:
    lowered = message.lower()
    if "has " in lowered and "active owned tasks" in lowered and ...:
        return "task_ownership_ambiguity_current_task_unset"
    if "current_task" in lowered and ("is a directory" in lowered or ...):
        return "state_store_current_task_path_corruption"
    ...
    return "other"  # 12,160 events / 72h
```

### 1.2 emit-side 측

`rg "Log.warn|Log.error" lib/ --type ml -c` = **29 파일** (top: `lib/board_dispatch.ml` 12, `lib/heuristic_metrics.ml` 8, `lib/board_votes.ml` 8). emit-side 에는 **`category` 인자가 존재하지 않으며**, 모든 분류 정보가 *message string 안에 자유 텍스트* 로 묻혀 있다. measure.py 는 그 묻힌 텍스트를 다시 짜내는 *reverse engineering* 단계.

### 1.3 워크어라운드 시그니처 적용 분석

본 패턴은 `software-development.md` 워크어라운드 거부 시그니처 중 다음 2 개에 정확히 부합:

- **#2 String/Substring 분류기 보강** — measure.py 의 substring match 가 *외부 분류기* 를 점진적으로 보강하는 자리. 새 메시지 텍스트마다 `if "..." in lowered` 가 추가되어 prefix drift 가 자라고, 누구도 자유 텍스트 변경 시 measure.py 를 동기화하지 않는다. 컴파일러가 잡지 못함.
- **#3 N-of-M 패치** — 14 카테고리가 *각 emit site* 에서 자유 텍스트로 *N 번 변형 표현*. 동일 분류가 여러 사이트에서 다른 phrasing 으로 emit 되면 measure.py 의 string match 가 일부만 catch — N-of-M 누락.

### 1.4 RFC-0089 inventory gap

`docs/rfc/inventory/RFC-0089-string-classifier-sites.md` (Implemented 2026-05-17) 는 string classifier 박멸 RFC 이지만, `system_log` / `log_category` / `log_kind` / `warn-category` 키워드 grep = **0 hit**. 즉 RFC-0089 가 의도적으로 *내부 상태/결정/이벤트* 분류기를 닫았지만 **log emit 자체의 분류는 인벤토리에 포함되지 않음**. 본 RFC 가 RFC-0089 의 *형제 RFC* 로서 빠진 도메인을 닫는다.

## §2 제안: closed sum `System_log_category.t`

### 2.1 타입

```ocaml
type t =
  | Task_ownership_ambiguity_current_task_unset
  | State_store_current_task_path_corruption
  | Config_env_allowlist_drift
  | Telemetry_or_metadata_parse_drop
  | Host_fd_pressure
  | Docker_start_pressure
  | Keeper_stale_watchdog_lifecycle
  | Provider_timeout
  | Provider_cascade_exhaustion
  | Required_tool_contract_mismatch
  | Task_state_probe_misuse
  | Verifier_action_guard
  | Network_error_other
  | Other_boundary_unclassified of { hint : string }
```

- 14 variant (measure.py 14 카테고리 1-to-1 mapping).
- `Other_boundary_unclassified` 는 *외부 boundary* (예: third-party library exception 의 첫 emit) 에서만 허용. record field `hint` 가 *추적 단서* — `hint` 가 *반복 분기* 면 새 typed variant 추가 후보. measure.py 의 `return "other"` 와 의미적으로 동등하지만 *컴파일러가 추적*.
- 모든 variant 은 ppx ord (alphabetical) + `to_string` derive 로 serialization 결정성.

### 2.2 API 변경 (breaking)

```ocaml
(* lib/log.mli *)
val warn  : category:System_log_category.t -> ('a, Format.formatter, unit) format -> 'a
val error : category:System_log_category.t -> ('a, Format.formatter, unit) format -> 'a
```

- `category` named argument **required** — 호출자 누락 시 컴파일 에러.
- 변경은 *radical breaking* (~70+ call site). 따라서 본 RFC body 가 머지된 *후* `Wave A scout / Wave B sweep / Wave C legacy purge` 3-PR cascade 로 분할 마이그레이션 (§3).

### 2.3 emit envelope 변경

JSONL envelope 에 `category` field 추가:

```json
{ "level": "warn", "category": "Host_fd_pressure", "msg": "too many open files: ...", ... }
```

measure.py 는 *string match 제거* 하고 `obj["category"]` 직접 read. "other" bucket 은 typed `Other_boundary_unclassified` 만 카운트 → 12,160 → 잔여 외부 boundary noise 만 남음 (목표: < 500 / 72h).

## §3 마이그레이션 phasing

본 RFC 머지 후 PR-1 ~ PR-3 순차 머지:

### PR-1 (Wave A scout, base PR)
- `lib/system_log/system_log_category.ml{,i}` (closed-sum) 추가.
- `lib/log.ml{,i}` API 에 `?category` *optional* 인자 추가 (점진 안전).
- emit envelope 에 category field 추가.
- top-frequency 5-10 사이트 (board_dispatch.ml 12, heuristic_metrics.ml 8, board_votes.ml 8) Wave A 마이그레이션.
- measure.py 가 *envelope category 우선, string match fallback* 로 dual-read 지원.
- 예상 LoC: +250 / -50.

### PR-2 (Wave B sweep)
- 잔여 ~20 file 의 `Log.warn|error` site categorize.
- 예상 LoC: +400 / -80.

### PR-3 (Wave C legacy purge)
- `?category` *required* 로 승격 (signature change).
- 컴파일러가 누락 site 강제 catch → 새 site 마다 typed variant 선택 의무.
- measure.py 의 substring match 함수 `system_category()` 삭제. `obj["category"]` 단일 read.
- `Other_boundary_unclassified` count 가 100 / 72h 미만으로 떨어지지 않으면 PR-3 머지 미루기 (안정성 ratchet).
- 예상 LoC: +50 / -150.

## §4 anti-pattern self-check

| 항목 | 적용 | 비고 |
|------|------|------|
| §1 텔레메트리-as-fix | ❌ 회피 | counter 도입 아님. emit *boundary 에서 typed 강제*. drop counter / WARN visibility 추가 없음. |
| §2 String 분류기 보강 | ❌ 회피 | substring match 를 *제거* (measure.py system_category 삭제). 추가 아님. |
| §3 N-of-M 패치 | ❌ 회피 | optional → required 승격으로 컴파일러가 *모든* 사이트 강제. 점진 PR-1/2 는 *abstraction 부재 admit 아닌 단계적 enforce*. PR-3 closeout 에서 partial migration 금지. |
| Cap/Cooldown/Dedup | ❌ 해당 없음 | symptom 억제 아님. |
| Test backdoor | ❌ 회피 | typed variant 가 SSOT — `set_for_test` 불필요. |

## §5 메트릭

| 시점 | 기대 측정 | 출처 |
|------|-----------|------|
| Baseline | other = 12,160 / 72h (21% of 57,947) | `memory/masc-oas-log-reduction-measure.py` 2026-05-18 baseline |
| PR-1 머지 후 | other 변화 없음 (envelope optional, fallback 활성) | dual-read mode |
| PR-2 머지 후 | other 5,000 ~ 7,000 / 72h | 약 50% 카테고리화 |
| PR-3 머지 후 | other = `Other_boundary_unclassified` 카운트 ≈ 500 / 72h | substring match 제거, typed 단일 read |

목표: PR-3 머지 후 measure.py `other` < 1,000 / 72h. 미달 시 RFC follow-on 필요.

## §6 비-목표 (out of scope)

- **`Log.debug` / `Log.info` 카테고리화**: 본 RFC 는 *operator alarm surface* (warn/error) 에 한정. debug/info 는 trace volume 이라 별도 RFC.
- **`Tool_result.error` / LLM-facing**: RFC-0148 (Tool_error closed sum) 의 도메인. 본 RFC 와 별개.
- **`System_error_class.t`**: RFC-0154 (operator-facing exception class) 의 도메인. classify_exn 패턴은 본 RFC 와 *직교* (exception → class 는 RFC-0154, log emit → category 는 본 RFC).
- **외부 protocol log (HTTP access log, OAS request log)**: emit boundary 가 다른 lib (oas/, server_http_*) 라 별도 RFC.

## §7 참조

- RFC-0088 (Counter-as-Fix umbrella) — *visibility 추가 금지* 원칙 인용
- RFC-0089 (string classifier 박멸) — 본 RFC 의 형제, log 도메인 gap 보완
- RFC-0148 (Tool_error LLM-facing closed sum) — 같은 parse-don't-validate 패턴
- RFC-0154 (System_error_class operator-facing closed sum) — 같은 parse-don't-validate 패턴
- `memory/masc-oas-log-reduction-measure.py` — 14 카테고리 reverse-engineering source
- `memory/masc-oas-log-reduction-goal-2026-05-18.html` — 본 RFC 의 motivating audit

## §8 closeout 조건

- PR-1/PR-2/PR-3 모두 main 머지.
- measure.py 의 substring 분류 함수 `system_category()` 삭제.
- 본 RFC frontmatter `status: Implemented` + `implementation_prs: [...]` 갱신.
- *closeout commit*: `docs(rfc): RFC-0155 Implemented — System_log_category typed SSOT closeout`.
