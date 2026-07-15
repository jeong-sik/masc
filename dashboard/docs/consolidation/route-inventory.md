# Dashboard Section Route Inventory (Phase -1a, Historical)

**목적**: Dashboard consolidation을 위한 section ID 참조 전수 조사.
**수집일**: 2026-04-14.
**수집 방법**: `rg` 기반 정적 분석. section 문자열 리터럴이 있는 모든 파일.

> **Status (2026-05-17)**: 아래 표는 consolidation 전 정적 스냅샷이다.
> Current Dashboard v1 navigation의 SSOT로 쓰지 않는다. 현재 SSOT는
> `dashboard/src/config/navigation.ts`, `lib/dashboard/dashboard_surface_readiness.ml`,
> `lib/dashboard/dashboard_nav_event.ml`이며, drift 검증은
> `scripts/check-dashboard-surface-parity.sh`와
> `scripts/check-dashboard-nav-event-parity.sh`가 담당한다.
>
> [근거] `bash scripts/check-dashboard-surface-parity.sh`
> (2026-05-17 KST, High) ->
> `Dashboard surface parity OK: 25 canonical surfaces aligned between
> navigation.ts and dashboard_surface_readiness.ml`.
>
> [근거] `bash scripts/check-dashboard-nav-event-parity.sh`
> (2026-05-17 KST, High) ->
> `dashboard nav-event allowlist parity: OK`.

## Current Canonical Inventory (2026-05-17)

| Surface | Sections |
|---------|----------|
| `cockpit` | none; hidden surface |
| `overview` | none |
| `monitoring` | `runtime`, `runtime-config`, `agents`, `fleet-health`, `diagnostics`, `transport-health`, `feature-health`, `observatory`, `cognition`; hidden diagnostics: `journey` |
| `command` | `operations` |
| `connectors` | `connector-status` |
| `workspace` | `board`, `sub-boards`, `moderation`, `planning`, `repositories`, `verification` |
| `lab` | `tools`, `harness` |
| `code` | `ide-shell` |
| `logs` | none |

Retired sections are not canonical dashboard surfaces:

- `monitoring:memory-subsystems` remains only as a legacy redirect to
  `monitoring:cognition&view=memory`.
- `workspace:collab-mvp` is retired and has no current canonical route or
  readiness entry.
- `monitoring:sessions`, `monitoring:telemetry`, `monitoring:fleet`,
  `monitoring:tool-quality`, `monitoring:governance`, `monitoring:metrics`,
  and `monitoring:fsm-hub` remain legacy redirect inputs only.
The historical tables below are kept to explain the consolidation work that
led to the current route table.

---

## Consumers (section 값을 읽어 분기)

| 파일:줄 | section 값 | 분기 형태 |
|---------|-----------|----------|
| tab-refresh.ts:57 | `activity` | if section === |
| tab-refresh.ts:60 | `agents` | if section === |
| tab-refresh.ts:63 | `tool-quality` | if section === |
| tab-refresh.ts:68 | `inspector` | if section === |
| tab-refresh.ts:73 | `planning` | if section === |
| tab-refresh.ts:76 | `goals` | if section === |
| tab-refresh.ts:79 | `board` | if section === |
| tab-refresh.ts:87 | `harness` | if section === |
| status.ts:26-29 | observatory, activity, runtime, telemetry, governance, memory-subsystems, fsm-hub, metrics, tool-quality, fleet | currentSection() union |
| status.ts:40-63 | 동일 집합 | ternary chain 렌더 |
| control.ts:14-17 | governance, connectors, inspector (fallback: intervene) | if section === |
| work.ts:13-14 | board, planning, goals | isWorkSection guard |
| lab.ts:11-15 | harness (fallback: tools) | if section === |
| ops/index.ts:386 | `intervene` | **useEffect hydration 조건** — 이름 변경 시 주의 |
| tool-full-inventory.ts:41,44 | `tools` | `tab === 'lab' && section === 'tools'` |
| config/navigation.ts:282 | `sessions` → `agents` | 기존 redirect 패턴 (확장 대상) |
| config/navigation.ts:302 | 전체 | section 매칭 로직 |

## Producers (section 값을 만들어 내보냄)

| 파일:줄 | 타겟 tab/section | query params 동반 | 비고 |
|---------|-----------------|-------------------|------|
| navigation.ts:70,79,88 | monitoring/agents, command/intervene, workspace/board | defaultParams | |
| navigation.ts:124-230 | 모든 section 정의 | section only | DASHBOARD_SECTION_ITEMS |
| router.ts:52 | command/intervene | source, target_type, target_id, focus_kind | legacy `/chains/operation/:id` deep link |
| router.ts:203 | workspace/board | post | navigateToPost |
| mission-briefing-card.ts:244 | command/intervene | | |
| mission-utils.ts:108 | command/intervene | missionInterveneParams(context) | |
| command/helpers.ts:115 | command/intervene | inherited | |
| overview.ts:333 | monitoring/agents | session_id | |
| overview.ts:380,409 | monitoring/agents | | HomeSectionHeader linkParams |
| overview.ts:415 | monitoring/agents | agent | |
| **overview.ts:476** | **lab/tool-quality** | | **⚠️ SILENT MISROUTE** (lab에 tool-quality 없음) |
| overview.ts:511,550 | command/governance | | |
| overview.ts:558 | command/intervene | | |
| overview.ts:712 | command/inspector | | |
| lab-inspector.ts:27,34,41 | monitoring/agents, command/intervene, workspace/board | | |
| memory.ts:392, memory-post-detail.ts:218 | workspace/board | | |
| agents-unified.ts:21 | monitoring/agents | view | activeView deep-link narrowing |
| agent-detail-state.ts:133 | monitoring/agents | | back navigation |
| agent-profile.ts:320,362 | monitoring/agents | agent (line 362) | |
| board-utils.ts:24 | monitoring/agents | agent | |
| otel-metrics.ts:171 | monitoring/agents | keeper | |
| **otel-metrics.ts:181** | **lab/tool-quality** | tool | **⚠️ SILENT MISROUTE** (동일) |
| goals/planning.ts:163 | monitoring/agents | keeper | |
| goals/planning.ts:279 | workspace/goals | | |
| command-palette.ts:91 | command/governance | | |
| **proof-sections.ts:19** | **monitoring/telemetry** | **session_id, operation_id, worker_run_id** | **⚠️ query param 보존 필수** |

## Tests (section 값을 참조하는 테스트)

| 파일:줄 | 대상 section | 용도 |
|---------|------------|------|
| tab-refresh.test.ts:60,65,72,77,84,89,104,116 | agents, activity, intervene, governance, planning, board, tool-quality, inspector | refresh 라우팅 |
| router.test.ts:6,8,13,15,21,26,28,35 | agents, board, intervene, governance | navigate + parseHash |
| control.test.ts:66,75,85,96 | intervene, governance, connectors, inspector | Command surface 렌더 |
| ops/index.test.ts:73,169 | intervene | hydration 효과 |
| observatory-filter-store.test.ts:54,80,83,91,98 | telemetry | keeper/session_id 필터 |
| mission-briefing-card.test.ts:307,358 | intervene | 링크 생성 |
| overview.test.ts:298 | command/governance | 네비게이션 |
| config/navigation.test.ts:27,93 | intervene (default), telemetry | redirect 기존 패턴 |

## Silent Misroutes (즉시 수정 필요)

1. `overview.ts:476`: `linkTab="lab" linkParams=${{ section: 'tool-quality' }}` — lab surface에는 tool-quality section 없음
2. `otel-metrics.ts:181`: `navigate('lab', { section: 'tool-quality', tool: v })` — 동일 문제

현재 `normalizeRouteParams`는 invalid section을 탭 기본값으로 silent fallback → misroute가 가시적 에러 없이 `lab/tools`로 이동.

## Consolidation 영향 분석

### Fleet Health로 흡수되는 section
- `telemetry` (proof-sections.ts의 query param 보존 필수)
- `fleet`
- `tool-quality` (misroute 2건 포함)
- monitoring `governance`

### Operations로 흡수되는 section
- `intervene` — 5곳 producer (router.ts, mission-briefing-card, mission-utils, command/helpers, overview, lab-inspector)
- **ops/index.ts:386 hydration 조건 주의**
- command `governance` — 2곳 producer (overview, command-palette)

### Planning으로 흡수되는 section
- `goals` — 1곳 producer (goals/planning.ts:279, self-link)

### Agents drill-down으로 흡수되는 section
- `fsm-hub` — producer 없음 (navigation만)

### Runtime으로 흡수되는 section
- `metrics` — producer 없음 (navigation만)

## View Param 도입 대상

`fleet-health` 단일 section으로 통합 시 sub-view 구분을 위해 `view` query param 사용:

| Legacy section | Canonical | View |
|---------------|-----------|------|
| telemetry | fleet-health | event-log |
| fleet | fleet-health | comparison |
| tool-quality | fleet-health | tool-quality |
| governance (monitoring) | fleet-health | governance |

Query params 보존 규칙:
- `telemetry` → `fleet-health?view=event-log`: session_id, operation_id, worker_run_id 전달
- `tool-quality` → `fleet-health?view=tool-quality`: tool 전달
- `fleet`, `governance` → 추가 param 없음
