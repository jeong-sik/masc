import { describe, expect, it } from 'vitest'
import { parseKeeperRuntimeTrace } from './keeper-runtime-trace'
import { decodeTraceSkillActivations, decodeTurnFlow, type TurnFlowTarget } from './keeper-turn-flow'

const target: TurnFlowTarget = { keeper: 'reviewer', traceId: 'trace-one', absoluteTurn: 7, turnRef: 'trace-one#7' }
const source = {
  stimulus_id: 'stimulus-one', source_kind: 'schedule_due',
  source_snapshot_ref: 'snapshot-one', admitted_revision: '9007199254740993', first_admitted_at: 100,
}
function trace(decision: unknown, extraRows: Record<string, unknown>[] = []) {
  const rows = [{ keeper_name: target.keeper, trace_id: target.traceId,
    keeper_turn_id: target.absoluteTurn, event: 'turn_started', status: 'ok', decision }, ...extraRows]
  return parseKeeperRuntimeTrace({
    keeper: target.keeper, trace_id: target.traceId, turn_id: target.absoluteTurn,
    manifest_total_rows: rows.length, manifest_total_rows_exact: true, manifest_returned_rows: rows.length,
    manifest_scan_diagnostics: {
      schema: 'keeper.runtime_manifest_scan_diagnostics.v1',
      unsupported_event_count: 0, unsupported_event_counts: [], unsupported_event_unattributed_count: 0,
      invalid_manifest_row_count: 0, invalid_json_row_count: 0, samples: [],
    },
    runtime_lens: { axes: { lifecycle: {
      turn_started_count: rows.filter(row => row.event === 'turn_started').length,
    } } },
    manifest_rows: rows,
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

  it('uses the scan-wide start count when a previous attempt has left the returned page', () => {
    const page = trace({ intake_sources: [source] })
    page.manifest_total_rows = 700
    page.runtime_lens.axes.lifecycle.turn_started_count = 2
    expect(page.manifest_rows.filter(row => row.event === 'turn_started')).toHaveLength(1)
    expect(decodeTurnFlow(page, target).intake).toEqual({ state: 'ambiguous', starts: 2 })
    page.manifest_total_rows_exact = false
    expect(decodeTurnFlow(page, target).intake).toEqual({ state: 'ambiguous', starts: 2 })
  })

  it('keeps partial or unreported scan coverage distinct from a unique observed start', () => {
    for (const complete of [false, null, undefined]) {
      const page = { ...trace({ intake_sources: [source] }), manifest_total_rows_exact: complete }
      expect(decodeTurnFlow(page, target).intake.state).toBe('unavailable')
    }
    const page = trace({ intake_sources: [source] })
    page.manifest_total_rows = 700
    // A bounded page is sufficient when the complete scan establishes exactly
    // one start and that start is present. Other event rows may be omitted.
    expect(decodeTurnFlow(page, target).intake.state).toBe('observed')
    page.manifest_rows = []
    expect(decodeTurnFlow(page, target).intake.state).toBe('unavailable')
  })

  it('does not hide unreadable rows behind an exact scan flag', () => {
    const page = trace({ intake_sources: [source] })
    if (page.manifest_scan_diagnostics.state !== 'available') throw new Error('fixture diagnostics unavailable')
    page.manifest_scan_diagnostics.invalid_json_row_count = 1
    expect(decodeTurnFlow(page, target).intake.state).toBe('unavailable')
  })

  it('preserves true, false and unknown manifest scan completeness at the API boundary', () => {
    expect(parseKeeperRuntimeTrace({ manifest_total_rows_exact: true }).manifest_total_rows_exact).toBe(true)
    expect(parseKeeperRuntimeTrace({ manifest_total_rows_exact: false }).manifest_total_rows_exact).toBe(false)
    expect(parseKeeperRuntimeTrace({}).manifest_total_rows_exact).toBeNull()
    expect(parseKeeperRuntimeTrace({ manifest_total_rows_exact: 'true' }).manifest_total_rows_exact).toBeNull()
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
