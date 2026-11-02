import { describe, expect, it } from 'vitest'
import fixture from '../../../test/fixtures/skill-ledger-async-actions.json'
import { skillActivationFrameSha256, skillAsyncResultDeliverySha256 } from './dashboard-tools-prompts'
import { decodePhysicalSkillEvidence } from './keeper-physical-skill-evidence'

const turnRef = 'new-physical-trace#73'
function wire() {
  return {
    schema: 'masc.dashboard.skill-physical-turn/v1', turn_ref: turnRef,
    origins: [{ trace_id: fixture.session_id, ledger_revision: fixture.revision,
      activations: structuredClone(fixture.activations),
      async_result_deliveries: structuredClone(fixture.async_result_deliveries),
      async_actions: structuredClone(fixture.async_actions) }],
    coverage: { scope: 'complete_retained_trace_snapshot', sessions_inspected: 2, ledgers_loaded: 1,
      gaps: [] as Record<string, unknown>[] },
  }
}

describe('physical receiving-turn Skill evidence', () => {
  it('reads cross-trace handoffs with complete original frames and original ledger provenance', () => {
    const data = decodePhysicalSkillEvidence(wire(), turnRef)
    expect(data.turnRef).toBe(turnRef)
    expect(data.origins[0]).toMatchObject({ traceId: 'trace-one', ledgerRevision: fixture.revision })
    expect(data.origins[0]?.activations).toEqual(fixture.activations)
    expect(data.origins[0]?.async_result_deliveries).toHaveLength(2)
    expect(data.origins[0]?.async_actions).toHaveLength(3)
    expect(data.origins[0]?.activations[0]?.turn_ref).toBe('trace-one#41')
    const original = wire()
    original.turn_ref = 'trace-one#41'
    original.origins[0]!.async_result_deliveries = []
    original.origins[0]!.async_actions = []
    expect(decodePhysicalSkillEvidence(original, original.turn_ref).origins[0]?.activations).toEqual(fixture.activations)
  })

  it('refuses evidence for an adjacent turn, a different origin or an unrelated frame', () => {
    expect(() => decodePhysicalSkillEvidence(wire(), 'new-physical-trace#74')).toThrow()
    const wrongPhysical = wire()
    wrongPhysical.origins[0]!.async_result_deliveries[1]!.physical_turn_ref = 'new-physical-trace#74'
    expect(() => decodePhysicalSkillEvidence(wrongPhysical, turnRef)).toThrow()
    const wrongOrigin = wire()
    wrongOrigin.origins[0]!.trace_id = 'unrelated-origin'
    expect(() => decodePhysicalSkillEvidence(wrongOrigin, turnRef)).toThrow(/outside/)
    const unrelated = wire()
    unrelated.origins[0]!.async_result_deliveries = []
    unrelated.origins[0]!.async_actions = []
    expect(() => decodePhysicalSkillEvidence(unrelated, turnRef)).toThrow(/outside/)
  })

  it('validates child frames even for a reference handoff with no subsequent action', () => {
    const referenceOnly = wire()
    referenceOnly.origins[0]!.async_result_deliveries = [referenceOnly.origins[0]!.async_result_deliveries[1]!]
    referenceOnly.origins[0]!.async_actions = []
    expect(decodePhysicalSkillEvidence(referenceOnly, turnRef).origins[0]?.async_result_deliveries).toHaveLength(1)
    const missing = structuredClone(referenceOnly)
    missing.origins[0]!.activations = []
    expect(() => decodePhysicalSkillEvidence(missing, turnRef)).toThrow(/original admitted child/)
    const changed = structuredClone(referenceOnly)
    changed.origins[0]!.activations[0]!.content_revision = 'a'.repeat(64)
    expect(() => decodePhysicalSkillEvidence(changed, turnRef)).toThrow(/original frame differs/)
    const noDelivery = wire()
    noDelivery.origins[0]!.async_result_deliveries = []
    expect(() => decodePhysicalSkillEvidence(noDelivery, turnRef)).toThrow(/causal delivery/)
  })

  it('rejects duplicate origins and contradictory physical actions across original traces', () => {
    const repeated = wire()
    repeated.origins.push(structuredClone(repeated.origins[0]!))
    repeated.coverage.ledgers_loaded = 2
    expect(() => decodePhysicalSkillEvidence(repeated, turnRef)).toThrow(/origins are repeated/)

    const first = decodePhysicalSkillEvidence(wire(), turnRef).origins[0]!
    const second = structuredClone(first)
    second.traceId = 'trace-two'
    for (const frame of second.activations) frame.turn_ref = 'trace-two#41'
    const hashes = new Map<string, string>()
    for (const delivery of second.async_result_deliveries) {
      const previous = skillAsyncResultDeliverySha256(delivery)
      delivery.original_turn_ref = 'trace-two#41'
      for (const child of delivery.child_activations) {
        child.activation_sha256 = skillActivationFrameSha256(second.activations[0]!)
      }
      hashes.set(previous, skillAsyncResultDeliverySha256(delivery))
    }
    for (const action of second.async_actions) action.delivery_sha256 = hashes.get(action.delivery_sha256)!
    const secondWire = { trace_id: second.traceId, ledger_revision: second.ledgerRevision,
      activations: second.activations, async_result_deliveries: second.async_result_deliveries, async_actions: second.async_actions }
    const shared = { ...wire(), origins: [wire().origins[0]!, secondWire],
      coverage: { ...wire().coverage, ledgers_loaded: 2 } }
    expect(decodePhysicalSkillEvidence(shared, turnRef).origins).toHaveLength(2)
    secondWire.async_actions[0]!.tool_name = 'contradictory-tool'
    expect(() => decodePhysicalSkillEvidence(shared, turnRef)).toThrow(/physical occurrence differs/)
  })

  it('preserves positive observations and reports gaps instead of silently claiming complete coverage', () => {
    const partial = wire()
    partial.coverage.scope = 'incomplete_retained_trace_snapshot'
    partial.coverage.gaps = [{ code: 'ledger_unreadable', trace_id: 'damaged-trace', cause_code: 'decode_failed', detail: 'invalid log' }]
    const data = decodePhysicalSkillEvidence(partial, turnRef)
    expect(data.origins).toHaveLength(1)
    expect(data.coverage.gaps[0]?.trace_id).toBe('damaged-trace')
    const completeWithGap = structuredClone(partial)
    completeWithGap.coverage.scope = 'complete_retained_trace_snapshot'
    expect(() => decodePhysicalSkillEvidence(completeWithGap, turnRef)).toThrow(/coverage disagrees/)
    partial.coverage.gaps[0] = { code: 'invented-gap' }
    expect(() => decodePhysicalSkillEvidence(partial, turnRef)).toThrow(/invalid gap/)
    partial.coverage.gaps = []
    expect(() => decodePhysicalSkillEvidence(partial, turnRef)).toThrow(/coverage disagrees/)
  })

  it('distinguishes known empty retained coverage from an unavailable store', () => {
    const empty = wire()
    empty.origins = []
    expect(decodePhysicalSkillEvidence(empty, turnRef).coverage.scope).toBe('complete_retained_trace_snapshot')
    empty.coverage.scope = 'trace_store_unavailable'
    empty.coverage.gaps = [{ code: 'trace_root_unavailable', operation: 'stat_entry', path: '/traces', detail: 'not accessible' }]
    expect(decodePhysicalSkillEvidence(empty, turnRef).coverage.scope).toBe('trace_store_unavailable')
    empty.origins = wire().origins
    expect(() => decodePhysicalSkillEvidence(empty, turnRef)).toThrow(/coverage disagrees/)
  })
})
