---
number: 0103
title: Log retention opt-in + JSONL volume root reduction
status: Draft
author: Claude Opus 4.7 (agent)
created: 2026-05-17
updated: 2026-05-17
supersedes: []
related:
  - RFC-0063 telemetry-feedback-loop
  - RFC-0089 string-classifier-to-typed-variant
---

# RFC-0103 — Log retention opt-in + JSONL volume root reduction

## 1. Summary

JSONL log retention (tool_calls, tool_usage, oas-events, runtime-manifests)
는 PR-5 (#PENDING) 에서 *opt-in* (env-gated) 으로 wiring. **default disabled**.

이 RFC 는:
1. *왜 default disabled 인가* — retention 이 root fix 가 아니라 symptom 억제
2. *진짜 root* — JSONL volume reduction (특히 `oas-events` 의
   `Context_window_usage` telemetry-as-fix anti-pattern)
3. *Phase 별 step* — RFC-0089 (string→typed) 와 정렬

## 2. Background

5/16 host FD storm 사고의 부수 작업 중 base-path `.masc` 디스크 사용량 audit:

| Path | Size | 24-hour growth |
|---|---|---|
| `.masc/oas-events` | 226M | ~38M/day (5/05, 5/06 측정) |
| `.masc/keepers/*/runtime-manifests/` | (~per-keeper) | append-only, no archive |
| `.masc/tool_calls` | 115M | 16 keeper burst proxy |
| `.masc/tool_usage` | 128K | rolling stable |

`oas-events` 가 가장 큰 hotspot. 분석:
- 14 emits/min sustained
- **84% noise** = `Context_window_usage` event (RFC-0089 anti-pattern target)
- event format = `[name_string, props_dict]` (string-classifier 의 변종 —
  RFC-0089 §3 영역)

## 3. Why default disabled

### 3.1 Retention 30d 의 측정 근거 없음

원본 (fix-keeper-24-resource-gates) 의 `Some 30` default 는 *합리적 추측* 일
뿐. 0d/7d/90d/180d 분기점 측정 없음. `Workaround Rejection Bar` §Magic number
금지 항목 위반.

### 3.2 Retention 은 symptom 억제, root 아님

- `oas-events` 226M 의 84% 가 `Context_window_usage` telemetry-as-fix —
  retention 으로 *지운다 해서 emit rate 가 줄지 않음*
- 30일 후 다시 226M 가 누적, 60일 후 같음 — *volume 자체 reduction* 이 root
- `Workaround Rejection Bar` §Symptom 억제 패턴 ④ "Log Dedup/Demote" 변종

### 3.3 Default disabled = root fix 동기 유지

retention 이 default enabled 면:
- operator 시야에서 *문제 사라짐* → root fix (RFC-0089 typed event) 우선순위 하락
- prune 이 매일 돌면서 *false sense of safety* 형성
- 다음 incident 때 *retention 자체* 가 디버깅 노이즈 (왜 5/15 data 없냐?)

default disabled 면:
- operator 가 *명시적으로 enable* — 비결정론적 부분 명시
- disk 압력 발생 시 *PR-4 disk pressure circuit breaker* 가 alarm
- root fix (typed event volume reduction) 까지 *visible pressure* 유지

## 4. Phase plan

### Phase A — opt-in wiring (PR-5, 본 PR)

- 4 모듈의 `retention_days ()` default → `None`
  - `lib/keeper_tool_call_log.ml`
  - `lib/tool_usage_log.ml`
  - `lib/cascade/cascade_event_bridge.ml` (oas-events)
  - `lib/keeper/keeper_runtime_manifest.ml`
- env vars 유지: `MASC_*_RETENTION_DAYS` (positive int 일 때만 enable)
- invalid env 값 (non-positive 또는 non-int) = disabled (안전한 default)

### Phase B — Context_window_usage typed event (RFC-0089 dovetail)

- `[name_string, props_dict]` → typed variant `Context_window_event of { ... }`
- emit rate sampling (현재 14/min → 1/min sampled — 92% reduction 가정)
- RFC-0089 §3.1.1 implementation table 에 entry 추가

### Phase C — `runtime-manifests` 영역 boundary

- 현재 trace-based, archive 없음 — *trace 종료 시 manifest 도 종료* 되어야 함
- typed *trace lifecycle event* boundary (RFC-0099 session-lifecycle-typed-events
  와 정렬)
- archive 정책 = *operator 결정* (cold storage 또는 drop), retention 아님

### Phase D — `playground/docker` 영역 (별도 — RFC-0097 phase 1)

- 20G 의 60% 가 `playground/docker` (Docker image layers + volumes)
- retention 영역 아님 — *Docker volume/image quota policy* 필요
- RFC-0097 keeper-sandbox-container-reuse phase 1 의 quota stage 와 통합

## 5. Workaround rejection bar mapping

| 패턴 | 본 RFC 의 대응 |
|---|---|
| `Cap` | 본 RFC 에 cap 없음 (env vars 는 opt-in budget) |
| `Cooldown` | PR-4 disk pressure cooldown — 별도 영역 |
| `Retention TTL` | **default disabled 로 opt-in 화** ← root |
| `Repair` | typed boundary (Phase B/C) 로 root fix |
| `Telemetry-as-fix` | `Context_window_usage` 가 정확히 이 패턴 — Phase B 가 제거 |

## 6. Risk

- *Disk 무한 성장* — 이 RFC 의 default disabled 직접 결과. PR-4 disk
  pressure circuit breaker 가 *alarm + admit_turn skip* 으로 corruption 방지.
  *operator 가 free-space alert 받고 retention enable 또는 root fix 진행*.
- *retention enable 후 다시 disable* — 가능. env unset → default disabled.
- Phase B/C/D 의 *RFC dependency* — 본 RFC 가 motivation, dependency 아님.
  각 Phase 별도 RFC 후속.

## 7. Open questions

1. operator UX — retention enable 권고 환경 변수 셋 (production preset) 을
   별도 RFC 로 분리할 것인가? (예: `MASC_PRESET_PRODUCTION=retention_30d`)
2. `runtime-manifests` 의 trace-lifecycle event boundary 가 RFC-0099 와
   *exact same scope* 인지 확인 필요. 일부 overlap 가능.

## 8. References

- PR-5: TBD (본 RFC 와 stack)
- 5/16 host FD storm 사고 keeper memory:
  `feedback_runtime_lens_boundary_carve_out`
- `Workaround Rejection Bar`: `software-development.md` §워크어라운드 거부 기준
