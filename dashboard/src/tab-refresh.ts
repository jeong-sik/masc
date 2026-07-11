import type { RouteState } from './types'
import { refreshExecution, refreshBoard, refreshFusionBoard, refreshFusionRuns, refreshGoals, refreshShell } from './store'
import { requestNamespaceTruth } from './namespace-truth-store'
import { refreshMissionSnapshot } from './mission-store'
import { refreshOperatorWorkspaceDigest, refreshOperatorSnapshot } from './operator-store'

async function refreshObservatoryPanel(): Promise<void> {
  const { refreshObservatorySurface } = await import('./components/observatory/observatory')
  refreshObservatorySurface()
}

async function refreshHarnessLabSurface(): Promise<void> {
  const { refreshHarnessSurface } = await import('./components/harness-health-state')
  await refreshHarnessSurface()
}

async function refreshToolQualityLabSurface(): Promise<void> {
  const { refreshToolQuality } = await import('./components/tool-quality-panel')
  await refreshToolQuality()
}

async function refreshFeatureHealthSurface(): Promise<void> {
  const { refreshFeatureHealth } = await import('./components/feature-health')
  await refreshFeatureHealth()
}

async function refreshServerConfigSurface(): Promise<void> {
  const { refreshServerConfig } = await import('./components/server-config')
  await refreshServerConfig()
}

async function refreshSurfaceReadinessSurface(): Promise<void> {
  const { refreshSurfaceReadiness } = await import('./components/surface-readiness-panel')
  await refreshSurfaceReadiness()
}

async function refreshActiveKeeperChatSurface(): Promise<void> {
  const { refreshActiveKeeperChatHistory } = await import('./keeper-runtime')
  // Guard-respecting (non-force): a no-op while the open keeper's transcript
  // is already hydrated, so route visits and the periodic refresh do not poll
  // the history endpoint. The SSE reconnect path forces its own re-hydration.
  refreshActiveKeeperChatHistory()
}

async function refreshGovernanceSurface(): Promise<void> {
  const { refreshGovernance } = await import('./components/governance-refresh')
  await refreshGovernance()
}

type RefreshTask =
  | 'shell'
  | 'namespaceTruth'
  | 'missionSnapshot'
  | 'execution'
  | 'observatory'
  | 'board'
  | 'fusionBoard'
  | 'goals'
  | 'harness'
  | 'toolQuality'
  | 'inspector'
  | 'surfaceReadiness'
  | 'operatorSnapshot'
  | 'operatorWorkspaceDigest'
  | 'fusionRuns'
  | 'activeKeeperChat'
  | 'governance'

// Monitor data ownership is partitioned by section. Two tiers:
//   Tier 1 — visible lanes (agents / fleet-health / runtime / observatory)
//            each declare their own view-aware or static refresh plan.
//   Tier 2 — hidden diagnostic sections (
//            transport-health / feature-health) share an identical light
//            fallback plan. Their mounted panels own telemetry polling, so
//            route visits only need to refresh namespace/mission context.
//   Outliers — `journey` (execution only) and `cognition` keep dedicated
//            branches above.
const HIDDEN_DIAGNOSTIC_FALLBACK_PLAN: readonly RefreshTask[] = ['namespaceTruth', 'missionSnapshot']

export function refreshPlanForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): RefreshTask[] {
  switch (routeState.tab) {
    case 'overview':
      // 'fusionRuns' and 'governance' feed the KPI strip + domain cards
      // (진행 심의 / 열린 승인) that the overview surface renders unconditionally.
      // Without them here those signals only populate after a Fusion/Approvals
      // tab visit, so the default landing tab showed 0/empty regardless of the
      // live fleet state (masc campaign #43).
      return ['shell', 'namespaceTruth', 'missionSnapshot', 'execution', 'fusionRuns', 'governance']
    case 'keepers':
      // 'activeKeeperChat' re-hydrates the open conversation panel's transcript
      // (guard-respecting no-op when already loaded). It matters on SSE
      // reconnect: the route refresh runs after a disconnect and recovers the
      // open keeper's history when replayed events fell outside the buffer.
      return ['namespaceTruth', 'execution', 'missionSnapshot', 'activeKeeperChat']
    case 'board':
      return ['board']
    case 'fusion':
      // 'fusionBoard' feeds the board-meta-derived detail browser without
      // inheriting Board-route filters; 'fusionRuns' feeds the registry-backed
      // live status panel (running + recent) that the SSE `fusion_run_status`
      // event also re-fetches.
      return ['fusionBoard', 'fusionRuns']
    case 'monitoring':
      if (routeState.params.section === 'observatory') {
        return ['namespaceTruth', 'observatory']
      }
      if (routeState.params.section === 'journey') {
        return ['execution']
      }
      if (!routeState.params.section || routeState.params.section === 'agents') {
        return ['namespaceTruth', 'execution', 'missionSnapshot']
      }
      if (routeState.params.section === 'cognition') {
        return ['namespaceTruth', 'execution', 'missionSnapshot']
      }
      // fleet-health: view-aware refresh (Phase 1 contract from tab-refresh.test.ts)
      if (routeState.params.section === 'fleet-health') {
        const view = routeState.params.view
        if (view === 'tool-quality') return ['toolQuality']
        if (view === 'comparison') return ['execution', 'toolQuality']
        // default + event-log + governance: keep the route visit light.
        // Mounted fleet-health panels own telemetry/tool/governance polling.
        return ['namespaceTruth']
      }
      // Hidden diagnostic sections fall through here. See the
      // HIDDEN_DIAGNOSTIC_FALLBACK_PLAN definition above for the tier split.
      return [...HIDDEN_DIAGNOSTIC_FALLBACK_PLAN]
    case 'command':
      if (routeState.params.view === 'inspector') {
        return ['inspector']
      }
      if (routeState.params.view === 'surfaces') {
        return ['surfaceReadiness']
      }
      return ['namespaceTruth', 'operatorSnapshot', 'operatorWorkspaceDigest']
    case 'workspace': {
      const section = routeState.params.section
      // 'work' (the default section) and 'planning' are both store-backed
      // goal/task surfaces: WorkSurfaceV2 (work) and PlanningPanel (planning)
      // render the flat `goals` + `tasks` signals. Those signals are only
      // populated by the `goals` (planning fetch) and `execution` refreshers.
      // Before this branch, landing on the default Work board returned [] and
      // left both signals empty, so the board showed 0 goals / 0 jobs even
      // though live planning/execution data existed.
      if (!section || section === 'work' || section === 'planning') {
        return ['goals', 'execution']
      }
      if (section === 'board') {
        return ['board']
      }
      return []
    }
    case 'lab':
      if (routeState.params.section === 'harness') {
        return ['harness']
      }
      return []
    case 'code':
      return ['namespaceTruth', 'execution', 'missionSnapshot']
    case 'logs':
    default:
      return []
  }
}

const REFRESHERS: Record<RefreshTask, (routeState: Pick<RouteState, 'tab' | 'params'>) => void> = {
  // Route visits should reuse the existing shell TTL instead of forcing a
  // fresh projection on every navigation.
  shell: () => { void refreshShell({ light: true }) },
  namespaceTruth: () => { requestNamespaceTruth() },
  missionSnapshot: () => { void refreshMissionSnapshot() },
  // Execution already has a fetch scheduler; route refreshes should enqueue
  // through that budgeted path instead of bypassing it.
  execution: routeState => {
    // Overview first paint already has the shell snapshot; the execution
    // snapshot fills the visible attention/fleet rows. Do not pay the generic
    // 300ms debounce on the first screen, but also do not force backend cache
    // recomputation.
    if (routeState.tab === 'overview') {
      void refreshExecution({ immediate: true })
    } else {
      void refreshExecution()
    }
  },
  observatory: () => { void refreshObservatoryPanel() },
  board: () => { void refreshBoard() },
  fusionBoard: () => { void refreshFusionBoard() },
  goals: () => { void refreshGoals() },
  harness: () => { void refreshHarnessLabSurface() },
  toolQuality: () => { void refreshToolQualityLabSurface() },
  inspector: () => {
    void refreshFeatureHealthSurface()
    void refreshServerConfigSurface()
  },
  surfaceReadiness: () => { void refreshSurfaceReadinessSurface() },
  operatorSnapshot: () => { void refreshOperatorSnapshot({ force: true }) },
  operatorWorkspaceDigest: () => { void refreshOperatorWorkspaceDigest({ force: true }) },
  fusionRuns: () => { void refreshFusionRuns() },
  activeKeeperChat: () => { void refreshActiveKeeperChatSurface() },
  governance: () => { void refreshGovernanceSurface() },
}

// --- Tab visit counter (localStorage-persisted) ---

const VISIT_COUNTER_KEY = 'masc_dashboard_tab_visits'

// In-memory fallback when localStorage is unavailable (private mode,
// quota exceeded, etc.) — keeps visit counters useful for the duration
// of the tab session even when persistence is broken.
let inMemoryVisitCounts: Record<string, number> | null = null

function recordTabVisit(tab: string, section?: string): void {
  const key = section ? `${tab}/${section}` : tab
  try {
    const raw = localStorage.getItem(VISIT_COUNTER_KEY)
    const counts: Record<string, number> = raw ? JSON.parse(raw) : {}
    counts[key] = (counts[key] ?? 0) + 1
    localStorage.setItem(VISIT_COUNTER_KEY, JSON.stringify(counts))
    inMemoryVisitCounts = null
  } catch (err) {
    // P2 silent-failure fix: localStorage unavailable (private mode,
    // quota exceeded, sandboxed iframe).  Previously the visit counter
    // froze entirely for the rest of the tab session and analytics
    // lost the navigation pattern.  Now: log once on the first
    // failure, then maintain an in-memory counter so the data is at
    // least available within the session even if not persisted.
    if (inMemoryVisitCounts === null) {
      console.warn('[tab-refresh] localStorage unavailable, falling back to in-memory visit counter', err)
      inMemoryVisitCounts = {}
    }
    inMemoryVisitCounts[key] = (inMemoryVisitCounts[key] ?? 0) + 1
  }
}

export function refreshForRoute(
  routeState: Pick<RouteState, 'tab' | 'params'>,
  options?: { recordVisit?: boolean },
): void {
  if (options?.recordVisit === true) {
    recordTabVisit(routeState.tab, routeState.params.section)
  }
  refreshPlanForRoute(routeState).forEach(task => {
    REFRESHERS[task](routeState)
  })
}
