---
rfc: "0158"
title: "OAS retry-admission typed error — split server timeout from didn't-try"
status: Draft
created: 2026-05-21
updated: 2026-05-21
author: agent-llm-a-opus
supersedes: []
superseded_by: null
related: ["0148", "0157"]
implementation_prs: []
---

# RFC-0158 — OAS retry-admission typed error

## §0 TL;DR

현재 `Keeper_turn_driver.Oas_timeout_budget` (`lib/keeper/keeper_turn_driver.mli:67-75`) 한 variant 가 두 가지 *의미상 분리된* 실패를 동일 분류로 emit 한다:

1. **server-side timeout** — provider 가 OAS 호출 도중 wall-clock 한계로 끊김 (`source = "cascade_attempt_watchdog"`)
2. **pre-dispatch admission denial** — keeper 가 retry 를 *시도조차 하지 않음*. budget gate 가 사전에 차단 (`source = "pre_retry_budget_unavailable"`, `"pre_attempt_budget_unavailable"`)

Team OO POC (`decide_retry_admission_for_turn : ... -> (unit, retry_admission_denial) result`, `lib/keeper/keeper_turn_cascade_budget.ml`) 는 case 2 의 *결정 함수* 를 typed 로 추출했다. 본 RFC 는 그 typed result 를 emission 까지 잇는 **closed-sum 확장** 을 정의한다: `masc_internal_error` 에 `Retry_admission_denied of { reason : retry_admission_denial }` 신규 variant 를 추가하고, Team JJ 관측치 (`oas_timeout_budget` 1077/24h, 74% retry-path ≈ 800/day) 의 *didn't-try* 부분을 별도 라벨로 분리한다.

핵심 제약: 신규 variant 는 closed-sum (OCaml exhaustive match) 확장이며 string classifier 가 아니다. 새 카운터 `masc_oas_error_total{kind="retry_admission_denied"}` 는 *visibility* 보조이며 *fix* 자체는 분리 emission 이다 (cf. RFC-0088, software-development.md §1 텔레메트리-as-fix 거부 기준).

목표 (Phase D 완료 후 24h sustained):
- `oas_timeout_budget{kind="oas_timeout_budget"}` ≥ 70% 감소 (1077 → ≤ 320)
- `retry_admission_denied` ≈ 800/day (현 retry-path 비중과 일치)
- `Oas_timeout_budget.source` 에서 `pre_retry_budget_unavailable`, `pre_attempt_budget_unavailable` 두 값 사용 0 (dead branch)

## §1 Motivation

### 1.1 Team JJ 정량 관측 (인용)

24h window:

| 신호 | 분량 | 비중 |
|---|---|---|
| `oas_timeout_budget` (총합) | 1077 | 100% |
| retry-path (`source = "pre_retry_budget_unavailable"`) | ~800 | 74% |
| true server timeout (`source = "cascade_attempt_watchdog"`) | ~277 | 26% |

retry-path 분량이 server-timeout 분량의 ~3배다. 그러나 둘은 alert / pause-policy / cascade-rotation 측면에서 *반대 신호*다:

- **server timeout**: provider 가 *느림* → cascade rotation 합리적, watchdog 자동 회복 가능
- **retry admission denial**: keeper 가 *시도 안 함* → cascade rotation 불필요 (다음 cascade candidate 도 동일 budget 적용 시 동일하게 denied), pause-policy 와 무관

`keeper_supervisor_pause_policy.ml:174` 의 `~blocker_class:(Some Oas_timeout_budget)` 와 `keeper_registry_types.ml:80` 의 `Oas_timeout_budget_loop of { count : int }` 는 *둘 다*를 동일 loop 신호로 누적한다. 즉 retry-admission denial 800회 가 server timeout 신호처럼 `Oas_timeout_budget_loop` counter 를 부풀려 supervisor 의 auto-pause 결정을 왜곡한다.

### 1.2 현재 emission 위치

- `lib/keeper/keeper_unified_turn.ml:599-615` — `resolve_bounded_oas_timeout_budget_with_turn_budget` 가 `None` 반환 시 `Oas_timeout_budget { source = if is_retry then "pre_retry_budget_unavailable" else "pre_attempt_budget_unavailable"; ... }` 를 raise. 이것이 *case 2* (didn't-try).
- `lib/keeper/keeper_turn_cascade_budget.ml:266` (`reclassify_oas_timeout_for_attempt`) — `Agent_sdk.Error.Api (Timeout { message })` 가 structural OAS timeout 메시지면 `Oas_timeout_budget { source = "cascade_attempt_watchdog"; ... }` 로 reclassify. 이것이 *case 1* (server slow).

두 site 가 동일 variant 를 emit 하므로 downstream 30+ 사이트 (exhaustive match) 는 분리 처리 불가하다.

### 1.3 cf. RFC-0148 sunset 사례

RFC-0148 (텔레메트리-as-fix self-recurrence, 2026-05-20) 가 보여준 안티패턴: counter 추가가 root fix 를 대체하지 않는다. 본 RFC 는 counter 부착만으로 닫지 않고, **emit 경로 자체를 분리** 한다.

## §2 Non-goals

- retry **policy** 변경 (언제/몇 번 retry 할지) — `decide_retry_admission_for_turn` 의 *내부 정책* 은 본 RFC 범위 밖. Team OO POC 의 현재 정책을 그대로 사용.
- `Oas_timeout_budget` variant 제거 — server-timeout case 1 은 그대로 유지. `source` 필드의 두 값 (`pre_retry_budget_unavailable`, `pre_attempt_budget_unavailable`) 만 dead branch 화.
- `Oas_timeout_budget_loop` 의 supervisor pause policy 재설계 — 본 RFC 후속 RFC 후보. 본 RFC 는 분리 emission 까지만.
- 카운터 이름 변경 — 기존 `oas_timeout_budget` 라벨은 case 1 의미로 좁아지고, 신규 `retry_admission_denied` 라벨이 추가될 뿐.
- 새 retry primitive 도입 — Team OO POC `decide_retry_admission_for_turn` 만 사용.

## §3 Design

### 3.1 typed 확장

`lib/keeper/keeper_turn_driver.mli` (현재 line 30-87 의 `masc_internal_error`) 에 신규 variant 추가:

```ocaml
type retry_admission_denial = {
  keeper_turn_timeout_sec : float;
  estimated_input_tokens : int;
  remaining_turn_budget_sec : float option;
  min_required_sec : float;
  is_retry : bool;
  (* Team OO POC 가 이미 정의한 reason 필드를 그대로 import.
     POC 시그니처: decide_retry_admission_for_turn -> (unit, retry_admission_denial) result *)
}

type masc_internal_error =
  | Cascade_exhausted of { ... }
  ...
  | Oas_timeout_budget of { ... }  (* case 1 server-timeout 만 *)
  | Retry_admission_denied of { reason : retry_admission_denial }  (* NEW *)
  | Max_tokens_ceiling_violation of { ... }
  ...
```

`retry_admission_denial` 은 Team OO POC 의 `lib/keeper/keeper_turn_cascade_budget.ml` 에 이미 정의된 record 타입을 재사용한다 (POC 가 export 한 형태 그대로). POC 가 export 하지 않았다면 Phase A 에서 export.

### 3.2 emission 분리

| 현재 emission site | 현재 emit | 분리 후 emit |
|---|---|---|
| `keeper_unified_turn.ml:599-615` (`is_retry = true`) | `Oas_timeout_budget { source = "pre_retry_budget_unavailable" }` | `Retry_admission_denied { reason }` |
| `keeper_unified_turn.ml:599-615` (`is_retry = false`) | `Oas_timeout_budget { source = "pre_attempt_budget_unavailable" }` | `Retry_admission_denied { reason }` (Phase C 결정: `is_retry` 필드로 구분, §9 Q1 참조) |
| `keeper_turn_cascade_budget.ml:266` (`reclassify_oas_timeout_for_attempt`) | `Oas_timeout_budget { source = "cascade_attempt_watchdog" }` | 변경 없음 (case 1 server timeout) |

분리 후 `Oas_timeout_budget.source` 필드는 `"cascade_attempt_watchdog"` 만 유효 값. 두 dead branch 는 Phase D 에서 제거.

### 3.3 downstream exhaustive match 처리

`grep -nc "Oas_timeout_budget" lib/ test/` 기준 약 30+ 사이트 (분포: lib/keeper/ 12, lib/cascade/ 3, test/ 15+). 신규 variant 추가는 OCaml exhaustive match 위반을 컴파일러가 강제하므로, Phase B 에서 *모든 사이트* 가 `Retry_admission_denied _ -> ...` arm 을 추가해야 한다. 각 사이트의 의미적 분류:

- `keeper_turn_disposition.ml` — disposition code 매핑. `Retry_admission_denied` 는 dispositional 으로 *retry-able 이 아님 (admission denied)* — 신규 disposition code 또는 `Oas_timeout_budget` 와 동일 처리 중 선택 (§9 Q2)
- `keeper_supervisor*.ml` — pause policy. `Retry_admission_denied` 는 `Oas_timeout_budget_loop` counter 에 *기여하지 않음* (별도 카운터 또는 skip)
- `cascade_attempt_fsm.ml`, `cascade_error_classify.ml` — cascade rotation 분류. `Retry_admission_denied` 는 cascade rotation 효과 없음 (다음 candidate 도 동일 budget) → `should_skip_cascade_rotation` 신호로 분류
- `test/*.ml` — 신규 variant 의 *명시적* assertion 추가, 기존 `Oas_timeout_budget` 테스트 의미 좁힘

## §4 Observability

### 4.1 카운터 라벨 분리

기존 `masc_oas_error_total{kind="oas_timeout_budget"}` 는 그대로 유지하되 의미가 좁아진다 (case 1 server-timeout 만).

신규 라벨 추가:

```
masc_oas_error_total{kind="retry_admission_denied", is_retry="true"}   # case 2.a, ~800/day 예상
masc_oas_error_total{kind="retry_admission_denied", is_retry="false"}  # case 2.b, 잔여
```

`is_retry` 라벨은 record 필드에서 직접 유도. cardinality 영향 2배 (1 → 2 series), 영구 라벨이며 free-form string 아님.

### 4.2 baseline & post-landing 측정

- Phase A wiring 직전 24h: 기존 `oas_timeout_budget{source="pre_retry_budget_unavailable"}` 분량을 직접 record (Team JJ 데이터 = ~800/day baseline)
- Phase D 완료 후 24h: `oas_timeout_budget{kind="oas_timeout_budget"}` ≤ 320/day (≥ 70% 감소) 와 `retry_admission_denied` ≈ 800/day 둘 다 충족해야 §7 acceptance 통과

### 4.3 dashboard 영향

기존 dashboard 의 `oas_timeout_budget` 패널은 **분량이 줄어든다** (visual cliff). RFC 머지 노트 + 패널 설명에 "kind 분리로 의미 축소" 명시. 별도 `retry_admission_denied` 패널 신설.

## §5 Workaround Rejection Self-Check

`software-development.md` §"워크어라운드 거부 기준" 3 signature + 7 체크리스트 self-check:

### §1 텔레메트리-as-fix — **NOT applicable**

새 카운터 `retry_admission_denied` 는 *fix 자체가 아니다*. fix 는 emission 분리 — variant 가 다르므로 downstream 처리 (pause policy, cascade rotation) 도 분리된다. 카운터는 이 분리가 production 에서 작동하는지 *관측* 만 한다. counter 만 있고 emit 경로 동일이면 §1 위반이지만, 본 RFC 는 **emit 경로 자체가 분기** 한다.

### §2 String classifier — **NOT applicable**

신규 variant 는 OCaml closed-sum 확장. 새 emission 경로는 record 필드 (`reason : retry_admission_denial`) 와 boolean (`is_retry`) 만 사용, string match 없음. 기존 `source` 문자열 (`"pre_retry_budget_unavailable"` 등) 은 Phase D 에서 dead branch 로 제거. *string 분류기를 추가하지 않고 제거하는 방향*.

### §3 N-of-M — **NOT applicable**

신규 variant 1 개 추가 → OCaml exhaustive match 가 *모든* 호출자에서 컴파일 오류로 강제. Phase B 의 30+ 사이트 PR 들은 컴파일러가 검증하므로 N-of-M missed-site 가 원리적으로 불가능. 각 PR 은 `dune build` 가 GREEN 일 때만 머지.

### 7-체크리스트

| # | 항목 | 본 RFC |
|---|---|---|
| 1 | "makes X visible" 만 수행 | ✗ — emit 경로 분리, fix |
| 2 | string/substring 추가 | ✗ — closed-sum, string 제거 |
| 3 | "N of M sites" 자인 | ✗ — exhaustive match 컴파일러 강제 |
| 4 | catch-all `_ ->` 추가 | ✗ — 모든 사이트 명시 arm |
| 5 | cap/cooldown/dedup/repair | ✗ — variant 분리 |
| 6 | test backdoor | ✗ — production code path 만 |
| 7 | 같은 typo N 사이트 N번 fix | ✗ — 단일 variant 정의 |

7/7 통과.

## §6 Migration

### Phase A — typed substrate (POC 머지)

- Team OO POC commit (`decide_retry_admission_for_turn`) 머지
- 신규 variant `Retry_admission_denied` 와 `retry_admission_denial` 타입을 `keeper_turn_driver.mli` 에 정의만 (caller 0)
- `masc_internal_error_to_json`, `summary_of_masc_internal_error` 등 helper 함수에 신규 arm 추가
- 신규 prometheus label 등록 (emit 0)
- 검증: `dune build` GREEN, `Retry_admission_denied` 사용 site 0 (`rg -nc "Retry_admission_denied" lib/`)

### Phase B — downstream exhaustive match 채우기

- 약 30+ 사이트별 PR (or 의미 범주별 묶음 PR — disposition / supervisor / cascade / test 4 묶음 권장)
- 각 PR 은 단독 머지 가능, `Retry_admission_denied` emit 0 유지
- 검증: `dune build` GREEN per PR

### Phase C — emission swap

- `keeper_unified_turn.ml:599-615` 의 emit 을 `Retry_admission_denied { reason = ... }` 로 교체
- baseline measurement: 머지 24h 전 `oas_timeout_budget{source="pre_retry_budget_unavailable"}` 분량 record
- post-merge measurement: 머지 24h 후 `retry_admission_denied{is_retry="true"}` 분량 ≈ baseline
- 검증: §7 acceptance threshold 통과

### Phase D — dead branch 제거

- `Oas_timeout_budget.source` 의 `"pre_retry_budget_unavailable"`, `"pre_attempt_budget_unavailable"` 값 사용 0 확인 후 emission site 제거
- `keeper_turn_terminal_code.ml` 등의 source-string match arm 제거
- 검증: `rg -n "pre_retry_budget_unavailable|pre_attempt_budget_unavailable" lib/` = 0

## §7 Acceptance

Phase D 완료 후 24h sustained:

| metric | 목표 |
|---|---|
| `masc_oas_error_total{kind="oas_timeout_budget"}` | ≤ 320/day (Team JJ baseline 1077 의 30%, ≥ 70% 감소) |
| `masc_oas_error_total{kind="retry_admission_denied", is_retry="true"}` | 600-1000/day (Team JJ retry-path ~800 추정치 ±25%) |
| `Oas_timeout_budget.source` distinct values in emit | `{"cascade_attempt_watchdog"}` 만 |
| `rg -n "pre_retry_budget_unavailable" lib/` | 0 hit |
| `dune build` + `dune runtest` | GREEN |
| `Oas_timeout_budget_loop` counter (supervisor) | retry-admission denial 미기여 (분량 감소 확인) |

## §8 Risks

### 8.1 exhaustive match 30+ 사이트 — *컴파일러 강제, 누락 0*

OCaml closed-sum 확장은 새 variant 추가 시 모든 `match` site 가 컴파일 오류. 누락은 원리적으로 불가능. Phase B 각 PR 은 `dune build` GREEN 일 때만 머지.

### 8.2 새 variant arm 의 *잘못된 위치* (의미 오류)

각 사이트가 `Retry_admission_denied _ -> ...` arm 을 추가할 때 위치가 다른 arm 의 의미를 가릴 수 있다 (예: `_ -> false` 같은 catch-all 위에 위치하면 OK, catch-all 아래면 컴파일러가 dead code warning). 완화:
- catch-all 제거 (`_ ->` 금지 strict mode) — `software-development.md` §4 FSM sparse match 패턴 회피
- Phase B 각 PR 에 unit test 추가: `match Retry_admission_denied {...} with | Retry_admission_denied _ -> () | _ -> assert false`

### 8.3 supervisor `Oas_timeout_budget_loop` counter 영향

현재 counter 는 두 case 합산. 분리 후 retry-admission denial 분량이 빠지면 supervisor auto-pause trigger 빈도가 감소 — 의도된 효과 (cf. §1.1) 지만, *기대보다 더 많이* 감소하면 server-timeout 의 진짜 loop 도 놓칠 수 있음. 완화: Phase C 머지 후 24h 모니터링, `keeper_unified_metrics` 의 pause-trigger rate 변화 추적.

### 8.4 dashboard visual cliff

Phase C 머지 즉시 기존 `oas_timeout_budget` 패널 분량 ~74% 절감. 사용자 보고 alarm 가능. 완화: 머지 노트 + 패널에 "RFC-0158 split 시점" annotation, `retry_admission_denied` 패널 동시 노출.

### 8.5 Team OO POC `retry_admission_denial` record 필드 안정성

POC 가 정의한 record 필드 (timeout/tokens/budget/min/is_retry) 가 향후 변경되면 카운터 라벨 cardinality 영향. 완화: 라벨은 `is_retry` boolean 만 (cardinality 2), 다른 필드는 카운터 라벨로 사용 안 함.

## §9 Open Questions

### Q1: `is_retry = false` 케이스도 `Retry_admission_denied` 로 묶을 것인가?

현재 `keeper_unified_turn.ml:599-615` 는 `is_retry` boolean 으로 두 source 문자열을 분기한다 (`"pre_retry_budget_unavailable"` vs `"pre_attempt_budget_unavailable"`). 두 케이스의 의미:

- `is_retry = true`: 재시도 직전 budget 부족 (Team JJ 의 74% 분량 핵심)
- `is_retry = false`: 첫 시도조차 budget 부족 (소수, 보통 keeper 가 fresh start 시 max_turns 부족)

선택지:
- **(A)** 두 케이스 모두 `Retry_admission_denied { reason }` 로 묶고 `is_retry` 필드로 구분 (기본)
- **(B)** `Retry_admission_denied` (재시도 직전 only) + `First_attempt_budget_below_min` (첫 시도) 두 variant 분리

Team OO POC 가 `retry_admission_denial` record 내 `is_retry` 필드를 이미 분리해 두었다면 **(A)** 가 자연스럽다 (POC 와 호환). 본 RFC 는 **(A)** 를 기본으로 두되, Phase B 진행 중 30+ 사이트의 *처리 분기* 가 `is_retry` 에 따라 의미적으로 갈리면 **(B)** 로 escalate.

### Q2: `Retry_admission_denied` 의 disposition code

`keeper_turn_disposition.ml` 의 disposition code 매핑 — `Oas_timeout_budget` 와 동일 (`"oas_timeout_budget"`) 으로 매핑하면 단순하지만 §3.3 의 카운터/pause 분리 효과가 부분 상쇄. 별도 disposition code (`"retry_admission_denied"`) 가 일관성 측면 권장. Phase B 진행 시 결정.

### Q3: Team OO POC `decide_retry_admission_for_turn` 의 export 범위

POC 가 `keeper_turn_cascade_budget.ml` 내부 함수면 `.mli` 에 export 필요. Phase A 의 첫 작업.

### Q4: cascade rotation 처리 (`cascade_attempt_fsm.ml`)

`Retry_admission_denied` 는 cascade rotation 가치가 없다 (다음 candidate 도 동일 budget) — `should_skip_cascade_rotation = true` 로 처리하면 cascade 비용 절약. 그러나 *budget 이 candidate-specific* 인 경우 (per-provider timeout) 는 rotation 의미가 있을 수 있음. Phase B 의 `cascade_attempt_fsm.ml` PR 에서 결정.
