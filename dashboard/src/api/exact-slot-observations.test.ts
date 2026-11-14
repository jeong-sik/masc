import { describe, expect, it } from 'vitest'
import { parseSlotMatrix, parseSlotObservations } from './exact-slot-observations'
import { httpBinding, slotMatrix, slotObservation, slotState } from './fixtures/exact-slot-observations'

describe('passive exact-slot observations', () => {
  it('keeps predecessor refusal and successor acceptance with their original bindings and times', () => {
    const state = parseSlotMatrix(slotMatrix(), 0, 'board_attention_exact')
    expect(state.state).toBe('available')
    if (state.state !== 'available') throw new Error('fixture should decode')
    const [a, b, unknown, cli] = state.slots
    expect(a?.currentBinding?.endpoint).toBe('https://new.invalid/v1/responses')
    expect(a?.lastFailure?.observation.binding).toMatchObject({ kind: 'http',
      value: { endpoint: 'https://old.invalid/v1/responses' } })
    expect(a?.lastFailure?.observation.outcome).toEqual({ kind: 'execution_failed',
      cause: 'Provider_refused / Rate_limited', httpStatus: 429 })
    expect(a?.lastFailure?.observation.startedAt).toBe(10)
    expect(b?.lastSuccess?.observation.outcome.kind).toBe('accepted')
    expect(b?.lastSuccess?.observation.startedAt).toBe(12)
    expect(a?.undatedOutcomes[0]?.observation.finishedAt).toBeNull()
    expect(unknown?.lastObservation).toBeNull()
    expect(cli?.slotId).toBe(a?.slotId)
    expect(cli?.transport).toBe('official_client')
  })
  it('keeps missing metadata unknown and isolates unreadable metadata', () => {
    expect(parseSlotObservations(undefined)).toEqual({ state: 'unobserved' })
    expect(parseSlotMatrix(undefined, undefined, undefined)).toEqual({ state: 'unobserved' })
    expect(parseSlotObservations({ state: 'available', observations: [{}] }).state).toBe('unavailable')
    expect(parseSlotMatrix([slotState({ ordering_scope: 'run_started_at' })], 0, 'board_attention_exact').state).toBe('unavailable')
  })
  it('refuses dated success/failure with no measured return and mismatched slot provenance', () => {
    const undated = { run_id: 'run', observation: slotObservation({ started_at: null, finished_at: null }) }
    expect(parseSlotMatrix([slotState({ last_failure: undated })], 0, 'board_attention_exact').state).toBe('unavailable')
    const other = { run_id: 'run', observation: slotObservation({ slot_id: 'other' }) }
    expect(parseSlotMatrix([slotState({ last_observation: other })], 0, 'board_attention_exact').state).toBe('unavailable')
    const otherOwner = { run_id: 'run', observation: slotObservation({ lane_key: 'other-installation/grade' }) }
    expect(parseSlotMatrix([slotState({ last_observation: otherOwner })], 0, 'board_attention_exact').state).toBe('unavailable')
    expect(parseSlotMatrix([slotState()], 0, 'other-installation/grade').state).toBe('unavailable')
    expect(parseSlotMatrix([slotState(), slotState()], 0, 'board_attention_exact').state).toBe('unavailable')
  })
  it('never exposes credentials from an invalid endpoint through the decoder error', () => {
    const state = parseSlotObservations({ state: 'available', observations: [slotObservation({
      binding: ['Http', httpBinding('https://user:secret@host.invalid/path?token=secret#secret')],
    })] })
    expect(state.state).toBe('unavailable')
    expect(JSON.stringify(state)).not.toContain('secret')
  })
  it('decodes official-client causes without treating client invocation as a provider address', () => {
    const state = parseSlotObservations({ state: 'available', observations: [slotObservation({
      binding: ['Official_client'], outcome: ['Cli_failed', { runtime_id: 'A',
        cause: ['Native_failed', ['Codex']] }],
    })] })
    expect(state).toMatchObject({ state: 'available', observations: [{ binding: { kind: 'official_client' },
      outcome: { kind: 'cli_failed', cause: 'Native_failed / Codex' } }] })
  })
  it('decodes a connect that found no route as its own network failure', () => {
    const state = parseSlotObservations({ state: 'available', observations: [slotObservation({
      outcome: ['Execution_failed', ['Completion_failed', { sent: false,
        cause: ['Network_failure', ['Unreachable']] }]],
    })] })
    expect(state).toMatchObject({ state: 'available', observations: [{
      outcome: { kind: 'execution_failed', cause: 'Completion_failed / Network_failure / Unreachable' } }] })
  })
})
