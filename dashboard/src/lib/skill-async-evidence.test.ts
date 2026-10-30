import { describe, expect, it } from 'vitest'
import { sha256 } from '@noble/hashes/sha2.js'
import { bytesToHex } from '@noble/hashes/utils.js'
import fixture from '../../../test/fixtures/skill-ledger-async-actions.json'
import { decodeSkillActivationAsyncEvidence } from '../api/dashboard-tools-prompts'
import { projectSkillAsyncEvidence } from './skill-async-evidence'

function selected(deliveries: unknown[], actions: unknown[]) {
  return decodeSkillActivationAsyncEvidence(fixture.activations[0], {
    trace_id: fixture.session_id,
    async_result_deliveries: deliveries,
    async_actions: actions,
  })
}

function handoffDigest(delivery: typeof fixture.async_result_deliveries[number]): string {
  const { observed_at: _clock, ...identity } = delivery
  return bytesToHex(sha256(new TextEncoder().encode(JSON.stringify(identity))))
}

describe('retained async evidence display decisions', () => {
  it('keeps inline and reference handoffs, SDK outcomes and a native start distinct', () => {
    const evidence = selected(fixture.async_result_deliveries, fixture.async_actions)
    const view = projectSkillAsyncEvidence(evidence)
    expect(view.resultDeliveries.map(item => item.presentation)).toEqual(['inline_result', 'manifest_reference'])
    expect(view.actions.map(group => group.first.occurrence.kind)).toEqual(['sdk_result', 'sdk_result', 'native_started'])
    expect(view.actionLinkCount).toBe(3)
    expect(view.actions).toHaveLength(3)
    expect(view.actions[2]?.first.occurrence).toEqual(fixture.async_actions[2]?.occurrence)
  })

  it('shows one physical action while preserving two causally bound handoffs and clocks', () => {
    const extra = { ...fixture.async_result_deliveries[0]!, request_id: 'another-result', observed_at: '2026-10-15T12:00:00Z' }
    const link = { ...fixture.async_actions[0]!, delivery_sha256: handoffDigest(extra), observed_at: '2026-10-15T12:00:01Z' }
    const view = projectSkillAsyncEvidence(selected([...fixture.async_result_deliveries, extra], [...fixture.async_actions, link]))
    expect(view.actionLinkCount).toBe(4)
    expect(view.actions).toHaveLength(3)
    const group = view.actions[0]!
    expect([group.first, ...group.additionalLinks].map(action => [action.delivery_sha256, action.observed_at]))
      .toEqual([[fixture.async_actions[0]!.delivery_sha256, fixture.async_actions[0]!.observed_at], [link.delivery_sha256, link.observed_at]])
  })

  it('does not combine the same SDK call on another physical receiving turn', () => {
    const extra = { ...fixture.async_result_deliveries[0]!, physical_turn_ref: 'new-physical-trace#74' }
    const action = { ...fixture.async_actions[0]!, physical_turn_ref: extra.physical_turn_ref, delivery_sha256: handoffDigest(extra) }
    const view = projectSkillAsyncEvidence(selected([...fixture.async_result_deliveries, extra], [...fixture.async_actions, action]))
    expect(view.actions).toHaveLength(4)
    expect(view.actions.map(group => group.first.physical_turn_ref)).toEqual(['new-physical-trace#73', 'new-physical-trace#73', 'new-physical-trace#73', 'new-physical-trace#74'])
  })

  it('keeps an observed activation without async facts empty', () => {
    expect(projectSkillAsyncEvidence(selected([], []))).toEqual({ resultDeliveries: [], actionLinkCount: 0, actions: [] })
  })
})
