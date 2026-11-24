import type { RouteState } from './types'
import { routeRequiresExecutionAuthority } from './execution-authority-routes'
import { refreshExecution, refreshBoard, refreshFusionBoard, refreshFusionRuns, refreshGoals, refreshShell } from './store'
import { requestNamespaceTruth } from './namespace-truth-store'
import { refreshMissionSnapshot } from './mission-store'

async function refreshToolQualityLabSurface(): Promise<void> {
  const { refreshToolQuality } = await import('./components/tool-quality-panel')
  await refreshToolQuality()
}

async function refreshActiveKeeperChatSurface(): Promise<void> {
  const { refreshActiveKeeperChatHistory } = await import('./keeper-runtime')
  refreshActiveKeeperChatHistory()
}

type RefreshTask =
  | 'shell'
  | 'namespaceTruth'
  | 'missionSnapshot'
  | 'execution'
  | 'board'
  | 'fusionBoard'
  | 'goals'
  | 'toolQuality'
  | 'fusionRuns'
  | 'activeKeeperChat'

const HIDDEN_DIAGNOSTIC_FALLBACK_PLAN: readonly RefreshTask[] = ['namespaceTruth', 'missionSnapshot']

export function refreshPlanForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): RefreshTask[] {
  const plan = surfaceRefreshPlanForRoute(routeState)
  return routeRequiresExecutionAuthority(routeState) ? [...new Set<RefreshTask>([...plan, 'execution'])] : plan
}

function surfaceRefreshPlanForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): RefreshTask[] {
  switch (routeState.tab) {
    case 'overview':
      return ['shell', 'namespaceTruth', 'missionSnapshot', 'execution', 'goals']
    case 'keepers':
      return ['namespaceTruth', 'execution', 'missionSnapshot', 'activeKeeperChat']
    case 'board':
      return ['board']
    case 'fusion':
      return ['fusionBoard', 'fusionRuns']
    case 'monitoring':
      if (!routeState.params.section || routeState.params.section === 'runtime') {
        return ['namespaceTruth', 'missionSnapshot']
      }
      if (routeState.params.section === 'fleet-health') {
        const view = routeState.params.view
        if (view === 'tool-quality') return ['toolQuality']
        return ['namespaceTruth']
      }
      return [...HIDDEN_DIAGNOSTIC_FALLBACK_PLAN]
    case 'workspace': {
      const section = routeState.params.section
      if (!section || section === 'work') {
        return ['goals', 'execution']
      }
      if (section === 'board') {
        return ['board']
      }
      return []
    }
    case 'logs':
    default:
      return []
  }
}

const REFRESHERS: Record<RefreshTask, (routeState: Pick<RouteState, 'tab' | 'params'>) => void> = {
  shell: () => { void refreshShell({ light: true }) },
  namespaceTruth: () => { requestNamespaceTruth() },
  missionSnapshot: () => { void refreshMissionSnapshot() },
  execution: routeState => {
    if (routeState.tab === 'overview') {
      void refreshExecution({ immediate: true })
    } else {
      void refreshExecution()
    }
  },
  board: () => { void refreshBoard() },
  fusionBoard: () => { void refreshFusionBoard() },
  goals: () => { void refreshGoals() },
  toolQuality: () => { void refreshToolQualityLabSurface() },
  fusionRuns: () => { void refreshFusionRuns() },
  activeKeeperChat: () => { void refreshActiveKeeperChatSurface() },
}

const VISIT_COUNTER_KEY = 'masc_dashboard_tab_visits'
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
