import { describe, expect, it } from 'vitest'
import { parseKeeperRuntimeTrace } from './keeper-runtime-trace'
import { decodeTraceSkillActivations, decodeTurnFlow, type TurnFlowTarget } from './keeper-turn-flow'

const target: TurnFlowTarget = { keeper: 'reviewer', traceId: 'trace-one', absoluteTurn: 7, turnRef: 'trace-one#7' }
const source = {
  stimulus_id: 'stimulus-one', source_kind: 'schedule_due',
  source_snapshot_ref: 'snapshot-one', admitted_revision: '9007199254740993', first_admitted_at: 100,
}
function trace(decision: unknown, extraRows: Record<string, unknown>[] = []) {
  return parseKeeperRuntimeTrace({
    keeper: target.keeper, trace_id: target.traceId, turn_id: target.absoluteTurn,
    manifest_rows: [{ keeper_name: target.keeper, trace_id: target.traceId,
      keeper_turn_id: target.absoluteTurn, event: 'turn_started', status: 'ok', decision }, ...extraRows],
  })
}

describe('exact turn intake', () => {
  it('keeps source order, exact revisions and source kinds without inferring dispatch', () => {
    const second = { ...source, stimulus_id: 'stimulus-two', source_kind: 'board_signal' }
    const flow = decodeTurnFlow(trace({ channel: 'scheduled_autonomous', intake_sources: [source, second] }), target)
    expect(flow.intake).toEqual({ state: 'observed', channel: 'scheduled_autonomous', sources: [
      { stimulusId: 'stimulus-one', sourceKind: 'schedule_due', snapshotRef: 'snapshot-one',
        admittedRevision: '9007199254740993', firstAdmittedAt: 100 },
      { stimulusId: 'stimulus-two', sourceKind: 'board_signal', snapshotRef: 'snapshot-one',
        admittedRevision: '9007199254740993', firstAdmittedAt: 100 },
    ] })
    expect(flow.events.map(event => event.event)).toEqual(['turn_started'])
  })

  it('distinguishes an observed empty intake from unavailable historical fields', () => {
    expect(decodeTurnFlow(trace({ intake_sources: [] }), target).intake).toEqual({
      state: 'observed', channel: null, sources: [],
    })
    expect(decodeTurnFlow(trace({}), target).intake.state).toBe('not_recorded')
    const historic = { ...source }; delete (historic as Partial<typeof source>).source_kind
    expect(decodeTurnFlow(trace({ intake_sources: [historic] }), target).intake).toMatchObject({
      state: 'observed', sources: [{ sourceKind: null }],
    })
  })

  it('rejects foreign trace, Keeper, physical turn and inconsistent turn references', () => {
    for (const mismatch of [{ keeper: 'other' }, { trace_id: 'other' }, { turn_id: 8 }]) {
      expect(() => decodeTurnFlow({ ...trace({}), ...mismatch }, target)).toThrow()
    }
    expect(() => decodeTurnFlow(trace({}), { ...target, turnRef: 'trace-one#8' })).toThrow()
    expect(() => decodeTurnFlow(trace({}, [{ keeper_name: 'other', trace_id: 'trace-one', keeper_turn_id: 7 }]), target)).toThrow()
  })

  it('does not attribute a repeated start to a single guessed attempt', () => {
    const row = trace({ intake_sources: [source] }).manifest_rows[0]!
    expect(decodeTurnFlow(trace({ intake_sources: [] }, [row]), target).intake).toEqual({ state: 'ambiguous', starts: 2 })
  })

  it('rejects malformed observations instead of presenting them as empty', () => {
    for (const invalid of [null, {}, [{ ...source, admitted_revision: 1 }], [{ ...source, first_admitted_at: 'now' }]]) {
      expect(() => decodeTurnFlow(trace({ intake_sources: invalid }), target)).toThrow()
    }
  })
})

function emptySkills() {
  const summary = Object.fromEntries([
    'instruction_invocations', 'skill_bodies_served', 'skill_resources_served',
    'instruction_provider_deliveries', 'instruction_official_client_handoffs', 'instruction_actions_observed',
    'composition_invocations', 'composition_provider_deliveries', 'composition_official_client_handoffs',
    'composition_actions_observed', 'invalid_transitions',
  ].map(key => [key, 0]))
  return {
    schema: 'masc.dashboard.skill-activations/v1', status: 'available', trace_id: target.traceId,
    summary, scoped_summaries: [], ledger: {
      schema: 'masc.skill-activations/v8', workspace_key: 'a'.repeat(64), session_id: target.traceId,
      revision: 'b'.repeat(64), activations: [], transition_rejections: [], async_result_deliveries: [], async_actions: [],
    },
  }
}

describe('trace Skill evidence', () => {
  it('uses the canonical decoder and keeps a known empty ledger distinct from missing evidence', () => {
    const known = decodeTraceSkillActivations(emptySkills(), target)
    expect(known.status).toBe('available')
    expect(decodeTraceSkillActivations({ schema: 'masc.dashboard.skill-activations/v1',
      status: 'not_recorded', trace_id: target.traceId }, target).status).toBe('not_recorded')
  })
  it('rejects mismatched source or ledger identity', () => {
    const raw = emptySkills()
    expect(() => decodeTraceSkillActivations({ ...raw, trace_id: 'other' }, target)).toThrow()
    expect(() => decodeTraceSkillActivations({ ...raw, ledger: { ...raw.ledger, session_id: 'other' } }, target)).toThrow()
    expect(() => decodeTraceSkillActivations({ ...raw, ledger: { ...raw.ledger, activations: [{}] } }, target)).toThrow()
  })
})
