import type { RouteState } from './types'
import { refreshExecution, refreshBoard, refreshGoals } from './store'
import { refreshRoomTruth } from './room-truth-store'
import { refreshOperatorRoomDigest, refreshOperatorSnapshot } from './operator-store'
import { refreshMissionSnapshot } from './mission-store'
import {
  commandPlaneSurface,
  refreshCommandPlaneChainSummary,
  refreshCommandPlaneCurrentSurface,
  refreshCommandPlaneOrchestra,
  refreshCommandPlaneSwarm,
} from './command-store'

async function refreshActivityGraphSurface(): Promise<void> {
  const { refreshActivityGraph } = await import('./components/activity-graph')
  await refreshActivityGraph()
}

export type RefreshTask =
  | 'roomTruth'
  | 'missionSnapshot'
  | 'execution'
  | 'activityGraph'
  | 'board'
  | 'goals'
  | 'commandCurrentSurface'
  | 'commandChainSummary'
  | 'commandSwarm'
  | 'commandOrchestra'
  | 'operatorSnapshot'
  | 'operatorRoomDigest'

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
      if (routeState.params.section === 'warroom') {
        const tasks: RefreshTask[] = [
          'roomTruth',
          'commandCurrentSurface',
          'commandChainSummary',
        ]
        if (
          commandPlaneSurface.value === 'swarm'
          || commandPlaneSurface.value === 'orchestra'
        ) {
          tasks.push('commandSwarm')
        }
        if (commandPlaneSurface.value === 'orchestra') {
          tasks.push('commandOrchestra')
        }
        return tasks
      }
      if (routeState.params.section === 'intervene') {
        return ['roomTruth', 'operatorSnapshot', 'operatorRoomDigest']
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
      if (routeState.params.section === 'avatars') {
        return ['execution']
      }
      if (routeState.params.section === 'overview') {
        return ['roomTruth']
      }
      return []
    case 'logs':
    default:
      return []
  }
}

const REFRESHERS: Record<RefreshTask, () => void> = {
  roomTruth: () => { void refreshRoomTruth() },
  missionSnapshot: () => { void refreshMissionSnapshot() },
  execution: () => { void refreshExecution({ force: true }) },
  activityGraph: () => { void refreshActivityGraphSurface() },
  board: () => { void refreshBoard() },
  goals: () => { void refreshGoals() },
  commandCurrentSurface: () => { void refreshCommandPlaneCurrentSurface({ force: true }) },
  commandChainSummary: () => { void refreshCommandPlaneChainSummary({ force: true }) },
  commandSwarm: () => { void refreshCommandPlaneSwarm(undefined, undefined, { force: true }) },
  commandOrchestra: () => { void refreshCommandPlaneOrchestra(undefined, undefined, { force: true }) },
  operatorSnapshot: () => { void refreshOperatorSnapshot({ force: true }) },
  operatorRoomDigest: () => { void refreshOperatorRoomDigest({ force: true }) },
}

export function refreshForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): void {
  refreshPlanForRoute(routeState).forEach(task => {
    REFRESHERS[task]()
  })
}
