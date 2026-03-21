import { route } from './router'
import { refreshExecution, refreshBoard, refreshGoals, refreshTrpg } from './store'
import { refreshRoomTruth } from './room-truth-store'
import { refreshOperatorRoomDigest, refreshOperatorSnapshot } from './operator-store'
import { refreshMissionBriefing, refreshMissionSnapshot } from './mission-store'
import { refreshProofSnapshot } from './proof-store'
import {
  commandPlaneSurface,
  refreshCommandPlaneChainSummary,
  refreshCommandPlaneCurrentSurface,
  refreshCommandPlaneOrchestra,
  refreshCommandPlaneSwarm,
} from './command-store'

async function refreshGovernanceSurface(): Promise<void> {
  const { refreshGovernance } = await import('./components/governance')
  await refreshGovernance()
}

async function refreshToolsSurface(): Promise<void> {
  const { refreshTools } = await import('./components/tools')
  await refreshTools()
}

async function refreshActivityGraphSurface(): Promise<void> {
  const { refreshActivityGraph } = await import('./components/activity-graph')
  await refreshActivityGraph()
}

export function refreshForTab(tab: string) {
  if (tab === 'home') {
    refreshRoomTruth()
    refreshExecution()
    refreshMissionSnapshot()
  }

  if (tab === 'status') {
    const section = route.value.params.section
    if (section === 'activity') {
      refreshExecution()
      void refreshActivityGraphSurface()
    } else if (section === 'agents') {
      refreshRoomTruth()
      refreshExecution()
      refreshMissionSnapshot()
    } else {
      refreshRoomTruth()
      refreshMissionSnapshot('full')
      refreshMissionBriefing()
    }
  }

  if (tab === 'work') {
    const section = route.value.params.section
    if (section === 'evidence') {
      refreshProofSnapshot(route.value.params.session_id, route.value.params.operation_id)
    } else if (section === 'governance') {
      void refreshGovernanceSurface()
    } else if (section === 'planning') {
      refreshGoals()
      refreshExecution()
    } else {
      refreshBoard()
    }
  }

  if (tab === 'operations') {
    const section = route.value.params.section
    if (section === 'command') {
      refreshRoomTruth()
      refreshCommandPlaneCurrentSurface()
      refreshCommandPlaneChainSummary()
      if (
        commandPlaneSurface.value === 'swarm'
        || commandPlaneSurface.value === 'warroom'
        || commandPlaneSurface.value === 'orchestra'
      ) {
        refreshCommandPlaneSwarm()
      }
      if (commandPlaneSurface.value === 'orchestra') {
        refreshCommandPlaneOrchestra()
      }
      if (commandPlaneSurface.value === 'warroom') {
        refreshOperatorSnapshot()
      }
    } else if (section === 'tools') {
      void refreshToolsSurface()
    } else {
      refreshRoomTruth()
      refreshOperatorSnapshot()
      refreshOperatorRoomDigest()
    }
  }

  if (tab === 'lab') {
    const section = route.value.params.section
    if (section === 'trpg') {
      refreshTrpg()
    } else if (section === 'avatars' || section === 'overview') {
      refreshRoomTruth()
    } else {
      refreshRoomTruth()
    }
  }
}
