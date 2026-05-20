import type { RouteState } from './types'
import { refreshExecution, refreshBoard, refreshGoals, refreshShell } from './store'
import { requestNamespaceTruth } from './namespace-truth-store'
import { refreshMissionSnapshot } from './mission-store'
import { refreshOperatorRoomDigest, refreshOperatorSnapshot } from './operator-store'

async function refreshActivityGraphSurface(): Promise<void> {
  const { refreshActivityGraph } = await import('./components/activity-graph-store')
  await refreshActivityGraph()
}

async function refreshGitGraphSurface(): Promise<void> {
  const { refreshGitGraph } = await import('./components/git-graph-store')
  await refreshGitGraph()
}

async function refreshObservatoryPanel(): Promise<void> {
  const { refreshObservatorySurface } = await import('./components/observatory/observatory')
  refreshObservatorySurface()
}

async function refreshAutoresearchLabSurface(): Promise<void> {
  const { refreshAutoresearchSurface } = await import('./components/autoresearch')
  await refreshAutoresearchSurface()
}

async function refreshHarnessLabSurface(): Promise<void> {
  const { refreshHarnessSurface } = await import('./components/harness-health')
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

async function refreshDoctorSurface(): Promise<void> {
  const { refreshDoctor } = await import('./components/doctor-panel')
  await refreshDoctor()
}

async function refreshSurfaceReadinessSurface(): Promise<void> {
  const { refreshSurfaceReadiness } = await import('./components/surface-readiness-panel')
  await refreshSurfaceReadiness()
}

async function refreshCascadeInspectorSurface(): Promise<void> {
  const { refreshCascadeInspector } = await import('./components/cascade-inspector')
  await refreshCascadeInspector()
}

type RefreshTask =
  | 'shell'
  | 'namespaceTruth'
  | 'missionSnapshot'
  | 'execution'
  | 'observatory'
  | 'activityGraph'
  | 'gitGraph'
  | 'board'
  | 'goals'
  | 'autoresearch'
  | 'harness'
  | 'toolQuality'
  | 'inspector'
  | 'surfaceReadiness'
  | 'cascadeInspector'
  | 'operatorSnapshot'
  | 'operatorRoomDigest'

// Monitor data ownership is partitioned by section. Two tiers:
//   Tier 1 — visible lanes (agents / fleet-health / runtime / observatory)
//            each declare their own view-aware or static refresh plan.
//   Tier 2 — hidden diagnostic sections (cascade-config / doctor /
//            transport-health / feature-health) share an identical light
//            fallback plan. Their mounted panels own telemetry polling, so
//            route visits only need to refresh namespace/mission context.
//   Outliers — `journey` (execution only) and `cognition` (4-source plan
//            with autoresearch) keep dedicated branches above.
const HIDDEN_DIAGNOSTIC_FALLBACK_PLAN: readonly RefreshTask[] = ['namespaceTruth', 'missionSnapshot']

export function refreshPlanForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): RefreshTask[] {
  switch (routeState.tab) {
    case 'overview':
      return ['shell', 'namespaceTruth', 'missionSnapshot', 'execution']
    case 'monitoring':
      if (routeState.params.section === 'observatory') {
        const view = routeState.params.view
        if (view === 'activity' || view === 'graph') return ['namespaceTruth', 'activityGraph']
        if (view === 'live') return ['namespaceTruth', 'execution', 'missionSnapshot']
        return ['namespaceTruth', 'observatory']
      }
      if (routeState.params.section === 'journey') {
        return ['execution']
      }
      if (!routeState.params.section || routeState.params.section === 'agents') {
        return ['namespaceTruth', 'execution', 'missionSnapshot']
      }
      if (routeState.params.section === 'cognition') {
        return ['namespaceTruth', 'execution', 'missionSnapshot', 'autoresearch']
      }
      if (routeState.params.section === 'runtime' && routeState.params.view === 'inspector') {
        return ['cascadeInspector']
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
      return ['namespaceTruth', 'operatorSnapshot', 'operatorRoomDigest']
    case 'workspace':
      if (routeState.params.section === 'planning') {
        return ['goals', 'execution']
      }
      if (routeState.params.section === 'board') {
        return ['board']
      }
      if (routeState.params.section === 'repositories' && routeState.params.view === 'graph') {
        return ['gitGraph']
      }
      return []
    case 'lab':
      if (routeState.params.section === 'autoresearch') {
        return ['autoresearch']
      }
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
  execution: () => { void refreshExecution() },
  observatory: () => { void refreshObservatoryPanel() },
  activityGraph: () => { void refreshActivityGraphSurface() },
  gitGraph: () => { void refreshGitGraphSurface() },
  board: () => { void refreshBoard() },
  goals: () => { void refreshGoals() },
  autoresearch: () => { void refreshAutoresearchLabSurface() },
  harness: () => { void refreshHarnessLabSurface() },
  toolQuality: () => { void refreshToolQualityLabSurface() },
  inspector: () => {
    void refreshFeatureHealthSurface()
    void refreshServerConfigSurface()
    void refreshDoctorSurface()
  },
  surfaceReadiness: () => { void refreshSurfaceReadinessSurface() },
  cascadeInspector: () => { void refreshCascadeInspectorSurface() },
  operatorSnapshot: () => { void refreshOperatorSnapshot({ force: true }) },
  operatorRoomDigest: () => { void refreshOperatorRoomDigest({ force: true }) },
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
