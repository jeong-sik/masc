// Synthetic wire fixtures for the frozen historical binding/current route boundary.
export function slotObservation(overrides: Record<string, unknown> = {}) {
  return { slot_id: 'A', binding: ['Http', httpBinding('https://old.invalid/v1/responses')],
    call_id: 'call-A', flow_id: 'flow-1', visit_ordinal: 0, plan_fingerprint: 'a'.repeat(64),
    request_body_sha256: 'b'.repeat(64), catalog_generation: 'generation-1',
    catalog_evidence: 'c'.repeat(64), target_identity: 'd'.repeat(64),
    phase: ['Terminal'], generation_dispatched: true, started_at: 10, finished_at: 11,
    outcome: ['Execution_failed', ['Provider_refused', { http_status: 429, refusal: ['Rate_limited'] }]],
    ...overrides }
}
export function httpBinding(endpoint: string) {
  return { provider_id: 'provider-1', model_id: 'model-1', provider_kind: 'openai_compat', endpoint }
}
export function slotState(overrides: Record<string, unknown> = {}) {
  const retained = { run_id: 'original-run', observation: slotObservation() }
  return { slot_id: 'A', transport: 'http', declared: true,
    current_binding: httpBinding('https://new.invalid/v1/responses'), ordering_scope: 'dated_only',
    last_observation: retained, last_attempt: retained, last_success: null, last_failure: retained,
    undated_outcomes: [], ...overrides }
}
export function slotMatrix() {
  const accepted = { run_id: 'original-run', observation: slotObservation({ slot_id: 'B',
    binding: ['Http', httpBinding('https://second.invalid/v1/responses')], call_id: 'call-B',
    visit_ordinal: 1, started_at: 12, finished_at: 13, outcome: ['Accepted'] }) }
  const unclocked = { run_id: 'undated-run', observation: slotObservation({ binding: ['Http_unobserved'],
    started_at: null, finished_at: null, call_id: null, phase: ['Prepared'], generation_dispatched: false,
    outcome: ['Admission_rejected', ['Runtime_unavailable']] }) }
  return [slotState({ undated_outcomes: [unclocked] }),
    slotState({ slot_id: 'B', current_binding: httpBinding('https://second.invalid/v1/responses'),
      last_observation: accepted, last_attempt: accepted, last_success: accepted, last_failure: null }),
    slotState({ slot_id: 'C', current_binding: null, last_observation: null, last_attempt: null, last_failure: null }),
    slotState({ transport: 'official_client', current_binding: null,
      last_observation: null, last_attempt: null, last_failure: null })]
}
