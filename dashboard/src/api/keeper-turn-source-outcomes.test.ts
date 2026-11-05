import { describe, expect, it } from 'vitest'
import { decodeTurnSourceOutcomes } from './keeper-turn-source-outcomes'

const selected = [{ stimulusId: 'stimulus-one', snapshotRef: 'a'.repeat(64),
  admittedRevision: '9007199254740993', sourceKind: 'keeper_delegate_completed', firstAdmittedAt: 100 }]
const receipt = { transition_id: 'transition-one', event_id: 'event-one', applied_at: 102,
  kind: 'ack_turn_completed' }
function observation() {
  return { schema: 'masc.keeper.turn-source-outcomes/v1', state: 'observed', observed_at: 110,
    coverage: { state: 'read', rows_inspected: 3, invalid_json_rows: 0,
      invalid_ledger_rows: 0, storage_error: false },
    sources: [{ stimulus_id: selected[0]!.stimulusId, source_snapshot_ref: selected[0]!.snapshotRef,
      admitted_revision: selected[0]!.admittedRevision, receipts: [receipt] }],
  }
}

describe('exact selected source outcomes', () => {
  it('retains the read clock and typed queue receipt without inferring business success', () => {
    const result = decodeTurnSourceOutcomes(observation(), selected)
    expect(result).toMatchObject({ state: 'observed', observedAt: 110,
      sources: [{ admittedRevision: '9007199254740993', receipts: [{ kind: 'ack_turn_completed' }] }] })
    for (const kind of ['cancelled', 'transferred', 'ack_fusion_terminal', 'ack_hitl_terminal']) {
      const raw = observation(); raw.sources[0]!.receipts[0] = { ...receipt, kind }
      expect(decodeTurnSourceOutcomes(raw, selected)).toMatchObject({
        state: 'observed', sources: [{ receipts: [{ kind }] }],
      })
    }
  })

  it('rejects another incarnation, snapshot, source or duplicate instead of joining by id alone', () => {
    for (const wrong of [{ admitted_revision: '9007199254740992' },
      { source_snapshot_ref: 'b'.repeat(64) }, { stimulus_id: 'other' }]) {
      const raw = observation(); Object.assign(raw.sources[0]!, wrong)
      expect(decodeTurnSourceOutcomes(raw, selected).state).toBe('unavailable')
    }
    const raw = observation(); raw.sources.push(raw.sources[0]!)
    expect(decodeTurnSourceOutcomes(raw, selected).state).toBe('unavailable')
    expect(decodeTurnSourceOutcomes(observation(), []).state).toBe('unavailable')
  })

  it('preserves independently observed positives through partial ledger reads', () => {
    const raw = observation()
    raw.coverage = { state: 'partial', rows_inspected: 3, invalid_json_rows: 1,
      invalid_ledger_rows: 1, storage_error: true }
    expect(decodeTurnSourceOutcomes(raw, selected)).toMatchObject({
      state: 'observed', coverage: { state: 'partial', storageError: true },
      sources: [{ receipts: [{ transitionId: 'transition-one' }] }],
    })
    raw.sources[0]!.receipts = []
    expect(decodeTurnSourceOutcomes(raw, selected)).toMatchObject({
      state: 'observed', coverage: { state: 'partial' }, sources: [{ receipts: [] }],
    })
  })

  it('keeps conflicting receipts rather than choosing one by timestamp', () => {
    const raw = observation()
    raw.sources[0]!.receipts.push({ ...receipt, transition_id: 'other-transition', applied_at: 999, kind: 'cancelled' })
    expect(decodeTurnSourceOutcomes(raw, selected)).toMatchObject({ state: 'observed', sources: [{
      receipts: [{ kind: 'ack_turn_completed' }, { kind: 'cancelled' }],
    }] })
  })

  it('rejects malformed receipts or contradictory coverage without inventing an empty result', () => {
    for (const bad of [null, {}, { ...receipt, kind: 'success' }, { ...receipt, applied_at: NaN }]) {
      const raw = observation(); Object.assign(raw.sources[0]!, { receipts: [bad] })
      expect(decodeTurnSourceOutcomes(raw, selected).state).toBe('unavailable')
    }
    const raw = observation(); raw.coverage.invalid_ledger_rows = 1
    expect(decodeTurnSourceOutcomes(raw, selected).state).toBe('unavailable')
    raw.coverage = { state: 'unavailable', rows_inspected: 0, invalid_json_rows: 0,
      invalid_ledger_rows: 0, storage_error: true }
    expect(decodeTurnSourceOutcomes(raw, selected).state).toBe('unavailable')
    raw.sources[0]!.receipts = []
    expect(decodeTurnSourceOutcomes(raw, selected)).toMatchObject({
      state: 'observed', coverage: { state: 'unavailable' }, sources: [{ receipts: [] }],
    })
  })

  it('does not turn missing historical fields or incomplete manifest reads into no-ACK evidence', () => {
    expect(decodeTurnSourceOutcomes(undefined, selected).state).toBe('unavailable')
    expect(decodeTurnSourceOutcomes({ schema: 'masc.keeper.turn-source-outcomes/v1', state: 'unavailable',
      reason: 'ambiguous_turn_start', observed_at: 100 }, selected).state).toBe('unavailable')
    expect(decodeTurnSourceOutcomes({ ...observation(), schema: 'unknown' }, selected).state).toBe('unavailable')
  })
})
