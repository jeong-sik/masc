import { readExactActivity, writeExactActivity, type ExactActivityLane } from './exact-lane-activity'
import { modelSetupResumeState, resumeSavedModelSetup } from './model-setup-resume'
import { announceExactLaneObservationChanged } from './exact-lane-observation'
import { laneActivitySessions, type LaneActivitySession } from './lane-activity-session'

export type ExactLaneActivitySession = LaneActivitySession<ExactActivityLane, never>

const exact = laneActivitySessions<ExactActivityLane>({
  key: lane => lane.laneId,
  read: readExactActivity,
  write: writeExactActivity,
  // An Exact lane's slots are published by resuming the saved model setup. A
  // newer resume that already succeeded answers for this save too.
  afterCommit: async signal => (await resumeSavedModelSetup({ signal })).kind === 'active'
    || modelSetupResumeState.peek().kind === 'active',
  announceObservation: announceExactLaneObservationChanged,
})

export const exactLaneActivitySessionFor = exact.sessionFor
export const resetExactLaneActivitySessionsForTesting = exact.resetForTesting
