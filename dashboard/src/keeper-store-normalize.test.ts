import { describe, expect, it } from 'vitest'
import { deriveLifecycleState, normalizeKeepers, normalizeKeeperTrustTerminalReason, toKeeperPhase } from './keeper-store-normalize'

describe('toKeeperPhase — backend lowercase to PascalCase normalization', () => {
  it('maps lowercase backend phase strings to PascalCase KeeperPhase', () => {
    expect(toKeeperPhase('offline')).toBe('Offline')
    expect(toKeeperPhase('running')).toBe('Running')
    expect(toKeeperPhase('failing')).toBe('Failing')
    expect(toKeeperPhase('overflowed')).toBe('Overflowed')
    expect(toKeeperPhase('compacting')).toBe('Compacting')
    expect(toKeeperPhase('handing_off')).toBe('HandingOff')
    expect(toKeeperPhase('draining')).toBe('Draining')
    expect(toKeeperPhase('paused')).toBe('Paused')
    expect(toKeeperPhase('stopped')).toBe('Stopped')
    expect(toKeeperPhase('crashed')).toBe('Crashed')
    expect(toKeeperPhase('restarting')).toBe('Restarting')
    expect(toKeeperPhase('dead')).toBe('Dead')
  })

  it('accepts PascalCase input for forward compatibility', () => {
    expect(toKeeperPhase('Offline')).toBe('Offline')
    expect(toKeeperPhase('Running')).toBe('Running')
    expect(toKeeperPhase('Overflowed')).toBe('Overflowed')
    expect(toKeeperPhase('HandingOff')).toBe('HandingOff')
  })

  it('trims surrounding whitespace before matching', () => {
    expect(toKeeperPhase(' running ')).toBe('Running')
    expect(toKeeperPhase(' HandingOff ')).toBe('HandingOff')
  })

  it('returns null for unknown or empty values', () => {
    expect(toKeeperPhase(null)).toBeNull()
    expect(toKeeperPhase(undefined)).toBeNull()
    expect(toKeeperPhase('')).toBeNull()
    expect(toKeeperPhase('unknown_phase')).toBeNull()
    expect(toKeeperPhase('RUNNING')).toBeNull()
  })
})

describe('normalizeKeepers phase field', () => {
  it('normalizes lowercase backend phase to PascalCase KeeperPhase', () => {
    const [keeper] = normalizeKeepers([
      { name: 'phase-test', status: 'active', phase: 'running' },
    ])
    expect(keeper?.phase).toBe('Running')
    expect(keeper?.lifecycle_phase).toBe('Running')
  })

  it('preserves explicit lifecycle phase and pipeline stage detail', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'offline-detail-test',
        status: 'offline',
        phase: 'running',
        lifecycle_phase: 'Offline',
        pipeline_stage: 'offline',
        pipeline_stage_detail: 'launch_pending_no_fiber',
      },
    ])
    expect(keeper?.phase).toBe('Running')
    expect(keeper?.lifecycle_phase).toBe('Offline')
    expect(keeper?.pipeline_stage).toBe('offline')
    expect(keeper?.pipeline_stage_detail).toBe('launch_pending_no_fiber')
  })

  it('normalizes handing_off to HandingOff', () => {
    const [keeper] = normalizeKeepers([
      { name: 'handoff-test', status: 'active', phase: 'handing_off' },
    ])
    expect(keeper?.phase).toBe('HandingOff')
  })

  it('normalizes overflowed to Overflowed', () => {
    const [keeper] = normalizeKeepers([
      { name: 'overflow-test', status: 'active', phase: 'overflowed' },
    ])
    expect(keeper?.phase).toBe('Overflowed')
  })

  it('returns null for unknown phase', () => {
    const [keeper] = normalizeKeepers([
      { name: 'unknown-test', status: 'active', phase: 'bogus' },
    ])
    expect(keeper?.phase).toBeNull()
  })

  it('returns null when phase is absent', () => {
    const [keeper] = normalizeKeepers([
      { name: 'no-phase', status: 'active' },
    ])
    expect(keeper?.phase).toBeNull()
  })

  it('trims keeper status before normalization', () => {
    const [keeper] = normalizeKeepers([
      { name: 'trimmed-status', status: ' active ', phase: ' running ' },
    ])
    expect(keeper?.status).toBe('active')
    expect(keeper?.phase).toBe('Running')
  })
})

describe('normalizeKeepers lifecycle metrics', () => {
  it('preserves keeper compaction gates from the backend surface', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'sangsu',
        status: 'active',
        compaction_profile: 'balanced',
        compaction_ratio_gate: 0.72,
        compaction_message_gate: 120,
        compaction_token_gate: 240000,
      },
    ])

    expect(keeper?.compaction_profile).toBe('balanced')
    expect(keeper?.compaction_ratio_gate).toBe(0.72)
    expect(keeper?.compaction_message_gate).toBe(120)
    expect(keeper?.compaction_token_gate).toBe(240000)
  })

  it('normalizes live activity projection and current approval gate', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'sangsu',
        status: 'active',
        last_activity_at: '2026-06-06T02:49:01Z',
        last_activity_source: 'approval_pending',
        live_activity: {
          source: 'approval_pending',
          at: '2026-06-06T02:49:01Z',
          age_s: 5,
          tool: 'Write',
        },
        current_gate: {
          kind: 'approval_required',
          source: 'audit_approvals',
          tool: 'Write',
          turn_id: 178,
          at: '2026-06-06T02:49:01Z',
        },
      },
    ])

    expect(keeper?.last_activity_source).toBe('approval_pending')
    expect(keeper?.last_activity_at).toBe('2026-06-06T02:49:01Z')
    expect(keeper?.live_activity).toMatchObject({
      source: 'approval_pending',
      tool: 'Write',
      age_s: 5,
    })
    expect(keeper?.current_gate).toMatchObject({
      kind: 'approval_required',
      source: 'audit_approvals',
      tool: 'Write',
      turn_id: 178,
    })
  })

  it('accepts flat backend handoff fields', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'alpha',
        status: 'active',
        metrics_series: [
          {
            ts_unix: 1,
            context_ratio: 0.92,
            context_tokens: 920,
            context_max: 1000,
            latency_ms: 120,
            generation: 3,
            channel: 'turn',
            model_used: 'glm-5',
            cost_usd: 0.12,
            compacted: false,
            handoff_performed: true,
            handoff_to_model: 'glm-5',
            handoff_new_generation: 4,
          },
        ],
      },
    ])

    expect(keeper?.metrics_series).toHaveLength(1)
    const metric = keeper!.metrics_series![0]
    expect(metric).toMatchObject({
      is_handoff: true,
      is_compaction: false,
      handoff_to_model: null,
      handoff_new_generation: 4,
    })
    expect(deriveLifecycleState(keeper!)).toBe('handoff-imminent')
  })

  it('accepts nested handoff objects with to_generation fallback', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'beta',
        status: 'active',
        metrics_series: [
          {
            ts_unix: 2,
            context_ratio: 0.88,
            context_tokens: 880,
            context_max: 1000,
            latency_ms: 140,
            generation: 5,
            channel: 'turn',
            model_used: 'llama:test-balanced',
            cost_usd: 0.2,
            compacted: false,
            handoff: {
              performed: true,
              to_model: 'llama:test-balanced',
              to_generation: 6,
            },
          },
        ],
      },
    ])

    expect(keeper?.metrics_series).toHaveLength(1)
    const metric = keeper!.metrics_series![0]
    expect(metric).toMatchObject({
      is_handoff: true,
      handoff_to_model: null,
      handoff_new_generation: 6,
    })
    expect(deriveLifecycleState(keeper!)).toBe('handoff-imminent')
  })

  it('marks compaction events as compacting', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'gamma',
        status: 'active',
        metrics_series: [
          {
            ts_unix: 3,
            context_ratio: 0.61,
            context_tokens: 610,
            context_max: 1000,
            latency_ms: 90,
            generation: 1,
            channel: 'turn',
            model_used: 'llama:auto',
            cost_usd: 0.01,
            compacted: true,
            compaction_saved_tokens: 240,
            compaction_trigger: 'ratio(0.9100>=0.8500)',
          },
        ],
      },
    ])

    expect(keeper?.metrics_series).toHaveLength(1)
    const metric = keeper!.metrics_series![0]
    expect(metric).toMatchObject({
      is_handoff: false,
      is_compaction: true,
      compaction_saved_tokens: 240,
      compaction_trigger: 'ratio(0.9100>=0.8500)',
    })
    expect(deriveLifecycleState(keeper!)).toBe('compacting')
  })

  it('keeps runtime tool audit fields out of shell rows', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'delta',
        status: 'active',
        latest_tool_names: ['observed_tool'],
        latest_tool_call_count: 2,
        tool_audit_source: 'heartbeat_result',
        tool_audit_at: '2026-04-02T08:30:00Z',
        context_source: 'metrics_log',
        recent_input_preview: 'operator asked for a refresh',
        recent_output_preview: 'keeper acknowledged the request',
      },
    ])

    expect(keeper).toMatchObject({
      latest_tool_names: ['observed_tool'],
      latest_tool_call_count: 2,
      tool_audit_source: 'heartbeat_result',
      tool_audit_at: '2026-04-02T08:30:00Z',
      context_source: 'metrics_log',
      recent_input_preview: 'operator asked for a refresh',
      recent_output_preview: 'keeper acknowledged the request',
    })
  })

  it('normalizes prompt telemetry dynamically from keeper metric points', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'prompt-keeper',
        status: 'active',
        metrics_series: [
          {
            ts_unix: 4,
            context_ratio: 0.42,
            context_tokens: 420,
            context_max: 1000,
            latency_ms: 110,
            generation: 2,
            channel: 'turn',
            model_used: 'glm-5',
            cost_usd: 0.03,
            compacted: false,
            prompt_fingerprint: 'prompt-fp-001',
            prompt: {
              fingerprint: 'prompt-fp-001',
              total_bytes: 830,
              cacheable_bytes: 512,
              system_prompt: { bytes: 512, fingerprint: 'seg-system' },
              dynamic_context: { bytes: 220, fingerprint: 'seg-dynamic' },
              user_message: { bytes: 98, fingerprint: 'seg-user' },
            },
          },
        ],
      },
    ])

    expect(keeper?.metrics_series).toHaveLength(1)
    const metric = keeper?.metrics_series?.[0]
    expect(metric).toBeDefined()
    if (!metric) throw new Error('metric missing')
    expect(metric.prompt_fingerprint).toBe('prompt-fp-001')
    expect(metric.prompt_metrics).toEqual({
      fingerprint: 'prompt-fp-001',
      total_bytes: 830,
      cacheable_bytes: 512,
      segments: {
        system_prompt: { bytes: 512, fingerprint: 'seg-system' },
        dynamic_context: { bytes: 220, fingerprint: 'seg-dynamic' },
        user_message: { bytes: 98, fingerprint: 'seg-user' },
      },
    })
  })

  it('preserves trust summary and latest causal event fields', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'trust-keeper',
        status: 'active',
        trust: {
          disposition: 'Blocked',
          disposition_reason: 'approval_waiting',
          needs_attention: true,
          attention_reason: 'approval_pending',
          next_human_action: 'resolve_approval',
          approval_state: {
            state: 'pending',
            summary: '1 approval request waiting',
            pending_count: 1,
            latest_event_at: '2026-04-23T00:09:30Z',
          },
          execution_summary: {
            sandbox_summary: 'docker / none',
            completion_observation_summary: 'not_observed',
            latest_receipt_at: '2026-04-23T00:10:00Z',
          },
          latest_causal_event: {
            kind: 'approval_pending',
            ts: '2026-04-23T00:11:00Z',
            ts_unix: 1776903060,
            keeper_turn_id: 42,
            task_id: 'task-1',
            title: 'Approval pending',
            summary: 'Waiting for operator approval before resuming.',
            severity: 'warn',
            next_human_action: 'resolve_approval',
            trace_id: 'trace-approval-42',
          },
        },
      },
    ])

    expect(keeper?.trust).toMatchObject({
      disposition: 'Blocked',
      disposition_reason: 'approval_waiting',
      needs_attention: true,
      attention_reason: 'approval_pending',
      next_human_action: 'resolve_approval',
      approval_state: {
        state: 'pending',
        summary: '1 approval request waiting',
        pending_count: 1,
        latest_event_at: '2026-04-23T00:09:30Z',
      },
      execution_summary: {
        sandbox_summary: 'docker / none',
        completion_observation_summary: 'not_observed',
      },
      latest_causal_event: {
        kind: 'approval_pending',
        keeper_turn_id: 42,
        title: 'Approval pending',
        summary: 'Waiting for operator approval before resuming.',
        trace_id: 'trace-approval-42',
      },
    })
  })

  it('preserves owner-specific stopped-reaction fields in trust summary', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'blocked-keeper',
        status: 'active',
        trust: {
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
    ])

    expect(keeper?.trust).toMatchObject({
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
    })
    expect(keeper?.stop_cause).toMatchObject({
      code: 'turn_timeout',
      source: 'terminal_reason_code',
      summary: 'Turn execution exceeded the keeper turn deadline',
      next_action: 'inspect_runtime_blocker',
    })
  })

  it('prefers runtime blocker as the normalized stop cause for keeper detail', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'blocked-keeper',
        status: 'active',
        runtime_blocker_class: 'turn_timeout',
        runtime_blocker_summary: 'turn has not made progress',
        trust: {
          latest_terminal_reason: {
            code: 'api_error_timeout',
            source: 'execution_receipt',
            severity: 'bad',
            summary: 'provider timed out',
          },
        },
      },
    ])

    expect(keeper?.stop_cause).toMatchObject({
      code: 'turn_timeout',
      source: 'runtime_blocker_class',
      summary: 'turn has not made progress',
    })
  })

  it('returns null latest_terminal_reason when code is missing', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'no-code-keeper',
        status: 'active',
        trust: {
          latest_terminal_reason: { source: 'execution_receipt' },
        },
      },
    ])
    expect(keeper?.trust?.latest_terminal_reason).toBeNull()
  })

  it('accepts live runtime_trust payloads and preserves terminal reason fields', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'runtime-trust-keeper',
        status: 'active',
        runtime_trust: {
          disposition: 'Blocked',
          operator_disposition: 'pause_human',
          operator_disposition_reason: 'required_tool_use_unsatisfied',
          needs_attention: true,
          approval: {
            state: 'ready',
            summary: 'no pending approvals',
            pending_count: 0,
          },
          execution: {
            provider_attempt_count: 2,
            provider_fallback_applied: true,
            provider_selected_model: 'provider:runtime-lane',
          },
          latest_terminal_reason: {
            code: 'required_tool_use_unsatisfied',
            source: 'execution_receipt',
            severity: 'bad',
            summary: 'required keeper tool use was not satisfied',
            next_action: 'inspect_provider_tool_contract',
          },
          latest_next_action: 'inspect_provider_tool_contract',
        },
      },
    ])

    expect(keeper?.trust).toMatchObject({
      disposition: 'Blocked',
      operator_disposition: 'pause_human',
      operator_disposition_reason: 'required_tool_use_unsatisfied',
      needs_attention: true,
      approval_state: {
        state: 'ready',
        summary: 'no pending approvals',
        pending_count: 0,
      },
      execution_summary: {
        provider_attempt_count: 2,
        provider_fallback_applied: true,
        provider_selected_model: 'provider:runtime-lane',
      },
      latest_terminal_reason: {
        code: 'required_tool_use_unsatisfied',
        severity: 'bad',
        next_action: 'inspect_provider_tool_contract',
      },
      latest_next_action: 'inspect_provider_tool_contract',
    })
  })

  it('preserves runtime lane evidence while redacting model/provider identity', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'runtime-keeper',
        status: 'active',
        runtime_id: 'oas-keeper_unified',
        selected_runtime_canonical: 'primary',
        primary_model: 'openai:gpt-5.4',
        active_model: 'gpt-5.4',
        active_model_label: 'openai:gpt-5.4',
        last_model_used: 'gpt-5.4',
        last_model_used_label: 'openai:gpt-5.4',
        metrics_series: [
          {
            ts_unix: 10,
            context_ratio: 0.42,
            context_tokens: 420,
            context_max: 1000,
            latency_ms: 100,
            generation: 1,
            channel: 'turn',
            model_used: 'anthropic:claude-sonnet',
            runtime: {
              runtime_id: 'primary',
              selected_model: 'anthropic:claude-sonnet',
              attempt_count: 2,
              outcome: 'passed_to_next_model',
              strategy: 'round_robin',
              fallback_applied: true,
              fallback_hops: 1,
              fallback_events: [
                {
                  from_model_id: 'openai:gpt-5.4',
                  to_model_id: 'anthropic:claude-sonnet',
                  reason: 'turn_timeout',
                },
              ],
            },
          },
        ],
      },
    ])

    expect(keeper).toMatchObject({
      runtime_id: 'oas-keeper_unified',
      runtime_canonical: 'primary',
      selected_runtime_canonical: 'primary',
      active_model_label: null,
      last_model_used_label: null,
    })
    expect(keeper?.primary_model).toBeUndefined()
    expect(keeper?.active_model).toBeUndefined()
    expect(keeper?.last_model_used).toBeUndefined()
    expect(keeper?.metrics_series?.[0]).toMatchObject({
      runtime_id: 'primary',
      runtime_selected_model: null,
      runtime_attempt_count: 2,
      runtime_outcome: 'passed_to_next_model',
      runtime_strategy: 'round_robin',
      fallback_applied: true,
      fallback_hops: 1,
      fallback_from: null,
      fallback_to: null,
      fallback_reason: 'turn_timeout',
    })
    expect(keeper?.metrics_series?.[0]?.model_used).toBe('')
  })

  it('normalizes ctx composition telemetry from keeper metric points', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'ctx-keeper',
        status: 'active',
        metrics_series: [
          {
            ts_unix: 5,
            context_ratio: 0.51,
            context_tokens: 510,
            context_max: 1000,
            latency_ms: 95,
            generation: 2,
            channel: 'turn',
            model_used: 'glm-5',
            cost_usd: 0.04,
            compacted: false,
            ctx_composition: {
              actual_input_tokens: 1000,
              attributed_bytes: 1160,
              segments: {
                system_prompt: { bytes: 320, fingerprint: null },
                history_user: { bytes: 210, fingerprint: null },
                history_tool_use: { bytes: 90, fingerprint: null },
                history_tool_result: { bytes: 540, fingerprint: null },
              },
            },
          },
        ],
      },
    ])

    expect(keeper?.metrics_series).toHaveLength(1)
    const metric = keeper?.metrics_series?.[0]
    expect(metric?.ctx_composition).toEqual({
      actual_input_tokens: 1000,
      attributed_bytes: 1160,
      segments: {
        system_prompt: { bytes: 320, fingerprint: null },
        history_user: { bytes: 210, fingerprint: null },
        history_tool_use: { bytes: 90, fingerprint: null },
        history_tool_result: { bytes: 540, fingerprint: null },
      },
    })
  })

  it('derives wall tok/s from usage output tokens and latency', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'wall-rate',
        status: 'active',
        metrics_series: [
          {
            ts_unix: 6,
            context_ratio: 0.24,
            context_tokens: 240,
            context_max: 1000,
            latency_ms: 2000,
            generation: 2,
            channel: 'turn',
            model_used: 'glm-5',
            cost_usd: 0.05,
            compacted: false,
            usage: {
              input_tokens: 120,
              output_tokens: 80,
              total_tokens: 200,
            },
            inference_telemetry: {
              request_latency_ms: 2000,
              timings: {
                predicted_per_second: 140,
                prompt_per_second: 55,
                cache_n: 10,
              },
            },
          },
        ],
      },
    ])

    const metric = keeper?.metrics_series?.[0]
    expect(metric?.input_tokens).toBe(120)
    expect(metric?.output_tokens).toBe(80)
    expect(metric?.total_tokens).toBe(200)
    expect(metric?.wall_tokens_per_second).toBe(40)
    expect(metric?.inference_telemetry?.timings?.predicted_per_second).toBe(140)
  })

  it('preserves missing latency as null in keeper runtime metrics', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'missing-latency',
        status: 'active',
        metrics_series: [
          {
            ts_unix: 7,
            context_ratio: 0.3,
            context_tokens: 300,
            context_max: 1000,
            generation: 2,
            channel: 'turn',
            model_used: 'glm-5',
            cost_usd: 0.05,
            usage: {
              input_tokens: 120,
              output_tokens: 80,
              total_tokens: 200,
            },
            inference_telemetry: {
              timings: {
                predicted_per_second: 140,
              },
            },
          },
        ],
      },
    ])

    const metric = keeper?.metrics_series?.[0]
    expect(metric?.latency_ms).toBeNull()
    expect(metric?.wall_tokens_per_second).toBeNull()
    expect(metric?.inference_telemetry?.request_latency_ms).toBeNull()
  })

  it('preserves paused runtime signals and blocker metadata for keeper UI', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'uranium666',
        status: 'idle',
        paused: true,
        keepalive_running: true,
        pause_state: 'paused',
        runtime_blocker_state: 'blocked',
        runtime_blocker_class: 'turn_timeout',
        runtime_blocker_summary: 'Provider turn timed out.',
        last_blocker: 'missing social headers',
        last_autonomous_action_at: '2026-04-04T14:08:35Z',
        created_at: '2026-04-03T14:59:29Z',
        updated_at: '2026-04-04T14:08:35Z',
        last_activity_ago_s: 42,
      },
    ])

    expect(keeper).toMatchObject({
      paused: true,
      keepalive_running: true,
      pause_state: 'paused',
      runtime_blocker_state: 'blocked',
      runtime_blocker_class: 'turn_timeout',
      runtime_blocker_summary: 'Provider turn timed out.',
      last_blocker: 'missing social headers',
      last_autonomous_action_at: '2026-04-04T14:08:35Z',
      created_at: '2026-04-03T14:59:29Z',
      updated_at: '2026-04-04T14:08:35Z',
      last_activity_ago_s: 42,
    })
  })
})

describe('normalizeKeeperTrustTerminalReason — exported helper', () => {
  it('returns null for non-record input', () => {
    expect(normalizeKeeperTrustTerminalReason(null)).toBeNull()
    expect(normalizeKeeperTrustTerminalReason('string')).toBeNull()
    expect(normalizeKeeperTrustTerminalReason(42)).toBeNull()
  })

  it('returns null when code field is absent or empty', () => {
    expect(normalizeKeeperTrustTerminalReason({})).toBeNull()
    expect(normalizeKeeperTrustTerminalReason({ code: null })).toBeNull()
    expect(normalizeKeeperTrustTerminalReason({ code: '' })).toBeNull()
  })

  it('returns a full terminal reason when code is present', () => {
    const result = normalizeKeeperTrustTerminalReason({
      code: 'turn_timeout',
      source: 'execution_receipt',
      severity: 'bad',
      summary: 'keeper exceeded the turn deadline',
      next_action: 'inspect_runtime_blocker',
    })
    expect(result).toEqual({
      code: 'turn_timeout',
      source: 'execution_receipt',
      severity: 'bad',
      summary: 'keeper exceeded the turn deadline',
      next_action: 'inspect_runtime_blocker',
    })
  })

  it('fills optional fields with null when absent', () => {
    const result = normalizeKeeperTrustTerminalReason({ code: 'runtime_blocked' })
    expect(result).toEqual({
      code: 'runtime_blocked',
      source: null,
      severity: null,
      summary: null,
      next_action: null,
    })
  })
})

describe('approval_state.pending_first — worktree approval blocker surfacing', () => {
  it('normalizes pending_first with all fields from approval_state', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'pr-keeper',
        status: 'active',
        trust: {
          needs_attention: true,
          attention_reason: 'approval_pending',
          next_human_action: 'resolve_approval',
          approval: {
            state: 'pending',
            pending_count: 1,
            pending_first: {
              id: 'appr_2cae9bec14f6',
              tool_name: 'Execute',
              task_id: 'task-187',
              blocker_class: 'blocked_before_worktree',
            },
          },
        },
      },
    ])
    expect(keeper?.trust?.approval_state?.pending_first).toEqual({
      id: 'appr_2cae9bec14f6',
      tool_name: 'Execute',
      task_id: 'task-187',
      blocker_class: 'blocked_before_worktree',
    })
  })

  it('sets pending_first to null when approval_state has no pending_first', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'pr-keeper',
        status: 'active',
        trust: {
          approval: {
            state: 'idle',
            pending_count: 0,
          },
        },
      },
    ])
    expect(keeper?.trust?.approval_state?.pending_first).toBeNull()
  })

  it('sets pending_first to null when individual fields are absent', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'pr-keeper',
        status: 'active',
        trust: {
          approval: {
            state: 'pending',
            pending_count: 1,
            pending_first: {},
          },
        },
      },
    ])
    expect(keeper?.trust?.approval_state?.pending_first).toEqual({
      id: null,
      tool_name: null,
      task_id: null,
      blocker_class: null,
    })
  })
})

describe('keeper profile config error boundary', () => {
  it('normalizes the closed config error schema without losing path or action', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'broken',
        status: 'blocked',
        needs_attention: true,
        config_error: {
          keeper: 'broken',
          keeper_path: '/workspace/.masc/config/keepers/broken.toml',
          failing_path: '/workspace/.masc/config/keepers/base.toml',
          kind: 'parse_error',
          detail: 'expected table header',
          terminal_reason: 'config_invalid',
          blocking: true,
          operator_action_required: true,
          next_action: 'fix_keeper_toml_config',
        },
      },
    ])

    expect(keeper?.config_error).toEqual({
      keeper: 'broken',
      keeper_path: '/workspace/.masc/config/keepers/broken.toml',
      failing_path: '/workspace/.masc/config/keepers/base.toml',
      kind: 'parse_error',
      reported_kind: null,
      detail: 'expected table header',
      terminal_reason: 'config_invalid',
      blocking: true,
      operator_action_required: true,
      next_action: 'fix_keeper_toml_config',
    })
  })

  it('retains unknown config error kinds as a fail-closed schema-drift value', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'broken',
        status: 'blocked',
        config_error: {
          keeper: 'broken',
          keeper_path: '/broken.toml',
          failing_path: '/broken.toml',
          kind: 'guessed_error',
          detail: 'unknown',
          terminal_reason: 'config_invalid',
          blocking: true,
          operator_action_required: true,
          next_action: 'fix_keeper_toml_config',
        },
      },
    ])

    expect(keeper?.config_error).toMatchObject({
      kind: 'unknown',
      reported_kind: 'guessed_error',
      blocking: true,
      operator_action_required: true,
    })
  })
})
