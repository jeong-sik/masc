import { describe, expect, it } from 'vitest'
import type { LaneRunSummary } from '../../api/dashboard-exact-lane-runs'
import { laneRunCompletionGap, laneRunPassReading } from './lane-run-view'

type Exact = Extract<LaneRunSummary, { runKind: 'exact_output' }>
type Task = Extract<LaneRunSummary, { runKind: 'task_verification' }>
type Goal = Extract<LaneRunSummary, { runKind: 'goal_verification' }>

const exact = (over: Partial<Exact> = {}): LaneRunSummary => ({
  runId: 'e', runKind: 'exact_output', lane: 'librarian_exact', subjectId: null, actor: 'a', startedAt: 1,
  status: 'succeeded', ...over,
})
const task = (status: Task['status']): LaneRunSummary => ({
  runId: 't', runKind: 'task_verification', lane: 'verifier_exact', subjectId: 'task-1', actor: 'a', startedAt: 1, status,
})
const goal = (status: Goal['status']): LaneRunSummary => ({
  runId: 'g', runKind: 'goal_verification', lane: 'verifier_exact', subjectId: 'goal-1', actor: 'a', startedAt: 1, status,
})

describe('laneRunPassReading', () => {
  it('reads each run kind by its own pass label', () => {
    expect(laneRunPassReading(exact())).toBe('passed')
    expect(laneRunPassReading(exact({ status: 'failed' }))).toBe('not_passed')
    expect(laneRunPassReading(task('approved'))).toBe('passed')
    expect(laneRunPassReading(task('rejected'))).toBe('not_passed')
    expect(laneRunPassReading(goal('committed'))).toBe('passed')
    expect(laneRunPassReading(goal('reviewed'))).toBe('not_passed')
    expect(laneRunPassReading(goal('running'))).toBe('running')
  })

  it('does not count a run whose completion was not persisted as passed, even when it intended success', () => {
    expect(laneRunPassReading(exact({ status: 'completion_persistence_failed', intendedStatus: 'succeeded' }))).toBe('not_passed')
  })
})

describe('laneRunCompletionGap', () => {
  it('names what the run ended as and why the record was not written', () => {
    expect(laneRunCompletionGap(exact({
      status: 'completion_persistence_failed', persistenceState: 'not_persisted', persistenceError: 'disk full',
      intendedStatus: 'failed', intendedCode: 'provider_error', intendedDetail: 'HTTP 500',
    }))).toEqual({
      persistenceState: 'not_persisted', persistenceError: 'disk full',
      intendedStatus: 'failed', intendedCode: 'provider_error', intendedDetail: 'HTTP 500',
    })
    expect(laneRunCompletionGap(exact({
      status: 'completion_durability_unknown', persistenceState: 'durability_unknown', persistenceError: 'fsync timed out',
      intendedStatus: 'succeeded',
    }))).toEqual({
      persistenceState: 'durability_unknown', persistenceError: 'fsync timed out',
      intendedStatus: 'succeeded', intendedCode: null, intendedDetail: null,
    })
  })

  it('has no gap for a persisted exact run or a verifier review', () => {
    expect(laneRunCompletionGap(exact())).toBeNull()
    expect(laneRunCompletionGap(task('commit_failed'))).toBeNull()
  })
})
