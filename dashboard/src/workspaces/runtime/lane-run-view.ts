// Decisions the Runtime tabs make about one decoded lane run. Pure functions
// over the decoder's output (api/dashboard-exact-lane-runs.ts).

import type {
  ExactLaneIntendedStatus,
  ExactLanePersistenceState,
  LaneRunSummary,
} from '../../api/dashboard-exact-lane-runs'

export type LaneRunPassReading = 'running' | 'passed' | 'not_passed'

/** Whether a finished run counts toward the Efficiency pass rate. Each run
 *  kind has its own pass label: an exact run that succeeded, a Task review
 *  that approved, a Goal review that committed. */
export function laneRunPassReading(run: LaneRunSummary): LaneRunPassReading {
  if (run.status === 'running') return 'running'
  switch (run.runKind) {
    case 'exact_output': return run.status === 'succeeded' ? 'passed' : 'not_passed'
    case 'task_verification': return run.status === 'approved' ? 'passed' : 'not_passed'
    case 'goal_verification': return run.status === 'committed' ? 'passed' : 'not_passed'
  }
}

/** An exact run whose producer finished but whose completion record did not
 *  reach the registry (lib/exact_lane_run_registry.ml pending completion).
 *  `intendedStatus` is how the run actually ended; `persistenceError` is why
 *  the record was not written. */
export interface LaneRunCompletionGap {
  readonly persistenceState: ExactLanePersistenceState
  readonly persistenceError: string
  readonly intendedStatus: ExactLaneIntendedStatus
  /** Present only when the run ended as failed. */
  readonly intendedCode: string | null
  readonly intendedDetail: string | null
}

export function laneRunCompletionGap(run: LaneRunSummary): LaneRunCompletionGap | null {
  if (run.runKind !== 'exact_output') return null
  const { persistenceState, persistenceError, intendedStatus } = run
  if (persistenceState === undefined || persistenceError === undefined || intendedStatus === undefined) return null
  return {
    persistenceState,
    persistenceError,
    intendedStatus,
    intendedCode: run.intendedCode ?? null,
    intendedDetail: run.intendedDetail ?? null,
  }
}

export function persistenceStateLabel(state: ExactLanePersistenceState): string {
  switch (state) {
    case 'not_persisted': return '완료 기록을 저장하지 못함'
    case 'durability_unknown': return '완료 기록이 저장됐는지 모름'
  }
}
