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
import { refreshGovernance } from './components/governance'
import { refreshTools } from './components/tools'
import { refreshSocial } from './components/social'

export function refreshForTab(tab: string) {
  if (tab === 'home') {
    refreshRoomTruth()
    refreshExecution()
    refreshMissionSnapshot()
  }

  if (tab === 'situation') {
    refreshRoomTruth()
    refreshMissionSnapshot()
    refreshMissionBriefing()
  }

  if (tab === 'agents') {
    refreshRoomTruth()
    refreshExecution()
    refreshMissionSnapshot()
  }

  if (tab === 'activity') {
    refreshExecution()
    refreshSocial()
  }

  if (tab === 'work') {
    const section = route.value.params.section
    if (section === 'evidence') {
      refreshProofSnapshot(route.value.params.session_id, route.value.params.operation_id)
    } else if (section === 'governance') {
      refreshGovernance()
    } else if (section === 'planning') {
      refreshGoals()
      refreshExecution()
    } else {
      refreshBoard()
    }
  }

  if (tab === 'control') {
    const section = route.value.params.section
    if (section === 'tools') {
      refreshTools()
    } else {
      refreshRoomTruth()
      refreshOperatorSnapshot()
      refreshOperatorRoomDigest()
    }
  }

  if (tab === 'lab') {
    const surface = route.value.params.surface
    if (surface === 'trpg') {
      refreshTrpg()
    } else {
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
    }
  }
}
