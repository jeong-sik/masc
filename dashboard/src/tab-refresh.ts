import type { RouteState } from './types'
import { refreshExecution, refreshBoard, refreshGoals, refreshShell } from './store'
import { requestNamespaceTruth } from './namespace-truth-store'
import { refreshMissionSnapshot } from './mission-store'
import { refreshOperatorRoomDigest, refreshOperatorSnapshot } from './operator-store'
import { refreshProofSnapshot } from './proof-store'

async function refreshActivityGraphSurface(): Promise<void> {
  const { refreshActivityGraph } = await import('./components/activity-graph')
  await refreshActivityGraph()
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

export type RefreshTask =
  | 'shell'
  | 'namespaceTruth'
  | 'missionSnapshot'
  | 'execution'
  | 'activityGraph'
  | 'board'
  | 'proof'
  | 'goals'
  | 'autoresearch'
  | 'harness'
  | 'toolQuality'
  | 'inspector'
  | 'operatorSnapshot'
  | 'operatorRoomDigest'

export function refreshPlanForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): RefreshTask[] {
  switch (routeState.tab) {
    case 'overview':
      return ['shell', 'namespaceTruth', 'missionSnapshot']
    case 'monitoring':
      if (routeState.params.section === 'activity') {
        return ['execution', 'activityGraph']
      }
      if (routeState.params.section === 'agents') {
        return ['namespaceTruth', 'execution', 'missionSnapshot']
      }
      return ['namespaceTruth', 'missionSnapshot']
    case 'command':
      return ['namespaceTruth', 'operatorSnapshot', 'operatorRoomDigest']
    case 'workspace':
      if (routeState.params.section === 'planning') {
        return ['goals', 'execution']
      }
      if (routeState.params.section === 'goals') {
        return ['goals']
      }
      if (routeState.params.section === 'board') {
        return ['board']
      }
      if (routeState.params.section === 'evidence') {
        return ['proof']
      }
      return []
    case 'lab':
      if (routeState.params.section === 'autoresearch') {
        return ['autoresearch']
      }
      if (routeState.params.section === 'harness') {
        return ['harness']
      }
      if (routeState.params.section === 'tool-quality') {
        return ['toolQuality']
      }
      if (routeState.params.section === 'inspector') {
        return ['inspector']
      }
      return []
    case 'logs':
    default:
      return []
  }
}

const REFRESHERS: Record<RefreshTask, (routeState: Pick<RouteState, 'tab' | 'params'>) => void> = {
  shell: () => { void refreshShell({ force: true }) },
  namespaceTruth: () => { requestNamespaceTruth() },
  missionSnapshot: () => { void refreshMissionSnapshot() },
  execution: () => { void refreshExecution({ force: true }) },
  activityGraph: () => { void refreshActivityGraphSurface() },
  board: () => { void refreshBoard() },
  proof: routeState => {
    void refreshProofSnapshot(
      routeState.params.session_id ?? null,
      routeState.params.operation_id ?? null,
    )
  },
  goals: () => { void refreshGoals() },
  autoresearch: () => { void refreshAutoresearchLabSurface() },
  harness: () => { void refreshHarnessLabSurface() },
  toolQuality: () => { void refreshToolQualityLabSurface() },
  inspector: () => {
    void refreshFeatureHealthSurface()
    void refreshServerConfigSurface()
  },
  operatorSnapshot: () => { void refreshOperatorSnapshot({ force: true }) },
  operatorRoomDigest: () => { void refreshOperatorRoomDigest({ force: true }) },
}

// --- Tab visit counter (localStorage-persisted) ---

const VISIT_COUNTER_KEY = 'masc_dashboard_tab_visits'

function recordTabVisit(tab: string, section?: string): void {
  try {
    const raw = localStorage.getItem(VISIT_COUNTER_KEY)
    const counts: Record<string, number> = raw ? JSON.parse(raw) : {}
    const key = section ? `${tab}/${section}` : tab
    counts[key] = (counts[key] ?? 0) + 1
    localStorage.setItem(VISIT_COUNTER_KEY, JSON.stringify(counts))
  } catch {
    // localStorage unavailable or quota exceeded — skip silently
  }
}

export function getTabVisitCounts(): Record<string, number> {
  try {
    const raw = localStorage.getItem(VISIT_COUNTER_KEY)
    return raw ? JSON.parse(raw) : {}
  } catch {
    return {}
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
