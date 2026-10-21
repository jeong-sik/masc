import { describe, expect, it } from 'vitest'
import { parseLaneAddonSnapshot } from './lane-addons'

const worker = {
  instance_id: 'worker-original', incarnation: 'incarnation-original', run_id: 'run-original',
  addon_id: 'quiz', title: 'Same package', revision: 'package-original', runtime_presence: 'live',
  configuration: { id: 'quiz', source_path: '/workspace/.masc/config/lane-addons/quiz.toml', revision: 'installed-original' },
  action_schema: null, phase: { kind: 'attached' }, observation_seq: 4, rows_count: 2,
  package: { outputs: {}, binding_schema: null, presentation: { description: null, readings: [] } },
}
function snapshot(host_requests: unknown) {
  return parseLaneAddonSnapshot({ configuration: null, rows: [], coverage: [], instances: [
    { ...worker, host_requests }, { ...worker, instance_id: 'worker-replacement', incarnation: 'incarnation-new', runtime_presence: 'retained' },
  ] })
}

describe('original worker host request observations', () => {
  it('retains every host-emitted wait reason with its original request ID', () => {
    // Lane_addon_exact.not_final_to_json plus Runtime's operator/source waits.
    const waiting = [
      { request_id: 'unconfigured', reason: { reason: 'lane_unconfigured' } },
      { request_id: 'off', reason: { reason: 'lane_off' } },
      { request_id: 'slots', reason: { reason: 'no_admitted_slots' } },
      { request_id: 'running', reason: { reason: 'attempt_in_progress' } },
      { request_id: 'registry', reason: { reason: 'lane_registry_unavailable', detail: 'registry replacing' } },
      { request_id: 'provider', reason: { reason: 'provider_unavailable', detail: 'quota window closed' } },
      { request_id: 'auth', reason: { reason: 'provider_auth_refused', detail: 'credentials rejected' } },
      { request_id: 'configuration', reason: { reason: 'provider_configuration_refused', detail: '' } },
      { request_id: 'operator', reason: { reason: 'awaiting_operator' } },
      { request_id: 'source', reason: { reason: 'source_unavailable', detail: 'input is not published' } },
    ]
    const cycle = { cycles: 3, waiting, issue: null }
    const [original, replacement] = snapshot(cycle).instances
    expect(original?.host_requests).toEqual({ kind: 'observed', cycle })
    expect(original?.incarnation).toBe('incarnation-original')
    expect(replacement?.host_requests).toBeUndefined()
  })
  it.each([
    { kind: 'listing_failed', detail: '' },
    { kind: 'listing_refused', detail: 'invalid worker request' },
    { kind: 'relisted_delivered_request', request_id: 'original-request' },
    { kind: 'result_delivery_failed', request_id: 'original-request', detail: 'worker disconnected' },
    { kind: 'exact_record_failed', request_id: 'original-request', detail: 'store unavailable' },
    { kind: 'ask_record_failed', request_id: 'original-question', detail: 'store unavailable' },
    { kind: 'no_exact_runner' },
  ])('retains the actual host cycle stop without converting it to a result: %j', issue => {
    const cycle = { cycles: 1, waiting: [], issue }
    expect(snapshot(cycle).instances[0]?.host_requests).toEqual({ kind: 'observed', cycle })
  })
  it.each([
    { cycles: -1, waiting: [], issue: null },
    { cycles: 1, waiting: [{ request_id: 'r', reason: { reason: 'future_reason' } }], issue: null },
    { cycles: 1, waiting: [{ request_id: 'r', reason: { reason: 'provider_unavailable' } }], issue: null },
    { cycles: 1, waiting: [{ request_id: 'r', reason: { reason: 'lane_off', detail: 'unexpected' } }], issue: null },
    { cycles: 1, waiting: [{ request_id: '', reason: { reason: 'awaiting_operator' } }], issue: null },
    { cycles: 1, waiting: [], issue: { kind: 'future_issue' } },
    { cycles: 1, waiting: [], issue: { kind: 'result_delivery_failed', detail: 'missing request' } },
    { cycles: 1, waiting: [], issue: null, applied: true },
    null,
  ])('keeps an unreadable cycle separate from worker and result facts: %j', invalid => {
    const received = snapshot(invalid)
    expect(received.instances[0]?.host_requests?.kind).toBe('unreadable')
    expect(received.instances[0]?.phase.kind).toBe('attached')
    expect(received.instances[0]?.observation_seq).toBe(4)
    expect(received.instances[0]?.configuration?.revision).toBe('installed-original')
    expect(received.instances[1]?.host_requests).toBeUndefined()
  })
  it('preserves zero cycles and absence as different observations', () => {
    const cycle = { cycles: 0, waiting: [], issue: null }
    const [original, retained] = snapshot(cycle).instances
    expect(original?.host_requests).toEqual({ kind: 'observed', cycle })
    expect(retained?.host_requests).toBeUndefined()
  })
})
