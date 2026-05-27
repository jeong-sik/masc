import { describe, expect, it } from 'vitest'

import { trustHasPendingFirstEvidence } from './trust-summary-evidence'

describe('trustHasPendingFirstEvidence', () => {
  it('returns false for nullish approval state', () => {
    expect(trustHasPendingFirstEvidence(null)).toBe(false)
    expect(trustHasPendingFirstEvidence(undefined)).toBe(false)
    expect(trustHasPendingFirstEvidence({})).toBe(false)
  })

  it('returns false when pending_first has only blank fields', () => {
    expect(
      trustHasPendingFirstEvidence({
        pending_first: { id: '', tool_name: '   ', task_id: null, blocker_class: undefined },
      }),
    ).toBe(false)
  })

  it('returns true when pending_first carries an approval id', () => {
    expect(
      trustHasPendingFirstEvidence({
        pending_first: {
          id: 'apr_123',
          tool_name: null,
          task_id: null,
          blocker_class: null,
        },
      }),
    ).toBe(true)
  })

  it('returns true when only blocker_class is set', () => {
    expect(
      trustHasPendingFirstEvidence({ pending_first: { blocker_class: 'sandbox' } }),
    ).toBe(true)
  })

  it('returns true when only tool_name is set', () => {
    expect(
      trustHasPendingFirstEvidence({ pending_first: { tool_name: 'Execute' } }),
    ).toBe(true)
  })

  it('returns true when only task_id is set', () => {
    expect(trustHasPendingFirstEvidence({ pending_first: { task_id: 'task-42' } })).toBe(true)
  })
})
