import { describe, expect, it } from 'vitest'
import { CirclePause } from 'lucide-preact'
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
    execution_truth: 'paused_dead',
    non_executable_cause: 'lifecycle_denied',
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
    expect(presentation.executionTruth).toBe('paused_dead')
    expect(presentation.nonExecutableCause).toBe('lifecycle_denied')
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

  // The server orders blocked_keepers by keeper identity and three consumers
  // take [0] to speak for the whole fleet, so a merely-waiting keeper could
  // sort ahead of one that needed repair and hide it.
  it('puts a keeper that needs repair ahead of one that is only waiting', () => {
    const waiting = fact({ keeper_name: 'aaa', action: 'wait_for_compaction' })
    const failing = fact({
      keeper_name: 'zzz',
      reason: 'meta_read_error',
      action: 'repair_keeper_meta_file',
    })

    const ordered = keeperFleetOperatorFacts({
      status: 'degraded',
      blocked_keepers: [waiting, failing],
    } as unknown as Parameters<typeof keeperFleetOperatorFacts>[0])

    expect(ordered[0]).toBe(failing)
    expect(ordered[1]).toBe(waiting)
  })

  it('keeps the server order between facts of equal severity', () => {
    const first = fact({ keeper_name: 'aaa', action: 'wait_for_compaction' })
    const second = fact({ keeper_name: 'bbb', action: 'wait_for_handoff' })

    const ordered = keeperFleetOperatorFacts({
      status: 'degraded',
      blocked_keepers: [first, second],
    } as unknown as Parameters<typeof keeperFleetOperatorFacts>[0])

    expect(ordered).toEqual([first, second])
  })

  it('does not mutate the fleet payload while ordering', () => {
    const waiting = fact({ keeper_name: 'aaa', action: 'wait_for_compaction' })
    const failing = fact({ keeper_name: 'zzz', action: 'repair_keeper_meta_file' })
    const blocked = [waiting, failing]

    keeperFleetOperatorFacts({
      status: 'degraded',
      blocked_keepers: blocked,
    } as unknown as Parameters<typeof keeperFleetOperatorFacts>[0])

    expect(blocked).toEqual([waiting, failing])
  })

  // no_keeper_binding rows collapse to agent_name, so without the task id two
  // unbound tasks of one agent render identically while the instruction says
  // to reassign "the task".
  it('carries the task identity the action refers to', () => {
    const presentation = keeperFleetOperatorFactPresentation(
      fact({
        keeper_name: null,
        agent_name: 'dreamer',
        task_id: 'task-7f3a',
        reason: 'no_keeper_binding',
        action: 'create_keeper_or_reassign_task',
      }),
      'degraded',
    )

    expect(presentation.keeper).toBe('dreamer')
    expect(presentation.taskId).toBe('task-7f3a')
  })

  it('reports absent task identity as null rather than a placeholder', () => {
    expect(keeperFleetOperatorFactPresentation(fact(), 'degraded').taskId).toBeNull()
  })
})
