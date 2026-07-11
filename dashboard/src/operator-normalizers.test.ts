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
    expect(result.operator_judge_runtime!.model_used).toBeNull()
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
  it('returns safe defaults for null', () => {
    const result = normalizeOperatorSnapshot(null)
    expect(result.root).toEqual({})
    expect(result.sessions).toEqual([])
    expect(result.keepers).toEqual([])
    expect(result.persistent_agents).toEqual([])
    expect(result.admission_queue).toBeNull()
    expect(result.admission_queue_error).toBeNull()
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
      root: { project: 'masc', paused: false },
    })
    expect(result.root.project).toBe('masc')
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

  it('preserves keeper runtime_trust and owner-specific stopped-reaction attention fields', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        {
          name: 'blocked-keeper',
          status: 'active',
          needs_attention: true,
          attention_reason: 'turn_timeout',
          next_human_action: 'inspect_runtime_blocker',
          runtime_trust: {
            disposition: 'Alert',
            operator_disposition: 'pause_runtime',
            operator_disposition_reason: 'turn_timeout',
            needs_attention: true,
            attention_reason: 'turn_timeout',
            latest_terminal_reason: {
              code: 'turn_timeout',
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
    expect(keeper.attention_reason).toBe('turn_timeout')
    expect(keeper.next_human_action).toBe('inspect_runtime_blocker')
    expect(keeper.runtime_trust).toMatchObject({
      disposition: 'Alert',
      operator_disposition: 'pause_runtime',
      operator_disposition_reason: 'turn_timeout',
      needs_attention: true,
      latest_terminal_reason: {
        code: 'turn_timeout',
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

  it('normalizes admission queue ownership metadata', () => {
    const result = normalizeOperatorSnapshot({
      admission_queue: {
        throttle_owner: 'oas_runtime',
        max_concurrent: 3,
        active: 1,
        available: 2,
        queue_depth: 0,
      },
    })
    expect(result.admission_queue).toEqual({
      throttle_owner: 'oas_runtime',
      max_concurrent: 3,
      active: 1,
      available: 2,
      queue_depth: 0,
    })
    expect(result.admission_queue_error).toBeNull()
  })

  it('rejects incomplete admission queue snapshots instead of fabricating zero capacity', () => {
    const result = normalizeOperatorSnapshot({
      admission_queue: {
        throttle_owner: 'oas_runtime',
        max_concurrent: 3,
      },
    })

    expect(result.admission_queue).toBeNull()
    expect(result.admission_queue_error).toBe('Admission projection contains invalid counters.')
  })

  it.each([
    [{ throttle_owner: '', max_concurrent: 3, active: 1, available: 2, queue_depth: 0 }, 'Admission projection is missing throttle ownership.'],
    [{ throttle_owner: 'runtime', max_concurrent: 3, active: 4, available: 0, queue_depth: 0 }, 'Admission projection counters are inconsistent.'],
    [{ throttle_owner: 'runtime', max_concurrent: 3, active: 1, available: 1, queue_depth: 0 }, 'Admission projection counters are inconsistent.'],
  ])('reports an invalid admission projection instead of silently omitting it', (admissionQueue, error) => {
    const result = normalizeOperatorSnapshot({ admission_queue: admissionQueue })

    expect(result.admission_queue).toBeNull()
    expect(result.admission_queue_error).toBe(error)
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

  it('extracts top-level needs_attention, attention_reason and next_human_action from keeper payload', () => {
    const result = normalizeOperatorSnapshot({
      keepers: [
        {
          name: 'blocked-keeper',
          status: 'paused',
          needs_attention: true,
          attention_reason: 'tool_route_recoverable_failure',
          next_human_action: 'inspect_provider_tool_contract',
        },
      ],
    })
    const k = result.keepers[0]
    expect(k?.needs_attention).toBe(true)
    expect(k?.attention_reason).toBe('tool_route_recoverable_failure')
    expect(k?.next_human_action).toBe('inspect_provider_tool_contract')
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
