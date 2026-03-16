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

  if (tab === 'command') {
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

  if (tab === 'mission') {
    refreshRoomTruth()
    refreshMissionSnapshot()
    refreshMissionBriefing()
  }

  if (tab === 'proof') {
    refreshProofSnapshot(route.value.params.session_id, route.value.params.operation_id)
  }

  if (tab === 'execution') {
    refreshRoomTruth()
    refreshExecution()
  }

  if (tab === 'intervene') {
    refreshRoomTruth()
    refreshOperatorSnapshot()
    refreshOperatorRoomDigest()
  }

  if (tab === 'memory') refreshBoard()
  if (tab === 'planning') refreshGoals()
  if (tab === 'lab') refreshTrpg()
  if (tab === 'governance') refreshGovernance()
  if (tab === 'live') refreshExecution()
  if (tab === 'tools') refreshTools()
  if (tab === 'social') refreshSocial()
}
