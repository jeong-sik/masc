import { describe, it, expect } from 'vitest'
import { decodeGoalResumePhase, goalLifecycleActions } from './goal-lifecycle'

describe('Goal suspension contract', () => {
  it.each(['paused', 'blocked'])('requires the full %s lifecycle', phase => {
    for (const target of ['executing', 'verifying', 'awaiting_confirmation']) {
      expect(decodeGoalResumePhase(phase, target)).toBe(target)
    }
    for (const target of [undefined, null, 'completed', 'dropped', 'paused', 42]) {
      expect(() => decodeGoalResumePhase(phase, target)).toThrow('resume_phase')
    }
  })
  it('rejects targets on an unsuspended Goal', () => {
    expect(decodeGoalResumePhase('executing', undefined)).toBeNull()
    expect(() => decodeGoalResumePhase('completed', 'executing')).toThrow()
  })
  it('uses server availability and excludes verifier-only actions', () => {
    expect(goalLifecycleActions(['resume', 'block', 'drop', 'reopen', 'record_proof_proven'])).toEqual(['resume', 'block', 'drop', 'reopen'])
    expect(goalLifecycleActions([])).toEqual([])
  })
})
