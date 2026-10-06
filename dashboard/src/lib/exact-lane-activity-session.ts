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
  afterCommit: async signal => (await resumeSavedModelSetup({ signal })).kind === 'failed'
    && modelSetupResumeState.peek().kind !== 'active'
    ? '설정은 저장됐지만 런타임 재개를 확인하지 못했습니다. Runtime 설정에서 재개를 다시 시도하세요.' : null,
  announceObservation: announceExactLaneObservationChanged,
})

export const exactLaneActivitySessionFor = exact.sessionFor
export const resetExactLaneActivitySessionsForTesting = exact.resetForTesting
