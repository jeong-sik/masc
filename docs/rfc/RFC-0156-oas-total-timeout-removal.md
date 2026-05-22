---
name: RFC-0156
title: OAS total timeout 제거 — turn timeout + stream idle 두 layer로 단순화
status: Draft
authors:
  - vincent.dev@kidsnote.com (Claude Opus 4.7 paired)
created: 2026-05-22
---

# RFC-0156: OAS total timeout 제거

## 1. Problem

`oas_timeout_for_estimated_input_tokens_with_turn_budget` 함수가 *adaptive*한 거동을 시그니처로 약속하지만, 실제 구현은 두 인자 모두 `let _ = ...` 로 무시하고 `min(turn_timeout_sec, oas_timeout_default_sec) = min(600, 300) = 300` 상수만 반환합니다.

```ocaml
(* lib/config/env_config_keeper.ml:454-470 *)
let oas_timeout_for_estimated_input_tokens_with_turn_budget
      ~(estimated_input_tokens : int)
      ~(max_turns : int)
  : float
  =
  let _ = max_turns in                               (* unused *)
  match oas_timeout_sec_override with
  | Some v -> v
  | None ->
    let _ = estimated_input_tokens in                (* unused *)
    Float.min turn_timeout_sec oas_timeout_default_sec
```

이는 CLAUDE.md `software-development.md` §2 *Permissive Default*의 강화형입니다. 일반 §2가 "미지의 입력을 편리한 기본값으로 매핑"이라면, 이 패턴은 "입력을 보지 않고 기본값으로 매핑". 호출자는 token 추정값을 *계산해서 전달*하지만 함수가 *사용하지 않음*.

## 2. Evidence

### 2.1 코드 자인

함수 출력 record의 `source` 필드가 `"static_300s"` 라벨로 자기 식별:

```ocaml
(* lib/keeper/keeper_turn_cascade_budget.ml:154-155 *)
let source =
  match runtime.oas_timeout_override_sec.value, capped_by_turn_budget with
  | Some _, true -> "override_capped_by_turn_budget"
  | Some _, false -> "override"
  | None, true -> "static_300s_capped_by_turn_budget"
  | None, false -> "static_300s"
in
```

### 2.2 Production 측정 (72h, 2026-05-19~22)

| 지표 | 값 | 출처 |
|------|-----|------|
| `oas_timeout_budget` WARN | 6,349건 | system_log measure |
| 직전 측정(보고서 §10.1.1) | 5,246건 | 보고서 5/21 |
| 변화율 | **+21%** (증가 추세) | — |
| 샘플 input token | ~5,000 | 로그 |
| 샘플 budget_sec | 300.0 | 로그 (token 무관) |
| 샘플 remaining_turn_budget_sec | 599.99 | turn 시작 직후 |
| 연쇄: `provider_cascade_exhaustion` | 1,991건 | timeout → rotation 누적 |

### 2.3 함수 호출 그래프

직접 caller 2곳:

- `lib/keeper/keeper_turn_cascade_budget.ml:91` — `resolve_bounded_oas_timeout_budget_with_turn_budget`
- `lib/keeper/keeper_turn_driver_try_provider.ml:170` — `per_provider_timeout_s`

Wrapper 1곳:

- `lib/keeper/keeper_runtime_resolved.ml:301-320` — `oas_timeout_for_estimated_input_tokens*`

외부 module 호출자 없음 (`rg "oas_timeout_for_estimated_input_tokens" --type ml` 검증).

### 2.4 #10008 의 역사적 맥락

```
(* #10008 fm2 removed token-count scaling because it timed out real
   research turns before useful work could finish. The replacement must
   still leave headroom for cascade fallback: default OAS calls get a
   300s cap inside the 600s keeper turn envelope. *)
```

이전에 *token scaling이 있었다가* "research turn이 못 끝남" 이유로 제거됨. 즉:
- v0: token-aware adaptive (회귀)
- v1 (현재): static 300s (남용)
- v2 (제안): total timeout 제거, turn + idle 두 layer

## 3. Goal — Non-goals

### 3.1 Goal

- `oas_timeout_for_estimated_input_tokens_with_turn_budget` 및 wrapper 제거
- `"static_300s"` source label 제거
- Cascade rotation trigger를 `stream_idle_timeout_sec` (이미 존재, 120s) 로 단순화
- 6,349건/72h WARN 95% 감소 (G3, 본 RFC §7)
- function-name lying 안티패턴 1개 박멸

### 3.2 Non-goals

- 다른 `let _ = <param>` 사이트 fix — 별도 issue (대부분 RFC-0132 boundary redaction으로 legitimate)
- `turn_timeout_sec` 변경
- `stream_idle_timeout_sec` 변경
- Token-aware adaptive 복원 — #10008 회귀 위험

## 4. Proposal

### 4.1 제거할 함수

```ocaml
(* lib/config/env_config_keeper.ml *)
- let oas_timeout_for_estimated_input_tokens_with_turn_budget ~estimated_input_tokens ~max_turns ...
- let oas_timeout_for_estimated_input_tokens ~estimated_input_tokens ...
- let oas_timeout_sec  (* backward-compat accessor, returns 300 *)

(* lib/keeper/keeper_runtime_resolved.ml *)
- let oas_timeout_for_estimated_input_tokens_with_turn_budget ...
- let oas_timeout_for_estimated_input_tokens ...
```

### 4.2 호출자 변경

```ocaml
(* lib/keeper/keeper_turn_cascade_budget.ml *)

(* Before *)
let adaptive_timeout_sec =
  Keeper_runtime_resolved.oas_timeout_for_estimated_input_tokens_with_turn_budget
    ~estimated_input_tokens ~max_turns
in
let effective_timeout_sec = Float.min adaptive_timeout_sec usable_budget in

(* After *)
(* OAS total timeout 제거 (RFC-0156). turn_timeout이 wall-clock cap, *)
(* stream_idle_timeout이 per-stream cap. *)
let effective_timeout_sec = usable_budget in
```

Source 라벨 단순화:

```ocaml
(* Before *)
| None, true -> "static_300s_capped_by_turn_budget"
| None, false -> "static_300s"

(* After *)
| None, _ -> "turn_budget"
```

### 4.3 환경변수 호환성

| Env knob | 현재 | 변경 후 |
|----------|------|---------|
| `MASC_KEEPER_OAS_TIMEOUT_SEC` | OAS total cap override | **deprecated**. 값이 set되어 있으면 1회 warning 로깅 + 무시. |
| `MASC_KEEPER_TURN_TIMEOUT_SEC` | turn wall-clock | 변경 없음 |
| `MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC` | per-stream idle | 변경 없음 (cascade rotation trigger 역할 강화) |

### 4.4 Cascade rotation 신호의 transition

| Signal | Before | After |
|--------|--------|-------|
| Total OAS budget exceeded | trigger rotation | 사라짐 (root cause of 6,349 WARN) |
| Stream idle > 120s | 이미 trigger | 유지 (primary trigger) |
| Provider HTTP error | 이미 trigger | 유지 |
| Completion contract mismatch | 이미 trigger | 유지 |
| Turn timeout (600s) | turn-level fail | 유지 |

Cascade rotation은 *idle signal + HTTP error + completion contract* 세 신호로 trigger. Total timeout 제거가 신호 손실을 일으키지 않음 — 이미 다른 layer가 동일 역할.

## 5. Risk

| 위험 | 가능성 | Mitigation |
|------|--------|------------|
| #10008 회귀 (research turn 600s 다 잡아먹음) | 중간 | `turn_timeout_sec(600s)` 자체가 cap. 한 turn이 다 쓰면 turn-level fail로 transition. cascade fallback 시간은 줄지만 turn 단위 isolation 유지. |
| Cascade rotation 부족 | 중간 | `stream_idle_timeout(120s)` 이미 trigger 역할. 통합 테스트로 fake provider stream idle 시뮬레이션 검증. |
| 외부 호출자 의존 | 낮음 | `rg "oas_timeout_for_estimated_input_tokens" --type ml` 검증: lib/test/ 내부만, 외부 없음. |
| Slow but successful 응답 *전환* | 낮음 | 의도된 효과 — 5분+ 걸리는 정상 응답이 회수됨. Goal G5. |

## 6. Migration plan

### Phase 1 — Soft deprecation (이번 PR)
- 함수 제거
- `MASC_KEEPER_OAS_TIMEOUT_SEC` 환경변수 무시 + warning 로깅
- `"static_300s"` source 라벨 제거

### Phase 2 — Production 검증 (머지 + reload 후 24h)
- §7 검증 표 측정
- G3-G5 통과 확인

### Phase 3 — Rollback 경로
- 머지 후 24h 내 G3-G5 미통과: 환경변수로 즉시 복귀
  - `MASC_KEEPER_OAS_TIMEOUT_SEC=300` 재활성화 path를 PR-2로 add back
  - (이번 PR은 환경변수 무시만, 복귀 path는 별도)

## 7. Verification

### 7.1 Alcotest (신규)

`test/test_keeper_turn_cascade_budget_timeout_removal.ml` 4 cases:

1. `test_no_static_300s_source` — `source` 필드가 `"static_300s*"` 절대 emit 안 함
2. `test_effective_timeout_matches_turn_budget` — token 100,000 입력해도 `effective_timeout_sec = remaining_turn_budget - guard`
3. `test_zero_remaining_returns_none` — `remaining_turn_budget < min(15)` 일 때 `None`
4. `test_deprecated_env_warning` — `MASC_KEEPER_OAS_TIMEOUT_SEC` set시 warning 로깅

### 7.2 Production 측정

| 지표 | baseline (72h) | Phase 2 (24h) | 측정 |
|------|---------------|---------------|------|
| G1: function 제거 | 2 함수 | `rg "oas_timeout_for_estimated_input_tokens" lib/` → 0 |
| G2: `"static_300s"` label | >1000/일 | 0 | `rg '"source":"static_300s' system_log` |
| G3: `oas_timeout_budget` WARN | 6,349/72h | <320 (-95%) | measure 스크립트 |
| G4: `provider_cascade_exhaustion` | 1,991/72h | <800 (-60%) | measure 스크립트 |
| G5: slow-but-success 회수 | 0 회수 | >0 | 5분+ 응답 성공 카운트 |
| G6: test suite green | — | 0 failure | `dune runtest` |

## 8. Alternatives considered

| Option | OAS budget | 평가 |
|--------|-----------|------|
| A. 비례 (turn × 0.9) | 540s | 변경 작음, but cascade fallback 60s 부족 |
| **B. 완전 제거 + idle** | ∞ + 120s idle | **선택** — code 단순화, function-name lying 박멸 |
| C. Token adaptive 복원 | dynamic | #10008 회귀 위험 |
| D. budget = turn_timeout | 600s | cascade fallback 의미 없음 |

## 9. References

- 기획 문서: `~/me/memory/function-name-lying-fix-plan-2026-05-22.html`
- 측정 보고: `~/me/memory/audit-deep-dive-2026-05-22.html` §4.2
- 사전 fix: PR #17469 (autoresearch shard), PR #17468 (task_verification_gate), OAS PR #1697 (correction_pipeline log enrichment)
- 역사적: #10008 fm2 (token-count scaling 제거)
- 관련 RFC: RFC-0132 PR-2 (boundary redaction — `let _ = model` 의 대부분은 이 family)
- CLAUDE.md `software-development.md` §2 Permissive Default
