# Cascade Documentation

> **Note**: 이 디렉토리는 **Vincent 개인 참고용** 문서입니다. 팀 SSOT나
> 외부 계약이 아니라 본인이 cascade 구조를 잊었을 때 돌아와 읽는 메모.
> 공식 스펙은 `docs/spec/`, 운영 계약은 `docs/observability/cascade-metrics.md`.

Cascade 레이어 운영/설계 문서 모음. MASC가 LLM provider 선택을 어떻게 하는지,
어떤 전략이 있는지, 어떤 관찰 면을 노출하는지를 한 곳에서 찾기 위한 인덱스.

## 관련 문서 (이 디렉토리 밖)

| 경로 | 내용 |
|------|------|
| `docs/observability/cascade-metrics.md` | Prometheus counter, Grafana dashboard, alerting rule |
| `docs/spec/14-configuration.md` | cascade catalog 스키마 레퍼런스 |
| `docs/tla-audit/cascade-fsm-gap-2026-04-13.md` | cascade FSM TLA+ 감사 결과 |
| `specs/boundary/CascadeStrategyStateful.tla` | Phase B sticky/round_robin spec |
| `specs/bug-models/CascadeLiveness-liveness.cfg` | keeper blocked -> timeout termination liveness guard |

## 코드 SSOT

| 모듈 | 역할 |
|------|------|
| `lib/cascade/cascade_strategy.ml` | 전략 kind 타입, `order_candidates`, state hook |
| `lib/cascade/cascade_fsm.ml` | provider outcome → decision (retry/exhaust) |
| `lib/cascade/cascade_config.ml` | `resolve_strategy` (runtime cascade JSON → `Cascade_strategy.t`) |
| `lib/cascade/cascade_config_loader.ml` | cascade source resolution + runtime JSON loader |
| `lib/cascade/cascade_toml_materializer.ml` | authoring TOML → runtime JSON materialization |
| `lib/cascade/cascade_health_filter.ml` | `should_cascade_to_next` (에러 분류) |
| `lib/cascade/cascade_health_tracker.ml` | cooldown, effective weight |
| `lib/cascade/cascade_state.ml` | sticky state, round_robin cursor |

## Runtime 설정 SSOT

- Live authoring source: `~/.masc/config/cascade.toml` (또는 `$MASC_BASE_PATH/.masc/config/cascade.toml`)
- Runtime artifact: sibling `cascade.json` materialized from TOML when present
- Repo fallback: `MASC_ALLOW_REPO_CONFIG_FALLBACK=true` 필요 (기본 OFF)

## 변경 시 체크리스트

cascade 관련 변경은 최소 3개 축을 함께 수정:

1. **코드**: `lib/cascade/*.ml`
2. **Spec**: `specs/boundary/CascadeStrategy*.tla` (variant 추가 시)
3. **문서**: 이 디렉토리 (전략 추가 시) + `docs/observability/cascade-metrics.md` (label 추가 시)

`CascadeLiveness.tla`를 건드릴 때는 `scripts/tla-check.sh`가 clean cfg,
buggy cfg, 그리고 `CascadeLiveness-liveness.cfg`까지 모두 실행해야 한다.
특히 liveness cfg는 all-provider-unhealthy 또는 last-provider 대기 상태가
turn timeout 경로로 반드시 종료되는지 확인하는 회귀가드다.

신규 전략 추가 시 `cascade_strategy_trace.mli`의 `event_kind`까지 5-surface
일관성이 깨지지 않는지 확인. 상세는 `cascade-metrics.md` 마지막 섹션.
