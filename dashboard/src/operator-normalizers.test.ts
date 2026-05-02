import { describe, it, expect } from 'vitest'
import { normalizeOperatorDigest, normalizeOperatorSnapshot } from './operator-normalizers'

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
    expect(result.recent_reviews).toEqual([])
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
        { action_type: 'broadcast', target_type: 'room', reason: 'Alert' },
      ],
    })
    expect(result.active_recommended_actions).toHaveLength(1)
  })

  it('extracts root namespace', () => {
    const result = normalizeOperatorDigest({
      root: {
        project: 'masc-mcp',
        cluster: 'local',
        paused: true,
        pause_reason: 'maintenance',
      },
    })
    expect(result.root!.project).toBe('masc-mcp')
    expect(result.root!.cluster).toBe('local')
    expect(result.root!.paused).toBe(true)
    expect(result.root!.pause_reason).toBe('maintenance')
  })

  it('defaults root namespace to empty object', () => {
    const result = normalizeOperatorDigest({})
    expect(result.root).toEqual({})
  })

  it('extracts operator_judge_runtime', () => {
    const result = normalizeOperatorDigest({
      operator_judge_runtime: {
        enabled: true,
        judge_online: true,
        refreshing: false,
        model_used: 'gpt-4',
      },
    })
    expect(result.operator_judge_runtime).not.toBeNull()
    expect(result.operator_judge_runtime!.enabled).toBe(true)
    expect(result.operator_judge_runtime!.model_used).toBe('gpt-4')
  })

  it('returns null operator_judge_runtime for invalid input', () => {
    const result = normalizeOperatorDigest({
      operator_judge_runtime: 'invalid',
    })
    expect(result.operator_judge_runtime).toBeNull()
  })

  it('extracts judgment', () => {
    const result = normalizeOperatorDigest({
      judgment: {
        surface: 'operator',
        status: 'complete',
        confidence: 0.85,
      },
    })
    expect(result.judgment).not.toBeNull()
    expect(result.judgment!.surface).toBe('operator')
    expect(result.judgment!.confidence).toBe(0.85)
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
  it('returns safe defaults for null', () => {
    const result = normalizeOperatorSnapshot(null)
    expect(result.root).toEqual({})
    expect(result.sessions).toEqual([])
    expect(result.keepers).toEqual([])
    expect(result.persistent_agents).toEqual([])
    expect(result.recent_messages).toEqual([])
    expect(result.pending_confirms).toEqual([])
    expect(result.available_actions).toEqual([])
  })

  it('returns safe defaults for undefined', () => {
    const result = normalizeOperatorSnapshot(undefined)
    expect(result.sessions).toEqual([])
    expect(result.keepers).toEqual([])
  })

  it('returns safe defaults for string input', () => {
    const result = normalizeOperatorSnapshot('invalid')
    expect(result.sessions).toEqual([])
  })

  it('extracts root namespace', () => {
    const result = normalizeOperatorSnapshot({
      root: { project: 'masc-mcp', paused: false },
    })
    expect(result.root.project).toBe('masc-mcp')
    expect(result.root.paused).toBe(false)
  })

  it('extracts sessions with valid session_id', () => {
    const result = normalizeOperatorSnapshot({
      sessions: [
        { session_id: 'sess-1', status: 'running' },
        { session_id: 'sess-2' },
      ],
    })
    expect(result.sessions).toHaveLength(2)
    expect(result.sessions[0]!.session_id).toBe('sess-1')
  })

  it('filters sessions without session_id', () => {
    const result = normalizeOperatorSnapshot({
      sessions: [
        { status: 'running' }, // no session_id
      ],
    })
    expect(result.sessions).toEqual([])
  })

  it('extracts sessions from nested structure', () => {
    const result = normalizeOperatorSnapshot({
      sessions: {
        sessions: [
          { session_id: 'nested-1' },
        ],
      },
    })
    expect(result.sessions).toHaveLength(1)
    expect(result.sessions[0]!.session_id).toBe('nested-1')
  })

  it('extracts keepers with valid name', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        { name: 'janitor', status: 'Running', generation: 10 },
        { name: 'dreamer', status: 'Idle' },
      ],
    })
    expect(result.keepers).toHaveLength(2)
    expect(result.keepers[0]!.name).toBe('janitor')
    expect(result.keepers[0]!.generation).toBe(10)
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
              tool_contract_result: 'violated',
              missing_required_tools: ['masc_board_post'],
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
        tool_contract_result: 'violated',
        missing_required_tools: ['masc_board_post'],
      },
      latest_terminal_reason: {
        code: 'required_tool_use_unsatisfied',
        severity: 'bad',
      },
    })
  })

  it('preserves keeper context fields from nested context payloads', () => {
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
    expect(result.keepers[0]!.context_ratio).toBe(0.1274375)
    expect(result.keepers[0]!.context_tokens).toBe(16312)
    expect(result.keepers[0]!.context_max).toBe(128000)
    expect(result.keepers[0]!.context_source).toBe('keeper_context_status')
  })

  it('filters keepers without name', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        { status: 'Running' }, // no name
      ],
    })
    expect(result.keepers).toEqual([])
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

  it('extracts pending_confirms with confirm_token', () => {
    const result = normalizeOperatorSnapshot({
      pending_confirms: [
        { confirm_token: 'tok-1', actor: 'agent-1', action_type: 'pause' },
      ],
    })
    expect(result.pending_confirms).toHaveLength(1)
    expect(result.pending_confirms[0]!.confirm_token).toBe('tok-1')
  })

  it('filters pending_confirms without token', () => {
    const result = normalizeOperatorSnapshot({
      pending_confirms: [
        { actor: 'agent-1' }, // no token
      ],
    })
    expect(result.pending_confirms).toEqual([])
  })

  it('extracts available_actions', () => {
    const result = normalizeOperatorSnapshot({
      available_actions: [
        { action_type: 'pause', target_type: 'keeper', description: 'Pause' },
      ],
    })
    expect(result.available_actions).toHaveLength(1)
    expect(result.available_actions[0]!.action_type).toBe('pause')
  })

  it('extracts operator_judge_runtime', () => {
    const result = normalizeOperatorSnapshot({
      operator_judge_runtime: {
        enabled: true,
        judge_online: false,
      },
    })
    expect(result.operator_judge_runtime).not.toBeNull()
    expect(result.operator_judge_runtime!.enabled).toBe(true)
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
          { confirm_token: 'tok-e1', actor: 'agent-1' },
        ],
        summary: {
          visible_count: 1,
          total_count: 5,
        },
      },
    })
    expect(result.pending_confirms).toHaveLength(1)
    expect(result.pending_confirms[0]!.confirm_token).toBe('tok-e1')
  })

  it('falls back to pending_confirms when no envelope', () => {
    const result = normalizeOperatorSnapshot({
      pending_confirms: [
        { confirm_token: 'tok-raw', actor: 'system' },
      ],
    })
    expect(result.pending_confirms).toHaveLength(1)
    expect(result.pending_confirms[0]!.confirm_token).toBe('tok-raw')
  })
})
