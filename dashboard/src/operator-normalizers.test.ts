import { describe, it, expect } from 'vitest'
import {
  normalizeOperatorDigest,
  normalizeOperatorSnapshot as normalizeOperatorSnapshotWire,
} from './operator-normalizers'

const emptyPendingConfirmEnvelope = {
  items: [],
  summary: {
    actor_filter: null,
    filter_active: false,
    visible_count: 0,
    total_count: 0,
    hidden_count: 0,
    hidden_actors: [],
    confirm_required_actions: [],
  },
}

const validPendingConfirmation = {
  confirm_token: 'tok-1',
  trace_id: 'trace-1',
  actor: 'agent-1',
  action_type: 'keeper_probe',
  target_type: 'keeper',
  target_id: 'janitor',
  payload: {},
  delegated_tool: 'masc_keeper_status',
  created_at: '2026-08-08T00:00:00Z',
  expires_at: null,
}

function normalizeOperatorSnapshot(raw: Record<string, unknown>) {
  return normalizeOperatorSnapshotWire({
    pending_confirm_envelope: emptyPendingConfirmEnvelope,
    ...raw,
  })
}

// ================================================================
// normalizeOperatorDigest
// ================================================================

describe('normalizeOperatorDigest', () => {
  it('returns safe defaults for null', () => {
    const result = normalizeOperatorDigest(null)
    expect(result.trace_id).toBeUndefined()
    expect(result.target_type).toBe('root')
    expect(result.target_id).toBeNull()
    expect(result.health).toBeUndefined()
    expect(result.attention_items).toEqual([])
    expect(result.recommended_actions).toEqual([])
  })

  it('returns safe defaults for undefined', () => {
    const result = normalizeOperatorDigest(undefined)
    expect(result.target_type).toBe('root')
    expect(result.attention_items).toEqual([])
  })

  it('returns safe defaults for string input', () => {
    const result = normalizeOperatorDigest('invalid')
    expect(result.target_type).toBe('root')
    expect(result.attention_items).toEqual([])
  })

  it('extracts top-level fields', () => {
    const result = normalizeOperatorDigest({
      trace_id: 'trace-1',
      target_type: 'keeper',
      target_id: 'janitor',
      health: 'healthy',
      judgment_owner: 'operator',
    })
    expect(result.trace_id).toBe('trace-1')
    expect(result.target_type).toBe('keeper')
    expect(result.target_id).toBe('janitor')
    expect(result.health).toBe('healthy')
    expect(result.judgment_owner).toBe('operator')
  })

  it('defaults target_type to root', () => {
    const result = normalizeOperatorDigest({})
    expect(result.target_type).toBe('root')
  })

  it('extracts attention_items', () => {
    const result = normalizeOperatorDigest({
      attention_items: [
        { kind: 'error', summary: 'Keeper down', target_type: 'keeper' },
      ],
    })
    expect(result.attention_items).toHaveLength(1)
    expect(result.attention_items[0]!.kind).toBe('error')
  })

  it('filters invalid attention_items', () => {
    const result = normalizeOperatorDigest({
      attention_items: [
        { kind: 'error' }, // missing summary, target_type
      ],
    })
    expect(result.attention_items).toEqual([])
  })

  it('extracts recommended_actions', () => {
    const result = normalizeOperatorDigest({
      recommended_actions: [
        { action_type: 'pause', target_type: 'keeper', reason: 'High CPU' },
      ],
    })
    expect(result.recommended_actions).toHaveLength(1)
    expect(result.recommended_actions[0]!.action_type).toBe('pause')
  })

  it('extracts active_recommended_actions', () => {
    const result = normalizeOperatorDigest({
      active_recommended_actions: [
        { action_type: 'broadcast', target_type: 'workspace', reason: 'Alert' },
      ],
    })
    expect(result.active_recommended_actions).toHaveLength(1)
  })

  it('extracts root namespace', () => {
    const result = normalizeOperatorDigest({
      root: {
        project: 'masc',
        cluster: 'local',
        paused: true,
        pause_reason: 'maintenance',
      },
    })
    expect(result.root!.project).toBe('masc')
    expect(result.root!.cluster).toBe('local')
    expect(result.root!.paused).toBe(true)
    expect(result.root!.pause_reason).toBe('maintenance')
  })

  it('defaults root namespace to empty object', () => {
    const result = normalizeOperatorDigest({})
    expect(result.root).toEqual({})
  })

  it('extracts judgment', () => {
    const result = normalizeOperatorDigest({
      judgment: {
        surface: 'operator',
        status: 'complete',
        confidence: 0.85,
        model_name: 'gpt-4.1',
        runtime_name: 'openai',
      },
    })
    expect(result.judgment).not.toBeNull()
    expect(result.judgment!.surface).toBe('operator')
    expect(result.judgment!.confidence).toBe(0.85)
    expect(result.judgment!.model_name).toBeNull()
    expect(result.judgment!.runtime_name).toBe('runtime')
  })

  it('extracts active_guidance_layer and active_summary', () => {
    const result = normalizeOperatorDigest({
      active_guidance_layer: 'judge',
      active_summary: {
        summary: 'All healthy',
        confidence: 0.9,
        provenance: 'operator',
      },
    })
    expect(result.active_guidance_layer).toBe('judge')
    expect(result.active_summary).not.toBeNull()
    expect(result.active_summary!.summary).toBe('All healthy')
  })
})

// ================================================================
// normalizeOperatorSnapshot
// ================================================================

describe('normalizeOperatorSnapshot', () => {
  it('rejects null', () => {
    expect(() => normalizeOperatorSnapshotWire(null)).toThrow('invalid operator snapshot')
  })

  it('rejects undefined', () => {
    expect(() => normalizeOperatorSnapshotWire(undefined)).toThrow('invalid operator snapshot')
  })

  it('extracts root namespace', () => {
    const result = normalizeOperatorSnapshot({
      root: { project: 'masc', paused: false },
    })
    expect(result.root.project).toBe('masc')
    expect(result.root.paused).toBe(false)
  })

  it('extracts keepers with valid name', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        {
          name: 'janitor',
          status: 'Running',
          phase: 'paused',
          pipeline_stage: 'paused',
          paused: true,
          generation: 10,
          active_model: 'claude-sonnet',
        },
        { name: 'alice', status: 'Idle' },
      ],
    })
    expect(result.keepers).toHaveLength(2)
    expect(result.keepers[0]!.name).toBe('janitor')
    expect(result.keepers[0]!.phase).toBe('paused')
    expect(result.keepers[0]!.pipeline_stage).toBe('paused')
    expect(result.keepers[0]!.paused).toBe(true)
    expect(result.keepers[0]!.generation).toBe(10)
    expect(result.keepers[0]!.model).toBe('runtime')
  })

  it('preserves keeper runtime_trust terminal reason fields', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        {
          name: 'sangsu',
          status: 'paused',
          runtime_trust: {
            needs_attention: true,
            operator_disposition: 'pause_human',
            execution: {
              provider_selected_model: 'provider:runtime-lane',
            },
            latest_terminal_reason: {
              code: 'required_tool_use_unsatisfied',
              severity: 'bad',
              summary: 'required keeper tool use was not satisfied',
              next_action: 'inspect_provider_tool_contract',
            },
          },
        },
      ],
    })

    expect(result.keepers[0]?.runtime_trust).toMatchObject({
      needs_attention: true,
      operator_disposition: 'pause_human',
      execution_summary: {
        provider_selected_model: 'provider:runtime-lane',
      },
      latest_terminal_reason: {
        code: 'required_tool_use_unsatisfied',
        severity: 'bad',
      },
    })
  })

  it('does not revive context fields from retired nested payloads', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        {
          name: 'sojin',
          context: {
            source: 'keeper_context_status',
            context_ratio: 0.1274375,
            context_tokens: 16312,
            context_max: 128000,
          },
        },
      ],
    })
    expect(result.keepers).toHaveLength(1)
    expect(result.keepers[0]!.context_ratio).toBeNull()
    expect(result.keepers[0]!.context_tokens).toBeNull()
    expect(result.keepers[0]!.context_max).toBeNull()
    // The nested retired payload names no top-level source; the string stays
    // absent and no numbers are revived from it.
    expect(result.keepers[0]!.context_source).toBeNull()
  })

  it('decodes context numbers declared by the turn_record projection', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        {
          name: 'rondo',
          context_ratio: 0.504435,
          context_tokens: 100887,
          context_max: 200000,
          context_source: 'turn_record',
          context_metrics_unavailable: null,
        },
      ],
    })

    expect(result.keepers[0]).toMatchObject({
      context_ratio: 0.504435,
      context_tokens: 100887,
      context_max: 200000,
      context_source: 'turn_record',
    })
  })

  it('drops context fields entirely under a retired source', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        {
          name: 'sojin',
          context_ratio: 0.1274375,
          context_tokens: 16312,
          context_max: 128000,
          context_source: 'keeper_context_status',
        },
      ],
    })

    expect(result.keepers[0]).toMatchObject({
      context_ratio: null,
      context_tokens: null,
      context_max: null,
      context_source: null,
    })
  })

  it('preserves unknown context and separately typed last-turn usage', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        {
          name: 'rondo',
          context_ratio: null,
          context_tokens: null,
          context_max: null,
          context_source: null,
          context_metrics_unavailable: {
            kind: 'not_observed',
            reason: 'context_measurement_missing',
          },
          last_turn_usage: {
            input_tokens: 790360,
            output_tokens: 17,
            total_tokens: 790377,
            observed_at: '2026-07-29T14:15:00Z',
            source: 'keeper_runtime_usage',
          },
        },
      ],
    })

    expect(result.keepers[0]).toMatchObject({
      context_ratio: null,
      context_tokens: null,
      context_max: null,
      context_source: null,
      context_metrics_unavailable: {
        kind: 'not_observed',
        reason: 'context_measurement_missing',
      },
      last_turn_usage: {
        input_tokens: 790360,
        output_tokens: 17,
        total_tokens: 790377,
        source: 'keeper_runtime_usage',
      },
    })
  })

  it('rejects retired and unknown context diagnostics explicitly', () => {
    const result = normalizeOperatorSnapshot({
      persistent_agents: [
        {
          name: 'watcher',
          context_metrics_unavailable: {
            kind: 'malformed_json',
            reason: 'malformed_metrics_row',
            path: '/tmp/metrics.jsonl',
            line_number: 7,
            detail: 'unexpected end of input',
          },
        },
        {
          name: 'broken-wire-contract',
          context_metrics_unavailable: {
            kind: 'new_failure_kind',
            reason: 'new_reason',
          },
        },
      ],
    })

    expect(result.persistent_agents![0]!.context_metrics_unavailable).toEqual({
      kind: 'invalid_payload',
      reported_kind: 'malformed_json',
      reported_reason: 'malformed_metrics_row',
    })
    expect(result.persistent_agents![1]!.context_metrics_unavailable).toEqual({
      kind: 'invalid_payload',
      reported_kind: 'new_failure_kind',
      reported_reason: 'new_reason',
    })
  })

  it('filters keepers without name', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        { status: 'Running' }, // no name
      ],
    })
    expect(result.keepers).toEqual([])
  })

  it('preserves keeper runtime_trust and owner-specific stopped-reaction attention fields', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        {
          name: 'blocked-keeper',
          status: 'active',
          needs_attention: true,
          attention_reason: 'fiber_unresolved',
          next_human_action: 'inspect_runtime_blocker',
          runtime_trust: {
            disposition: 'Alert',
            operator_disposition: 'pause_runtime',
            operator_disposition_reason: 'fiber_unresolved',
            needs_attention: true,
            attention_reason: 'fiber_unresolved',
            latest_terminal_reason: {
              code: 'fiber_unresolved',
              source: 'execution_receipt',
              severity: 'bad',
              summary: 'Turn execution exceeded the keeper turn deadline',
              next_action: 'inspect_runtime_blocker',
            },
            latest_next_action: 'inspect_runtime_blocker',
          },
        },
      ],
    })
    expect(result.keepers).toHaveLength(1)
    const keeper = result.keepers[0]!
    expect(keeper.needs_attention).toBe(true)
    expect(keeper.next_human_action).toBe('inspect_runtime_blocker')
    expect(keeper.runtime_trust).toMatchObject({
      disposition: 'Alert',
      operator_disposition: 'pause_runtime',
      operator_disposition_reason: 'fiber_unresolved',
      needs_attention: true,
      latest_terminal_reason: {
        code: 'fiber_unresolved',
        severity: 'bad',
        summary: 'Turn execution exceeded the keeper turn deadline',
        next_action: 'inspect_runtime_blocker',
      },
      latest_next_action: 'inspect_runtime_blocker',
    })
  })

  it('returns null runtime_trust when runtime_trust is absent', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        { name: 'plain-keeper', status: 'active' },
      ],
    })
    expect(result.keepers[0]!.runtime_trust).toBeNull()
  })

  it('returns null needs_attention / attention_reason when absent', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        { name: 'quiet-keeper', status: 'active' },
      ],
    })
    expect(result.keepers[0]!.needs_attention).toBeNull()
    expect(result.keepers[0]!.attention_reason).toBeNull()
    expect(result.keepers[0]!.next_human_action).toBeNull()
  })

  it('drops terminal_reason in runtime_trust when code is missing', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        {
          name: 'incomplete-trust-keeper',
          runtime_trust: { latest_terminal_reason: { source: 'execution_receipt' } },
        },
      ],
    })
    expect(result.keepers[0]!.runtime_trust?.latest_terminal_reason).toBeNull()
  })

  it('extracts recent_messages', () => {
    const result = normalizeOperatorSnapshot({
      recent_messages: [
        { id: 'msg-1', content: 'Hello', from: 'agent-1' },
      ],
    })
    expect(result.recent_messages).toHaveLength(1)
    expect(result.recent_messages[0]!.id).toBe('msg-1')
  })

  it('keeps pending confirmations inside the envelope', () => {
    const result = normalizeOperatorSnapshot({
      pending_confirm_envelope: {
        items: [
          validPendingConfirmation,
        ],
        summary: {
          ...emptyPendingConfirmEnvelope.summary,
          visible_count: 1,
          total_count: 1,
        },
      },
    })
    expect(result.pending_confirm_envelope.items).toHaveLength(1)
    expect(result.pending_confirm_envelope.items[0]!.confirm_token).toBe('tok-1')
  })

  it('rejects a snapshot with an invalid envelope item', () => {
    expect(() => normalizeOperatorSnapshotWire({
      pending_confirm_envelope: {
        items: [
          { actor: 'agent-1' },
        ],
        summary: {
          ...emptyPendingConfirmEnvelope.summary,
          visible_count: 1,
          total_count: 1,
        },
      },
    })).toThrow('invalid pending_confirm_envelope')
  })

  it('rejects a snapshot without the canonical envelope', () => {
    expect(() => normalizeOperatorSnapshotWire({})).toThrow(
      'invalid pending_confirm_envelope',
    )
  })

  it('extracts available_actions', () => {
    const result = normalizeOperatorSnapshot({
      available_actions: [
        { action_type: 'keeper_probe', tool_name: 'masc_keeper_status', target_type: 'keeper', description: 'Immediate keeper diagnostic snapshot.', confirm_required: false },
      ],
    })
    expect(result.available_actions).toHaveLength(1)
    expect(result.available_actions[0]!.action_type).toBe('keeper_probe')
  })

  it('normalizes the exact Agent Core inference observation', () => {
    const result = normalizeOperatorSnapshot({
      inference_inflight: {
        boundary_owner: 'agent_core_runtime',
        active: 1,
      },
    })
    expect(result.inference_inflight).toEqual({
      boundary_owner: 'agent_core_runtime',
      active: 1,
    })
  })

  it.each([
    { boundary_owner: 'runtime', active: 1 },
    { boundary_owner: 'agent_core_runtime', active: -1 },
    { boundary_owner: 'agent_core_runtime', active: 1.5 },
    { boundary_owner: 'agent_core_runtime' },
  ])('rejects inference observations outside the exact boundary contract', (inferenceInflight) => {
    const result = normalizeOperatorSnapshot({ inference_inflight: inferenceInflight })

    expect(result.inference_inflight).toBeNull()
  })

  it('extracts persistent_agents using same keeper normalizer', () => {
    const result = normalizeOperatorSnapshot({
      persistent_agents: [
        { name: 'watcher', status: 'active' },
      ],
    })
    expect(result.persistent_agents).toHaveLength(1)
    expect(result.persistent_agents![0]!.name).toBe('watcher')
  })

  it('extracts pending_confirm_envelope', () => {
    const result = normalizeOperatorSnapshot({
      pending_confirm_envelope: {
        items: [
          { ...validPendingConfirmation, confirm_token: 'tok-e1' },
        ],
        summary: {
          ...emptyPendingConfirmEnvelope.summary,
          visible_count: 1,
          total_count: 5,
          hidden_count: 4,
        },
      },
    })
    expect(result.pending_confirm_envelope.items).toHaveLength(1)
    expect(result.pending_confirm_envelope.items[0]!.confirm_token).toBe('tok-e1')
  })

  it('extracts top-level needs_attention, attention_reason and next_human_action from keeper payload', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        {
          name: 'blocked-keeper',
          status: 'paused',
          needs_attention: true,
          attention_reason: 'provider_runtime_error',
          next_human_action: 'inspect_provider_runtime_cause',
        },
      ],
    })
    const k = result.keepers[0]
    expect(k?.needs_attention).toBe(true)
    expect(k?.attention_reason).toBe('provider_runtime_error')
    expect(k?.next_human_action).toBe('inspect_provider_runtime_cause')
  })

  it('defaults top-level attention fields to null when absent', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [{ name: 'quiet-keeper' }],
    })
    const k = result.keepers[0]
    expect(k?.needs_attention).toBeNull()
    expect(k?.attention_reason).toBeNull()
    expect(k?.next_human_action).toBeNull()
  })
})
