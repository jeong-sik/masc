import { describe, expect, it } from 'vitest'

import { normalizePhaseDiagnosis } from './phase-conditions-panel'

describe('normalizePhaseDiagnosis', () => {
  it('normalizes and sorts backend phase diagnosis rows by priority', () => {
    const diagnosis = normalizePhaseDiagnosis({
      current_phase: 'Running',
      derived_phase: 'Failing',
      can_execute_turn: true,
      determining_condition: 'failing_unhealthy',
      rows: [
        {
          key: 'running_fiber_alive',
          label: 'Running: fiber alive',
          priority: 14,
          value: true,
          phase: 'Running',
          determining: false,
        },
        {
          key: 'failing_unhealthy',
          label: 'Failing: heartbeat or turn unhealthy',
          priority: 13,
          value: true,
          phase: 'Failing',
          determining: true,
        },
      ],
    })

    expect(diagnosis).not.toBeNull()
    expect(diagnosis!.currentPhase).toBe('Running')
    expect(diagnosis!.derivedPhase).toBe('Failing')
    expect(diagnosis!.canExecuteTurn).toBe(true)
    expect(diagnosis!.rows.map(row => row.key)).toEqual([
      'failing_unhealthy',
      'running_fiber_alive',
    ])
    expect(diagnosis!.rows[0]!.determining).toBe(true)
  })

  it('infers the determining row from determining_condition when row flag is absent', () => {
    const diagnosis = normalizePhaseDiagnosis({
      determining_condition: 'offline_fallback',
      rows: [
        {
          key: 'offline_fallback',
          label: 'Offline: fallback',
          priority: 15,
          value: true,
          phase: 'Offline',
        },
      ],
    })

    expect(diagnosis!.rows[0]!.determining).toBe(true)
  })

  it('returns null for missing optional backend field', () => {
    expect(normalizePhaseDiagnosis(undefined)).toBeNull()
    expect(normalizePhaseDiagnosis({ rows: [] })).toBeNull()
  })
})
