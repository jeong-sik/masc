import { describe, it, expect } from 'vitest'
import {
  normalizeOperatorActionDescriptor,
  normalizePendingConfirmation,
  normalizePendingConfirmSummary,
  normalizePendingConfirmEnvelope,
} from './pending-confirm'

const emptyPendingConfirmSummary = {
  actor_filter: null,
  filter_active: false,
  visible_count: 0,
  total_count: 0,
  hidden_count: 0,
  hidden_actors: [],
  confirm_required_actions: [],
}

const keeperProbeDescriptor = {
  action_type: 'keeper_probe',
  tool_name: 'masc_keeper_status',
  target_type: 'keeper',
  description: 'Immediate keeper diagnostic snapshot.',
  confirm_required: false,
}

// ================================================================
// normalizeOperatorActionDescriptor
// ================================================================

describe('normalizeOperatorActionDescriptor', () => {
  it('returns null for null', () => {
    expect(normalizeOperatorActionDescriptor(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(normalizeOperatorActionDescriptor(undefined)).toBeNull()
  })

  it('returns null for non-record input', () => {
    expect(normalizeOperatorActionDescriptor('invalid')).toBeNull()
  })

  it('returns null when action_type is missing', () => {
    expect(normalizeOperatorActionDescriptor({ target_type: 'keeper' })).toBeNull()
  })

  it('returns null when target_type is missing', () => {
    expect(normalizeOperatorActionDescriptor({ action_type: 'pause' })).toBeNull()
  })

  it('extracts the exact descriptor', () => {
    const result = normalizeOperatorActionDescriptor(keeperProbeDescriptor)
    expect(result).not.toBeNull()
    expect(result!.action_type).toBe('keeper_probe')
    expect(result!.tool_name).toBe('masc_keeper_status')
    expect(result!.target_type).toBe('keeper')
    expect(result!.description).toBe('Immediate keeper diagnostic snapshot.')
    expect(result!.confirm_required).toBe(false)
  })

  it('rejects missing and unknown fields', () => {
    const { tool_name: _toolName, ...missingTool } = keeperProbeDescriptor
    expect(normalizeOperatorActionDescriptor(missingTool)).toBeNull()
    expect(normalizeOperatorActionDescriptor({ ...keeperProbeDescriptor, extra: true })).toBeNull()
  })
})

// ================================================================
// normalizePendingConfirmation
// ================================================================

const validPendingConfirmation = {
  confirm_token: 'tok-1',
  trace_id: 'trace-1',
  actor: 'agent-1',
  action_type: 'keeper_probe',
  target_type: 'keeper',
  target_id: 'janitor',
  payload: {},
  delegated_tool: 'masc_keeper_status',
  created_at: '2026-04-17T12:00:00Z',
  expires_at: '2026-04-17T12:05:00Z',
}

describe('normalizePendingConfirmation', () => {
  it('returns null for null', () => {
    expect(normalizePendingConfirmation(null)).toBeNull()
  })

  it('returns null for non-record input', () => {
    expect(normalizePendingConfirmation(42)).toBeNull()
  })

  it('returns null when confirm_token is missing', () => {
    expect(normalizePendingConfirmation({ actor: 'agent-1' })).toBeNull()
  })

  it('extracts confirm_token', () => {
    const result = normalizePendingConfirmation(validPendingConfirmation)
    expect(result).not.toBeNull()
    expect(result!.confirm_token).toBe('tok-1')
  })

  it('extracts all fields', () => {
    const result = normalizePendingConfirmation({
      ...validPendingConfirmation,
    })
    expect(result!.actor).toBe('agent-1')
    expect(result!.action_type).toBe('keeper_probe')
    expect(result!.target_type).toBe('keeper')
    expect(result!.target_id).toBe('janitor')
    expect(result!.delegated_tool).toBe('masc_keeper_status')
    expect(result!.created_at).toBe('2026-04-17T12:00:00Z')
  })

  it('rejects an item with missing required fields', () => {
    const { target_id: _targetId, ...withoutTargetId } = validPendingConfirmation
    expect(normalizePendingConfirmation(withoutTargetId)).toBeNull()
  })

  it('rejects unknown fields and invalid timestamp ordering', () => {
    expect(normalizePendingConfirmation({ ...validPendingConfirmation, token: 'tok-1' })).toBeNull()
    expect(normalizePendingConfirmation({ ...validPendingConfirmation, created_at: 'not-time' })).toBeNull()
    expect(normalizePendingConfirmation({
      ...validPendingConfirmation,
      expires_at: validPendingConfirmation.created_at,
    })).toBeNull()
  })
})

// ================================================================
// normalizePendingConfirmSummary
// ================================================================

describe('normalizePendingConfirmSummary', () => {
  it('returns null for null', () => {
    expect(normalizePendingConfirmSummary(null)).toBeNull()
  })

  it('returns null for non-record', () => {
    expect(normalizePendingConfirmSummary('invalid')).toBeNull()
  })

  it('rejects an incomplete summary', () => {
    expect(normalizePendingConfirmSummary({})).toBeNull()
  })

  it('extracts all fields', () => {
    const result = normalizePendingConfirmSummary({
      actor_filter: 'agent-1',
      filter_active: true,
      visible_count: 5,
      total_count: 10,
      hidden_count: 5,
      hidden_actors: ['agent-2', 'agent-3'],
      confirm_required_actions: [
        keeperProbeDescriptor,
      ],
    })
    expect(result!.actor_filter).toBe('agent-1')
    expect(result!.filter_active).toBe(true)
    expect(result!.visible_count).toBe(5)
    expect(result!.total_count).toBe(10)
    expect(result!.hidden_count).toBe(5)
    expect(result!.hidden_actors).toEqual(['agent-2', 'agent-3'])
    expect(result!.confirm_required_actions).toHaveLength(1)
  })

  it('rejects invalid confirm_required_actions', () => {
    expect(normalizePendingConfirmSummary({
      ...emptyPendingConfirmSummary,
      confirm_required_actions: [
        { action_type: 'pause' },
      ],
    })).toBeNull()
  })

  it('rejects contradictory filter and count invariants', () => {
    expect(normalizePendingConfirmSummary({
      ...emptyPendingConfirmSummary,
      filter_active: true,
    })).toBeNull()
    expect(normalizePendingConfirmSummary({
      ...emptyPendingConfirmSummary,
      total_count: 1,
    })).toBeNull()
  })
})

// ================================================================
// normalizePendingConfirmEnvelope
// ================================================================

describe('normalizePendingConfirmEnvelope', () => {
  it('returns null for null', () => {
    expect(normalizePendingConfirmEnvelope(null)).toBeNull()
  })

  it('returns null for non-record', () => {
    expect(normalizePendingConfirmEnvelope([])).toBeNull()
  })

  it('returns null when no items and no summary', () => {
    expect(normalizePendingConfirmEnvelope({})).toBeNull()
  })

  it('extracts the complete envelope', () => {
    const result = normalizePendingConfirmEnvelope({
      items: [
        validPendingConfirmation,
        { ...validPendingConfirmation, confirm_token: 'tok-2' },
      ],
      summary: {
        actor_filter: null,
        filter_active: false,
        visible_count: 2,
        total_count: 2,
        hidden_count: 0,
        hidden_actors: [],
        confirm_required_actions: [],
      },
    })
    expect(result).not.toBeNull()
    expect(result!.items).toHaveLength(2)
    expect(result!.items[0]!.confirm_token).toBe('tok-1')
  })

  it('rejects a non-array items field', () => {
    expect(normalizePendingConfirmEnvelope({
      items: { confirms: [{ confirm_token: 'nested-1' }] },
      summary: {},
    })).toBeNull()
  })

  it('rejects the whole envelope when an item is invalid', () => {
    expect(normalizePendingConfirmEnvelope({
      items: [
        { confirm_token: 'tok-1' },
        { actor: 'agent-1' },
      ],
      summary: {
        actor_filter: null,
        filter_active: false,
        visible_count: 2,
        total_count: 2,
        hidden_count: 0,
        hidden_actors: [],
        confirm_required_actions: [],
      },
    })).toBeNull()
  })

  it('rejects duplicate tokens and visible-count drift', () => {
    expect(normalizePendingConfirmEnvelope({
      items: [validPendingConfirmation, validPendingConfirmation],
      summary: { ...emptyPendingConfirmSummary, visible_count: 2, total_count: 2 },
    })).toBeNull()
    expect(normalizePendingConfirmEnvelope({
      items: [validPendingConfirmation],
      summary: emptyPendingConfirmSummary,
    })).toBeNull()
  })

  it('rejects an envelope without a summary', () => {
    expect(normalizePendingConfirmEnvelope({
      items: [{ confirm_token: 'tok-1' }],
    })).toBeNull()
  })

  it('rejects an envelope without items', () => {
    expect(normalizePendingConfirmEnvelope({
      summary: {
        actor_filter: null,
        filter_active: false,
        visible_count: 0,
        total_count: 0,
        hidden_count: 0,
        hidden_actors: [],
        confirm_required_actions: [],
      },
    })).toBeNull()
  })
})
