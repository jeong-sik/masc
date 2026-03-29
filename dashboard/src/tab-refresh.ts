import type { RouteState } from './types'
import { refreshExecution, refreshBoard, refreshGoals } from './store'
import { requestRoomTruth } from './room-truth-store'
import { refreshOperatorRoomDigest, refreshOperatorSnapshot } from './operator-store'
import { refreshMissionSnapshot } from './mission-store'

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

async function refreshFeatureHealthSurface(): Promise<void> {
  const { refreshFeatureHealth } = await import('./components/feature-health')
  await refreshFeatureHealth()
}

async function refreshGovernanceSurface(): Promise<void> {
  const { refreshGovernance } = await import('./components/governance-store')
  await refreshGovernance()
}

export type RefreshTask =
  | 'roomTruth'
  | 'missionSnapshot'
  | 'execution'
  | 'activityGraph'
  | 'board'
  | 'goals'
  | 'autoresearch'
  | 'harness'
  | 'featureHealth'
  | 'operatorSnapshot'
  | 'operatorRoomDigest'
  | 'governance'

export function refreshPlanForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): RefreshTask[] {
  switch (routeState.tab) {
    case 'overview':
      return ['roomTruth', 'missionSnapshot']
    case 'monitoring':
      if (routeState.params.section === 'activity') {
        return ['execution', 'activityGraph']
      }
      if (routeState.params.section === 'agents') {
        return ['roomTruth', 'execution', 'missionSnapshot']
      }
      return ['roomTruth', 'missionSnapshot']
    case 'command':
      if (routeState.params.section === 'intervene') {
        return ['roomTruth', 'operatorSnapshot', 'operatorRoomDigest']
      }
      if (routeState.params.section === 'governance') {
        return ['roomTruth', 'governance']
      }
      return []
    case 'workspace':
      if (routeState.params.section === 'planning') {
        return ['goals', 'execution']
      }
      if (routeState.params.section === 'board') {
        return ['board']
      }
      return []
    case 'lab':
      if (routeState.params.section === 'autoresearch') {
        return ['autoresearch']
      }
      if (routeState.params.section === 'harness') {
        return ['harness']
      }
      if (routeState.params.section === 'features') {
        return ['featureHealth']
      }
      return []
    case 'logs':
    default:
      return []
  }
}

const REFRESHERS: Record<RefreshTask, () => void> = {
  roomTruth: () => { requestRoomTruth() },
  missionSnapshot: () => { void refreshMissionSnapshot() },
  execution: () => { void refreshExecution({ force: true }) },
  activityGraph: () => { void refreshActivityGraphSurface() },
  board: () => { void refreshBoard() },
  goals: () => { void refreshGoals() },
  autoresearch: () => { void refreshAutoresearchLabSurface() },
  harness: () => { void refreshHarnessLabSurface() },
  featureHealth: () => { void refreshFeatureHealthSurface() },
  operatorSnapshot: () => { void refreshOperatorSnapshot({ force: true }) },
  operatorRoomDigest: () => { void refreshOperatorRoomDigest({ force: true }) },
  governance: () => { void refreshGovernanceSurface() },
}

export function refreshForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): void {
  refreshPlanForRoute(routeState).forEach(task => {
    REFRESHERS[task]()
  })
}
