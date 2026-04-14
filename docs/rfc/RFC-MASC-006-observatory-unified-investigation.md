# RFC-MASC-006: Observatory — Unified Investigation Surface

**Status**: Draft
**Date**: 2026-04-14
**Scope**: `dashboard/src/components/`, `dashboard/src/observatory-store.ts`, `dashboard/src/api/dashboard.ts`, `dashboard/src/config/navigation.ts`
**One sentence**: 현재 4개 탭에 분산된 observability surface(telemetry · fleet · memory-subsystems · Prometheus metrics)를 **단일 time axis 기반 investigation surface(Observatory)**로 통합하여 cross-signal 인과 관계를 가시화한다.

## Related Documents

- RFC-MASC-005 (Dashboard as OAS Eval Consumer) — eval 메트릭 consumer pattern. Observatory도 동일 원칙(data producer는 OAS/MASC backend, dashboard는 consumer).
- `dashboard/src/observatory-store.ts` — `ObservatoryAgent` / `ObservatoryGroup` 기개념 존재, agents-by-session grouping + derived state (working/watching/quiet/offline). **이 RFC가 확장**.
- `dashboard/src/api/dashboard.ts` — data primitives (`fetchTelemetry`, `fetchToolQuality`, `fetchMemorySubsystems`, Prometheus metric endpoint).
- `dashboard/src/components/common/sparkline.ts` — Canvas 2D chart primitive (확장 대상).
- `feedback_dashboard-observation-focus.md` — 관찰 대시보드 원칙: 설명 최소화, 영한 혼용 금지, "누가/어디서/뭘/왜".
- `feedback_tailwind-only-dashboard.md` — Tailwind utility만.
- PR #7019 — Phase 1 IA reorg (tool-quality/fleet/inspector 이동). Observatory는 Phase 1 기반 위에서 동작.

## Problem Statement

### 현재 상태 (post-PR #7019)

같은 질문 "keeper-X가 왜 도구 호출에 실패하나?"에 답하기 위해 사용자는 **4개 surface를 순회**한다:

| Step | 탭 | Surface | 얻는 정보 |
|------|-----|---------|-----------|
| 1 | monitoring | **텔레메트리** (이벤트 스트림) | 이벤트 발생 순서, actor |
| 2 | monitoring | **Fleet 비교** | keeper-X의 aggregate 지표가 다른 keeper와 다름 |
| 3 | monitoring | **Prometheus** | X의 latency / memory metric 시계열 |
| 4 | monitoring | **기억 서브시스템** | X의 compaction 상태, synapse health |

각 surface는 **독립적 시간축**과 **독립적 필터**를 가지므로, 사용자는 머릿속에서 4개 관찰을 **시간 정렬·인과 해석**해야 한다.

### 숨겨진 인과 체인 예시

다음은 현재 UI에서 개별적으로만 보이는 사건들이다:

```
T+0    memory compaction 시작        (기억 서브시스템에서만 표시)
T+3s   context_ratio 0.92 → 0.74     (Prometheus에서만 표시)
T+8s   latency p95 급증               (Prometheus + Fleet에서만 표시)
T+12s  tool call timeout 이벤트 3건   (텔레메트리에서만 표시)
T+15s  tool success rate 60% 하락    (Fleet + tool-quality에서만 표시)
```

실제 인과: **compaction → memory pressure → latency spike → tool timeout → success rate 하락**.

이 인과가 단일 timeline 위에 겹쳐 보이면 누구나 읽을 수 있지만, 현재는 **4개 surface를 4번 열어 메모로 정렬**해야 보인다.

### Dead menu로 인한 cognitive noise

Explore 조사 (2026-04-14):

- `monitoring/sessions` — **pure stub**. `Status` dispatcher가 default(fallback)로 `<Mission />` 렌더. `overview`와 100% 겹침. URL만 있고 고유 UI 없음.
- `monitoring/memory-subsystems` — polling only, empty-state 흔함. 사용자 한두 명만 사용.

이 stub들은 사이드바 폭을 차지하며, 새 사용자가 "이게 뭐지?" 탐색에 시간 소비.

## Design Goals / Non-goals

### Goals

1. **Single time axis** — 모든 observability signal이 동일 horizontal timeline 위에.
2. **Cross-signal cursor** — 한 signal에 hover하면 다른 signal의 같은 시점 값이 highlight.
3. **Keeper-scoped context** — global filter(keeper, namespace, operation_id, time_range)를 Observatory 안에서 한 번 선택하면 모든 track이 동일 필터.
4. **Progressive disclosure** — 기본 보기는 최소 signal, 필요 시 track 추가/확장.
5. **Hook for autoresearch revival** — autoresearch cycle 이벤트를 별도 track으로 예약 (내용적 통합은 별도 RFC).

### Non-goals

- 신규 데이터 저장소 구축 — 기존 API만 소비.
- Metric 쿼리 language(PromQL 등) 제공 — 고정 track만.
- 전용 ML anomaly 엔진 — 통계 baseline 기반 hint 정도만 (Phase 3+).
- 기존 surface 즉각 삭제 — Observatory v1은 **보완**, 대체는 실사용 관찰 후 결정 (open question).

## Design

### Layout: Grafana Explore 스타일 vertical tracks

```
┌──────────────────────────────────────────────────────────────────┐
│ Global filter: [keeper-X ▾] [namespace ▾] [last 1h ▾]  [↻]      │
├──────────────────────────────────────────────────────────────────┤
│ Time axis ──────────────────────────────────────────────▶        │
│                                                                   │
│ ▸ Events         ■  ■■   ■     ■■■■          ■                   │
│ ▸ Tool calls          ■    ■■■     ■    ■■                       │
│ ▸ Latency p95    ──╱─╲──────╱──╲─────────╱╲──                    │
│ ▸ Success rate   ────────────╲────────────────╱─                  │
│ ▸ Context ratio  ────╲─────────╲──────────────╲─                  │
│ ▸ Memory state   ████████░░░░░████░░░░░░░████████                │
│ ▸ Autoresearch   ▮─────keep─────▮  ▮─discard─▮                   │
│                                                                   │
│ [cursor at T+12s] tooltip: "tool call timeout (3 events),        │
│                   latency=1.2s, ctx=0.74, memory=compacting"     │
└──────────────────────────────────────────────────────────────────┘
```

선택 이유:
- "시간 기반 질문"은 horizontal timeline이 자연스러움 (Grafana Explore, Datadog APM, Chrome DevTools Performance 관행).
- 각 signal은 vertical track으로 병렬 — cross-signal 시각 정렬 용이.
- vis-timeline 라이브러리 이미 `node_modules`에 있음, discrete event track 직접 활용 가능.

### Tracks (v1)

| # | Track | Data source | 렌더 방식 |
|---|-------|-------------|----------|
| a | 이벤트 스트림 | `fetchTelemetry` (time-axis, keeper filter) | vis-timeline discrete markers |
| b | 도구 호출 | telemetry + tool-quality hourly_trend 합성 | 색상 구분 markers (success/fail) |
| c | Metric 라인 | Prometheus `/api/v1/models/metrics` (bucketed) | sparkline-extended 라인 차트 |
| d | 메모리 상태 바 | `fetchMemorySubsystems` + 백엔드 time-series 확장 | horizontal state bar (compacting/stable) |
| e | Autoresearch cycle | `fetchAutoresearchLoops` | start/keep/discard/error markers |

**Note**: (d) 메모리 상태 바는 현재 API가 snapshot only이므로 **백엔드 time-series 확장 필요**. Observatory Phase 2 전제조건 또는 placeholder로 시작.

### Filter Bar (Global)

```typescript
// dashboard/src/store/observatory-filter.ts (신규)
export const keeperFilter = signal<string | null>(null)
export const namespaceFilter = signal<string | null>(null)
export const operationFilter = signal<string | null>(null)
export const timeRangeFilter = signal<TimeRange>({ preset: 'last_1h' })
```

- URL params와 sync: `?keeper=X&ns=Y&range=1h`
- 기존 surface에서 cross-link: `관찰 › 텔레메트리` 페이지의 "Observatory에서 보기" 버튼 → 현재 컨텍스트 전달
- Observatory 내부에서 keeper 변경 → URL 갱신 + 모든 track refetch

### Interactions

- **Pan/zoom** — 마우스 드래그로 시간 범위 이동, wheel로 zoom
- **Hover cursor** — 세로선이 모든 track을 가로지름, 각 track의 해당 시점 값 tooltip
- **Click drill-down** — 이벤트 marker 클릭 → 우측 detail pane에 raw payload
- **Keyboard** — `←/→` 시간 이동, `z` zoom to selection, `f` focus cursor

### Existing Surface와의 관계

**보완 관계 (v1)**. 기존 4 surface는 유지:
- 텔레메트리, Fleet, 기억 서브시스템, Prometheus 각자 single-signal 심층 보기 역할
- Observatory는 **cross-signal investigation** 역할
- 크로스링크: 기존 surface → "Observatory에서 보기" 버튼 / Observatory track marker → "이 track의 단독 surface" 버튼

**대체 결정은 Open Question** (아래 참조).

## Autoresearch-Planning Integration (미래 Hook)

사용자 방향성: "오토리서치를 앞으로 계획과 연계해서 살릴 것".

이 RFC는 **hook만 준비**하고 내용적 연계는 **RFC-MASC-007 (별도)**로 분리:

- **이 RFC 범위**: Observatory autoresearch track이 cycle 이벤트(start/keep/discard/error) 렌더
- **RFC-MASC-007 범위 (후속)**:
  - Planning 태스크 ↔ autoresearch 실험 seed 매핑
  - 실험 결과 keep → planning backlog feedback
  - Autoresearch가 목표의 "가설 검증기"로 승격

이렇게 분리하는 이유: autoresearch revival 자체가 별도 설계 공간(목표→가설 변환, seed 전략, feedback loop)을 가지며, Observatory의 관찰 기능과 결합하면 scope ballooning.

## Phased Implementation

### Phase 0 — Pruning (prerequisite, 1 PR, ~30 min)

**목표**: Observatory 구축 전에 noise 제거.

- `monitoring/sessions` 제거 — stub이므로 default section을 `agents`로 변경 + navigation에서 entry 삭제
- `monitoring/governance` (read) → `command/승인 큐` (write) 크로스링크 버튼 추가 (중복 UX 해소)
- `SurfaceSectionId`에서 `sessions` 제거
- URL `?section=sessions`는 `agents`로 redirect in `normalizeRouteParams`
- 테스트: `navigation.test.ts`, `Status` 컴포넌트 테스트

**산출물**: 1 PR, +20/-100 lines (approx)

### Phase 1 — Shared Filter State (1-2 PR, ~1 day)

**목표**: 기존 surface가 global filter 기반으로 동작하도록 토대 구축. Observatory 없이도 즉시 가치 있음.

- `dashboard/src/store/observatory-filter.ts` 신규: keeper / namespace / operation / time_range signals
- Header에 global filter chip 위젯 추가 (현재 활성 필터 표시 + clear)
- URL sync: `?keeper=X&ns=Y&range=1h`
- 기존 surface (telemetry, fleet, tool-quality, prometheus) fetch 함수가 filter signals 소비하도록 리팩터
- 기존 surface가 자체 필터 UI를 유지하되, global과 동기화

**산출물**: 1-2 PR

### Phase 2 — Observatory v1 (2-3 PR, ~1 week)

**목표**: 신규 surface `관찰/observatory` 런칭. 4 tracks 기본 (Events/Tools/Metrics/Memory placeholder).

- 신규 section `observatory` in `monitoring` 탭 (또는 별도 탭 논의 — open question)
- `dashboard/src/components/observatory.ts` 신규 — container + track orchestrator
- `dashboard/src/components/observatory/tracks/` — 각 track 컴포넌트
- vis-timeline 래퍼로 event/tool marker track
- sparkline-extended로 metric line track
- Cross-signal cursor 구현
- SSE 스트리밍 — 신규 이벤트를 realtime append
- Feature flag: `observatory_v1` (기본 off, 점진 rollout)

**산출물**: 2-3 PR, feature-flagged

### Phase 3 — Advanced (optional, 별도 RFC 가능)

- **Anomaly highlight** — 통계 baseline (z-score 기반) signal 튐 highlight
- **Compare mode** — keeper A vs keeper B 동일 timeline에 중첩
- **Memory time-series 백엔드 확장** — track (d)를 placeholder에서 실제 데이터로
- **Autoresearch cycle track 활성화** — RFC-MASC-007 결과물 연결
- **Query DSL (선택)** — 고급 사용자용 필터 표현식

## Open Questions

1. **Memory subsystem API가 snapshot only** — Observatory track (d)를 위해 백엔드 time-series 확장이 필요한가? 별도 RFC로 백엔드 확장 먼저? 아니면 placeholder로 Phase 2 시작?

2. **Telemetry retention** — 얼마나 과거까지 scroll 가능해야 하는가? 24h (현재) / 7d / 30d? 장기 retention은 별도 저장소 필요.

3. **Live streaming vs replay** — Observatory 기본 mode가 SSE tailing (live)인가 polling + 고정 range (replay)인가? 기본 UX 결정.

4. **기존 surface 대체 정책** — Observatory v1 후 telemetry/fleet/memory-subsystems/metrics 탭을 **그대로 유지**인가, **hide**인가, **Observatory 내부 "단독 보기 mode"로 흡수**인가? 실사용 1-2주 후 결정.

5. **Default time range** — 5m (ops context) / 1h (investigation) / 24h (trend) 중 무엇이 landing? Keeper 상태(활성/idle)에 따라 동적 권장?

6. **Observatory가 독립 탭인가 `관찰` 서브섹션인가** — Phase 1 이후 IA 가 "Now/Issues/Work/System" 4탭이 된다면, Observatory는 Now 안의 section? 또는 "Observatory" 자체가 5번째 탭?

## Risks

- **Scope balloon** — "모든 것을 보여주는 surface"로 팽창 유혹. 매 feature가 "Observatory에 track 하나 더 추가"로 수렴. **대책**: v1에서 5 track 상한, Phase 3 이상의 track 추가는 별도 RFC 필수.

- **Rendering performance** — 5 track × 실시간 스트리밍 × 여러 keeper → frame drop 가능. **대책**: Canvas 2D (sparkline 기반), virtual scroll, 최대 event count cap.

- **Learning curve** — 기존 단일-surface 사용자가 unified UI에 적응. **대책**: 기존 surface 즉시 삭제 안 함 (Q4), onboarding overlay.

- **Backend coupling** — 4개 데이터 소스가 서로 다른 retention/cadence. Observatory 통합 시 lowest-common-denominator 되는 위험. **대책**: 각 track이 "데이터 없음" 상태를 graceful 표시, 사용자에게 retention 차이 명시.

- **Autoresearch hook 공허화** — RFC-MASC-007이 지연되면 autoresearch track이 영원히 placeholder. **대책**: v1에서는 track 숨김 or "revival pending" 상태 표시.

## Alternatives Considered

### Option A — Soft cross-link만 (L1)

기존 4 surface 유지 + 크로스링크 버튼 + shared keeper_id URL param.

- **장점**: 최소 구축 비용
- **단점**: 사용자가 여전히 4 surface 탐색 필요. cross-signal 인과 여전히 머릿속 합성

**제외** — 근본 문제 미해결.

### Option B — IA 재편 4탭 (Phase 2 of nav reorg)

탭을 Now/Issues/Work/System 4개로 재편 + 기존 surface 그룹핑.

- **장점**: 현재 cognitive structure 정리
- **단점**: 분류만 바꾸고 observability 통합은 안 됨. Cross-signal 인과 안 보임

**제외** — 사용자가 Option C 선택.

### Option C (채택) — Unified Observatory

L2 통합 surface. 단일 time axis, cross-signal cursor.

- **장점**: 근본 문제 해결. Investigation UX가 Grafana Explore 수준에 근접
- **단점**: 큰 구축 노력 (Phase 2에서 2-3 PR, Phase 3 이후 확장)

## Success Metrics (Phase 2 런칭 후)

- **P1 (핵심)**: 사용자가 "keeper-X 왜 실패?" 질문을 Observatory 단일 화면에서 해결하는 비율 ≥ 70% (이전: 4 surface hop 100%)
- **P2**: Observatory session에서 평균 탭 전환 횟수 < 1 (현재 4 surface 탐색 시 평균 3-4회 추정)
- **P3**: Observatory 도입 후 기존 surface 방문 감소 추이 — 30% 이상 감소 시 Q4 (기존 surface 흡수) 근거

## Migration & Compatibility

- **Phase 0**: `?section=sessions` URL → `agents`로 301 redirect in `normalizeRouteParams`
- **Phase 1**: filter signals는 optional — 기존 surface가 없어도 동작, 있으면 동기화
- **Phase 2**: Observatory는 feature flag `observatory_v1` 뒤에. 기본 off → 점진 on
- **기존 bookmark**: Phase 0의 sessions redirect 외에는 URL 전부 보존

## Reviewers

- @jeong-sik (product direction, UX)
- (dashboard 코드 오너)

## Changelog

- 2026-04-14 (Draft v1): 초안 작성 (post-PR #7019, Phase 1 IA reorg 완료 직후)
