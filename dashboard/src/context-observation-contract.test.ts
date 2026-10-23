import { describe, expect, it } from 'vitest'
import { normalizeKeepers } from './keeper-store-normalize'
import { normalizeOperatorSnapshot } from './operator-normalizers'
import { contextObservationMessage } from './lib/context-observation'

const pending_confirm_envelope = {
  items: [],
  summary: {
    actor_filter: null, filter_active: false, visible_count: 0, total_count: 0,
    hidden_count: 0, hidden_actors: [], confirm_required_actions: [],
  },
}

// Current producer shapes: usage totals are evidence, never occupancy.
const observations = [
  { reason: 'conversation_cumulative_usage', usage_scope: 'conversation_cumulative', raw_input_tokens: 400000, context_window: 200000 },
  { reason: 'turn_total_usage', usage_scope: 'turn_total', raw_input_tokens: 600000, context_window: 200000 },
  { reason: 'usage_scope_unavailable', usage_scope: 'unavailable' },
  { reason: 'context_tokens_exceed_window', usage_scope: 'per_request', raw_input_tokens: 200001, context_window: 200000 },
]

describe('context observation wire consumers', () => {
  it.each(observations)('preserves $reason without inventing occupancy', observation => {
    const diagnostic = { kind: 'not_observed', ...observation }
    const row = {
      name: 'example-keeper',
      context_ratio: null, context_tokens: null, context_max: null, context_source: null,
      context_metrics_unavailable: diagnostic,
    }
    const keeper = normalizeKeepers([row])[0]!
    const snapshot = normalizeOperatorSnapshot({
      pending_confirm_envelope,
      keepers: { count: 1, items: [row] },
      persistent_agents: { count: 1, items: [row] },
    })
    const expected = {
      ...diagnostic,
      raw_input_tokens: 'raw_input_tokens' in observation ? observation.raw_input_tokens : null,
      context_window: 'context_window' in observation ? observation.context_window : null,
    }
    for (const decoded of [keeper, snapshot.keepers[0]!, snapshot.persistent_agents![0]!]) {
      expect(decoded.context_metrics_unavailable).toEqual(expected)
      expect(decoded.context_ratio).toBeNull()
      expect(decoded.context_tokens).toBeNull()
      expect(decoded.context_max).toBeNull()
      expect(contextObservationMessage(decoded.context_metrics_unavailable!).severity)
        .toBe(observation.reason === 'context_tokens_exceed_window' ? 'warning' : 'info')
    }
  })

  it.each([
    { reason: 'conversation_cumulative_usage', usage_scope: 'per_request' },
    { reason: 'usage_scope_unavailable' },
    { reason: 'context_tokens_exceed_window', usage_scope: 'per_request', context_window: 100 },
    { reason: 'context_tokens_exceed_window', usage_scope: 'per_request', raw_input_tokens: 99, context_window: 100 },
    { reason: 'context_tokens_exceed_window', usage_scope: 'per_request', raw_input_tokens: 100, context_window: 0 },
    { reason: 'turn_total_usage', usage_scope: 'turn_total', raw_input_tokens: -1 },
    { reason: 'turn_total_usage', usage_scope: 'turn_total', raw_input_tokens: 1.5 },
    { reason: 'turn_total_usage', usage_scope: 'turn_total', raw_input_tokens: '10' },
    { reason: 'turn_total_usage', usage_scope: 'turn_total', raw_input_tokens: Number.MAX_SAFE_INTEGER + 1 },
    { reason: 'future_reason', usage_scope: 'per_request' },
  ])('keeps malformed or unknown $reason explicit', observation => {
    const keeper = normalizeKeepers([{
      name: 'example-keeper', context_metrics_unavailable: { kind: 'not_observed', ...observation },
    }])[0]!
    expect(keeper.context_metrics_unavailable).toEqual({
      kind: 'invalid_payload', reported_kind: 'not_observed', reported_reason: observation.reason,
    })
    expect(contextObservationMessage(keeper.context_metrics_unavailable!).severity).toBe('error')
  })

  it('keeps store read failures actionable', () => {
    const keeper = normalizeKeepers([{
      name: 'example-keeper',
      context_metrics_unavailable: { kind: 'not_observed', reason: 'turn_record_read_failed' },
    }])[0]!
    expect(contextObservationMessage(keeper.context_metrics_unavailable!).severity).toBe('error')
  })

  it('does not let stale measurement fields override typed unavailability', () => {
    const row = {
      name: 'example-keeper', context_source: 'turn_record',
      context_ratio: 2, context_tokens: 400000, context_max: 200000,
      context: { source: 'turn_record', context_ratio: 2, context_tokens: 400000, context_max: 200000 },
      context_metrics_unavailable: {
        kind: 'not_observed', reason: 'conversation_cumulative_usage',
        usage_scope: 'conversation_cumulative', raw_input_tokens: 400000, context_window: 200000,
      },
    }
    const keeper = normalizeKeepers([row])[0]!
    const operator = normalizeOperatorSnapshot({ pending_confirm_envelope, keepers: { items: [row] } }).keepers[0]!
    for (const decoded of [keeper, operator]) {
      expect(decoded.context_ratio).toBeNull()
      expect(decoded.context_tokens).toBeNull()
      expect(decoded.context_source).toBeNull()
    }
    expect(keeper.context?.context_ratio).toBeNull()
  })
})
