import { describe, it, expect } from 'vitest'
import {
  normalizeOperatorActionDescriptor,
  normalizePendingConfirmation,
  normalizePendingConfirmSummary,
  normalizePendingConfirmEnvelope,
  selectPendingConfirmState,
} from './pending-confirm'

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

  it('extracts required fields', () => {
    const result = normalizeOperatorActionDescriptor({
      action_type: 'pause',
      target_type: 'keeper',
    })
    expect(result).not.toBeNull()
    expect(result!.action_type).toBe('pause')
    expect(result!.target_type).toBe('keeper')
  })

  it('extracts optional fields', () => {
    const result = normalizeOperatorActionDescriptor({
      action_type: 'broadcast',
      target_type: 'room',
      description: 'Alert all agents',
      confirm_required: true,
    })
    expect(result!.description).toBe('Alert all agents')
    expect(result!.confirm_required).toBe(true)
  })

  it('defaults optional fields when missing', () => {
    const result = normalizeOperatorActionDescriptor({
      action_type: 'pause',
      target_type: 'keeper',
    })
    expect(result!.description).toBeUndefined()
    expect(result!.confirm_required).toBeUndefined()
  })
})

// ================================================================
// normalizePendingConfirmation
// ================================================================

describe('normalizePendingConfirmation', () => {
  it('returns null for null', () => {
    expect(normalizePendingConfirmation(null)).toBeNull()
  })

  it('returns null for non-record input', () => {
    expect(normalizePendingConfirmation(42)).toBeNull()
  })

  it('returns null when no confirm_token or token', () => {
    expect(normalizePendingConfirmation({ actor: 'agent-1' })).toBeNull()
  })

  it('extracts confirm_token', () => {
    const result = normalizePendingConfirmation({
      confirm_token: 'tok-1',
    })
    expect(result).not.toBeNull()
    expect(result!.confirm_token).toBe('tok-1')
  })

  it('falls back to token field', () => {
    const result = normalizePendingConfirmation({
      token: 'tok-fallback',
    })
    expect(result!.confirm_token).toBe('tok-fallback')
  })

  it('prefers confirm_token over token', () => {
    const result = normalizePendingConfirmation({
      confirm_token: 'primary',
      token: 'secondary',
    })
    expect(result!.confirm_token).toBe('primary')
  })

  it('extracts all fields', () => {
    const result = normalizePendingConfirmation({
      confirm_token: 'tok-1',
      actor: 'agent-1',
      action_type: 'pause',
      target_type: 'keeper',
      target_id: 'janitor',
      delegated_tool: 'shell_exec',
      created_at: '2026-04-17T12:00:00Z',
      preview: { message: 'Hello' },
    })
    expect(result!.actor).toBe('agent-1')
    expect(result!.action_type).toBe('pause')
    expect(result!.target_type).toBe('keeper')
    expect(result!.target_id).toBe('janitor')
    expect(result!.delegated_tool).toBe('shell_exec')
    expect(result!.created_at).toBe('2026-04-17T12:00:00Z')
    expect(result!.preview).toEqual({ message: 'Hello' })
  })

  it('defaults target_id to null', () => {
    const result = normalizePendingConfirmation({
      confirm_token: 'tok-1',
    })
    expect(result!.target_id).toBeNull()
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

  it('returns defaults for empty record', () => {
    const result = normalizePendingConfirmSummary({})
    expect(result).not.toBeNull()
    expect(result!.actor_filter).toBeNull()
    expect(result!.filter_active).toBe(false)
    expect(result!.visible_count).toBe(0)
    expect(result!.total_count).toBe(0)
    expect(result!.hidden_count).toBe(0)
    expect(result!.hidden_actors).toEqual([])
    expect(result!.confirm_required_actions).toEqual([])
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
        { action_type: 'pause', target_type: 'keeper' },
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

  it('filters invalid confirm_required_actions', () => {
    const result = normalizePendingConfirmSummary({
      confirm_required_actions: [
        { action_type: 'pause' }, // missing target_type
      ],
    })
    expect(result!.confirm_required_actions).toEqual([])
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

  it('extracts items from array', () => {
    const result = normalizePendingConfirmEnvelope({
      items: [
        { confirm_token: 'tok-1' },
        { confirm_token: 'tok-2' },
      ],
    })
    expect(result).not.toBeNull()
    expect(result!.items).toHaveLength(2)
    expect(result!.items[0]!.confirm_token).toBe('tok-1')
  })

  it('extracts items from nested confirms', () => {
    const result = normalizePendingConfirmEnvelope({
      items: {
        confirms: [
          { confirm_token: 'nested-1' },
        ],
      },
    })
    expect(result!.items).toHaveLength(1)
    expect(result!.items[0]!.confirm_token).toBe('nested-1')
  })

  it('filters items without confirm_token', () => {
    const result = normalizePendingConfirmEnvelope({
      items: [
        { confirm_token: 'tok-1' },
        { actor: 'agent-1' }, // no token
      ],
    })
    expect(result!.items).toHaveLength(1)
  })

  it('extracts summary', () => {
    const result = normalizePendingConfirmEnvelope({
      items: [{ confirm_token: 'tok-1' }],
      summary: {
        visible_count: 1,
        total_count: 3,
      },
    })
    expect(result!.summary.visible_count).toBe(1)
    expect(result!.summary.total_count).toBe(3)
  })

  it('synthesizes summary when only items present', () => {
    const result = normalizePendingConfirmEnvelope({
      items: [
        { confirm_token: 'tok-1' },
        { confirm_token: 'tok-2' },
      ],
    })
    expect(result!.summary.visible_count).toBe(2)
    expect(result!.summary.total_count).toBe(2)
    expect(result!.summary.hidden_count).toBe(0)
    expect(result!.summary.confirm_required_actions).toEqual([])
  })

  it('returns envelope with summary but no items', () => {
    const result = normalizePendingConfirmEnvelope({
      summary: { visible_count: 0, total_count: 5 },
    })
    expect(result).not.toBeNull()
    expect(result!.items).toEqual([])
    expect(result!.summary.total_count).toBe(5)
  })
})

// ================================================================
// selectPendingConfirmState
// ================================================================

describe('selectPendingConfirmState', () => {
  it('returns defaults for null', () => {
    const result = selectPendingConfirmState(null)
    expect(result.items).toEqual([])
    expect(result.actor_filter).toBeNull()
    expect(result.visible_count).toBe(0)
    expect(result.total_count).toBe(0)
    expect(result.hidden_count).toBe(0)
    expect(result.hidden_actors).toEqual([])
    expect(result.confirm_required_actions).toEqual([])
  })

  it('returns defaults for undefined', () => {
    const result = selectPendingConfirmState(undefined)
    expect(result.items).toEqual([])
  })

  it('returns defaults for empty source', () => {
    const result = selectPendingConfirmState({})
    expect(result.items).toEqual([])
  })

  it('uses envelope items', () => {
    const result = selectPendingConfirmState({
      pending_confirm_envelope: {
        items: [{ confirm_token: 'tok-1', actor: 'a1', action_type: 'pause', target_type: 'keeper', target_id: null, delegated_tool: undefined, created_at: undefined, preview: undefined }],
        summary: {
          actor_filter: null,
          filter_active: false,
          visible_count: 1,
          total_count: 1,
          hidden_count: 0,
          hidden_actors: [],
          confirm_required_actions: [],
        },
      },
    })
    expect(result.items).toHaveLength(1)
    expect(result.items[0]!.confirm_token).toBe('tok-1')
  })

  it('falls back to pending_confirms when no envelope', () => {
    const result = selectPendingConfirmState({
      pending_confirms: [
        { confirm_token: 'tok-raw', actor: 'a1', action_type: 'pause', target_type: 'keeper', target_id: null, delegated_tool: undefined, created_at: undefined, preview: undefined },
      ],
    })
    expect(result.items).toHaveLength(1)
    expect(result.items[0]!.confirm_token).toBe('tok-raw')
  })

  it('uses available_actions for confirm_required_actions', () => {
    const result = selectPendingConfirmState({
      available_actions: [
        { action_type: 'pause', target_type: 'keeper', confirm_required: true },
        { action_type: 'broadcast', target_type: 'room', confirm_required: false },
      ],
    })
    expect(result.confirm_required_actions).toHaveLength(1)
    expect(result.confirm_required_actions[0]!.action_type).toBe('pause')
  })

  it('trims whitespace from actor_filter', () => {
    const result = selectPendingConfirmState({
      pending_confirm_summary: {
        actor_filter: '  agent-1  ',
        filter_active: false,
        visible_count: 1,
        total_count: 1,
        hidden_count: 0,
        hidden_actors: [],
        confirm_required_actions: [],
      },
    })
    expect(result.actor_filter).toBe('agent-1')
  })

  it('returns null actor_filter for empty string', () => {
    const result = selectPendingConfirmState({
      pending_confirm_summary: {
        actor_filter: '   ',
        filter_active: false,
        visible_count: 0,
        total_count: 0,
        hidden_count: 0,
        hidden_actors: [],
        confirm_required_actions: [],
      },
    })
    expect(result.actor_filter).toBeNull()
  })
})
