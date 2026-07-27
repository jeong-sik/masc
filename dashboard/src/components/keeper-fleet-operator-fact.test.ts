import { describe, expect, it } from 'vitest'
import { CirclePause, ShieldAlert } from 'lucide-preact'
import type { DashboardBlockedKeeperFact } from '../types'
import {
  CURRENT_KEEPER_FLEET_FACT_INVALID,
  keeperFleetOperatorFactPresentation,
  keeperFleetOperatorFacts,
} from './keeper-fleet-operator-fact'

function fact(
  overrides: Partial<DashboardBlockedKeeperFact> = {},
): DashboardBlockedKeeperFact {
  return {
    keeper_name: 'sangsu',
    agent_name: null,
    task_id: null,
    task_status: null,
    reason: 'durable_paused_autoboot_enabled',
    action: 'resume_or_leave_paused',
    operator_action_type: null,
    operator_tool_name: null,
    operator_action_confirm_required: null,
    ...overrides,
  }
}

describe('keeper fleet operator fact presentation', () => {
  it('uses the same typed action for label, tone, icon, and operator instruction', () => {
    const presentation = keeperFleetOperatorFactPresentation(fact(), 'degraded')

    expect(presentation.label).toBe('Keeper paused')
    expect(presentation.tone).toBe('warn')
    expect(presentation.Icon).toBe(CirclePause)
    expect(presentation.action).toContain('resume selected paused keepers')
    expect(presentation.reason).toBe('durable_paused_autoboot_enabled')
    expect(presentation.detail).toBeNull()
  })

  it('keeps lifecycle action, icon, and exact durable detail on one presentation surface', () => {
    const presentation = keeperFleetOperatorFactPresentation(
      fact({
        reason: 'runtime_meta_authority',
        action: 'inspect_lifecycle_transaction',
        lifecycle_admission_reason:
          'runtime_meta_authority:keeper=sangsu,transaction=tx-current,stage=durable_committed',
      }),
      'blocked',
    )

    expect(presentation).toMatchObject({
      label: 'Keeper lifecycle transaction blocked',
      tone: 'bad',
      Icon: ShieldAlert,
      reason: 'runtime_meta_authority',
      detail:
        'runtime_meta_authority:keeper=sangsu,transaction=tx-current,stage=durable_committed',
    })
    expect(presentation.action).toContain('settle its current authority')
  })

  it('fails a missing current fleet fact closed', () => {
    const [invalid] = keeperFleetOperatorFacts(null)
    if (invalid == null) {
      throw new Error('missing current fleet fact did not fail closed')
    }
    const presentation = keeperFleetOperatorFactPresentation(invalid, null)

    expect(invalid).toEqual(CURRENT_KEEPER_FLEET_FACT_INVALID)
    expect(presentation).toMatchObject({
      label: 'Current Keeper fact invalid',
      tone: 'bad',
      reason: 'current_fact_invalid',
    })
    expect(presentation.action).toContain('canonical current snapshot')
  })

  it('raises every blocked fleet fact to bad without changing its action', () => {
    const presentation = keeperFleetOperatorFactPresentation(fact(), 'blocked')

    expect(presentation.tone).toBe('bad')
    expect(presentation.action).toContain('resume selected paused keepers')
  })
})
