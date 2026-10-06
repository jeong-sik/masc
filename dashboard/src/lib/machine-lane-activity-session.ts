import { fetchLaneInventory, type LaneInventoryRow } from '../api/lane-inventory'
import { readMachineActivity, writeMachineActivity, type MachineActivityLane } from './machine-lane-activity'
import { announceMachineLaneObservationChanged } from './machine-lane-observation'
import { laneActivitySessions, type LaneActivityObservation, type LaneActivitySession } from './lane-activity-session'

/** Server activity from the lane inventory, read apart from the file. */
type MachineObservation = { activity: Extract<LaneInventoryRow['state'], { kind: 'machine' }>['activity']; at: number }
export type MachineLaneActivitySession = LaneActivitySession<MachineActivityLane, MachineObservation>

async function observe(lane: MachineActivityLane): Promise<LaneActivityObservation<MachineObservation>> {
  const inventory = await fetchLaneInventory()
  const row = inventory.rows.find(row => row.selection.kind === 'machine' && row.selection.machine === lane)
  return row?.state.kind === 'machine' ? { kind: 'observed', activity: row.state.activity, at: inventory.observed_at }
    : { kind: 'failed', error: '현재 목록에서 선택한 기계를 확인하지 못했습니다.' }
}

// Raw save publishes machine activity; model setup resume cannot load or
// restore a machine, so a Machine save has no afterCommit. A receipt alone is
// not an owner observation, so the next read asks the inventory again.
const machine = laneActivitySessions<MachineActivityLane, MachineObservation>({
  key: lane => lane,
  read: readMachineActivity,
  write: writeMachineActivity,
  announceObservation: announceMachineLaneObservationChanged,
  observe,
})

export const machineLaneActivitySessionFor = machine.sessionFor
export const resetMachineLaneActivitySessionsForTesting = machine.resetForTesting
