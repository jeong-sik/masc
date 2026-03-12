import { route } from './router'
import { refreshExecution, refreshBoard, refreshGoals, refreshTrpg } from './store'
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

export function refreshForTab(tab: string) {
  if (tab === 'command') {
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

  if (tab === 'mission') {
    refreshMissionSnapshot()
    refreshMissionBriefing()
  }

  if (tab === 'proof') {
    refreshProofSnapshot(route.value.params.session_id, route.value.params.operation_id)
  }

  if (tab === 'execution') refreshExecution()

  if (tab === 'intervene') {
    refreshOperatorSnapshot()
    refreshOperatorRoomDigest()
  }

  if (tab === 'memory') refreshBoard()
  if (tab === 'planning') refreshGoals()
  if (tab === 'lab') refreshTrpg()
}
