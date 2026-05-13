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
    expect(toKeeperPhase('zombie')).toBe('Zombie')
  })

  it('accepts PascalCase input for forward compatibility', () => {
    expect(toKeeperPhase('Offline')).toBe('Offline')
    expect(toKeeperPhase('Running')).toBe('Running')
    expect(toKeeperPhase('Overflowed')).toBe('Overflowed')
    expect(toKeeperPhase('HandingOff')).toBe('HandingOff')
    expect(toKeeperPhase('Zombie')).toBe('Zombie')
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
              estimated_total_tokens: 321,
              estimated_cacheable_tokens: 144,
              system_prompt: { bytes: 512, estimated_tokens: 144, fingerprint: 'seg-system' },
              dynamic_context: { bytes: 220, estimated_tokens: 61, fingerprint: 'seg-dynamic' },
              user_message: { bytes: 98, estimated_tokens: 28, fingerprint: 'seg-user' },
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
      estimated_total_tokens: 321,
      estimated_cacheable_tokens: 144,
      segments: {
        system_prompt: { bytes: 512, estimated_tokens: 144, fingerprint: 'seg-system' },
        dynamic_context: { bytes: 220, estimated_tokens: 61, fingerprint: 'seg-dynamic' },
        user_message: { bytes: 98, estimated_tokens: 28, fingerprint: 'seg-user' },
      },
    })
  })

  it('preserves backend attention, sandbox, and goal progress fields', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'attention-keeper',
        status: 'active',
        needs_attention: true,
        attention_reason: 'approval_pending',
        next_human_action: 'resolve_approval',
        sandbox_target: 'docker',
        blocked_task_count: 2,
        goal_progress: {
          active_goal_count: 1,
          linked_task_count: 4,
          done_task_count: 1,
          open_task_count: 3,
          blocked_task_count: 2,
          convergence: 0.25,
        },
        approval_policy_effective: {
          allow_rules: 1,
          deny_rules: 0,
          persisted_rules: 1,
        },
      },
    ])

    expect(keeper).toMatchObject({
      needs_attention: true,
      attention_reason: 'approval_pending',
      next_human_action: 'resolve_approval',
      sandbox_target: 'docker',
      blocked_task_count: 2,
      goal_progress: {
        linked_task_count: 4,
        blocked_task_count: 2,
        convergence: 0.25,
      },
      approval_policy_effective: {
        allow_rules: 1,
        persisted_rules: 1,
      },
    })
  })

  it('preserves trust summary and latest causal event fields', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'trust-keeper',
        status: 'active',
        trust: {
          disposition: 'Pause',
          disposition_reason: 'approval_waiting',
          needs_attention: true,
          attention_reason: 'approval_pending',
          next_human_action: 'resolve_approval',
          approval_state: {
            state: 'pending',
            summary: '1 approval request waiting',
            pending_count: 1,
          },
          execution_summary: {
            tool_contract_result: 'unknown',
            sandbox_summary: 'docker / none',
            mutation_guard_summary: 'mutation_contract_not_observed',
            latest_receipt_at: '2026-04-23T00:10:00Z',
          },
          latest_causal_event: {
            kind: 'approval_pending',
            ts: '2026-04-23T00:11:00Z',
            ts_unix: 1776903060,
            keeper_turn_id: 42,
            task_id: 'task-1',
            goal_ids: ['goal-1'],
            title: 'Approval pending',
            summary: 'Waiting for operator approval before resuming.',
            severity: 'warn',
            next_human_action: 'resolve_approval',
          },
        },
      },
    ])

    expect(keeper?.trust).toMatchObject({
      disposition: 'Pause',
      disposition_reason: 'approval_waiting',
      needs_attention: true,
      attention_reason: 'approval_pending',
      next_human_action: 'resolve_approval',
      approval_state: {
        state: 'pending',
        summary: '1 approval request waiting',
        pending_count: 1,
      },
      execution_summary: {
        tool_contract_result: 'unknown',
        sandbox_summary: 'docker / none',
        mutation_guard_summary: 'mutation_contract_not_observed',
      },
      latest_causal_event: {
        kind: 'approval_pending',
        keeper_turn_id: 42,
        title: 'Approval pending',
        summary: 'Waiting for operator approval before resuming.',
      },
    })
  })

  it('preserves stopped-reaction fields in trust summary', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'blocked-keeper',
        status: 'active',
        trust: {
          disposition: 'Alert',
          operator_disposition: 'pause_runtime',
          operator_disposition_reason: 'timeout_budget_exhausted',
          needs_attention: true,
          attention_reason: 'timeout_budget_exhausted',
          latest_terminal_reason: {
            code: 'timeout_budget_exhausted',
            source: 'execution_receipt',
            severity: 'bad',
            summary: 'Turn budget exhausted after 15 turns',
            next_action: 'inspect_timeout_budget',
          },
          latest_next_action: 'inspect_timeout_budget',
        },
      },
    ])

    expect(keeper?.trust).toMatchObject({
      disposition: 'Alert',
      operator_disposition: 'pause_runtime',
      operator_disposition_reason: 'timeout_budget_exhausted',
      needs_attention: true,
      attention_reason: 'timeout_budget_exhausted',
      latest_terminal_reason: {
        code: 'timeout_budget_exhausted',
        source: 'execution_receipt',
        severity: 'bad',
        summary: 'Turn budget exhausted after 15 turns',
        next_action: 'inspect_timeout_budget',
      },
      latest_next_action: 'inspect_timeout_budget',
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
          disposition: 'Pause',
          operator_disposition: 'pause_human',
          operator_disposition_reason: 'required_tool_use_unsatisfied',
          needs_attention: true,
          approval: {
            state: 'ready',
            summary: 'no pending approvals',
            pending_count: 0,
          },
          execution: {
            tool_contract_result: 'violated',
            required_tools: ['masc_board_post'],
            missing_required_tools: ['masc_board_post'],
            provider_attempt_count: 2,
            provider_fallback_applied: true,
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
      disposition: 'Pause',
      operator_disposition: 'pause_human',
      operator_disposition_reason: 'required_tool_use_unsatisfied',
      needs_attention: true,
      approval_state: {
        state: 'ready',
        summary: 'no pending approvals',
        pending_count: 0,
      },
      execution_summary: {
        tool_contract_result: 'violated',
        required_tools: ['masc_board_post'],
        missing_required_tools: ['masc_board_post'],
        provider_attempt_count: 2,
        provider_fallback_applied: true,
      },
      latest_terminal_reason: {
        code: 'required_tool_use_unsatisfied',
        severity: 'bad',
        next_action: 'inspect_provider_tool_contract',
      },
      latest_next_action: 'inspect_provider_tool_contract',
    })
  })

  it('preserves cascade lane evidence while redacting model/provider identity', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'cascade-keeper',
        status: 'active',
        cascade_name: 'oas-keeper_unified',
        selected_cascade_canonical: 'primary',
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
            model_used: 'anthropic:claude-sonnet-4-6',
            cascade: {
              cascade_name: 'primary',
              selected_model: 'anthropic:claude-sonnet-4-6',
              attempt_count: 2,
              outcome: 'passed_to_next_model',
              strategy: 'round_robin',
              fallback_applied: true,
              fallback_hops: 1,
              fallback_events: [
                {
                  from_model_id: 'openai:gpt-5.4',
                  to_model_id: 'anthropic:claude-sonnet-4-6',
                  reason: 'turn_timeout',
                },
              ],
            },
          },
        ],
      },
    ])

    expect(keeper).toMatchObject({
      cascade_name: 'oas-keeper_unified',
      cascade_canonical: 'primary',
      selected_cascade_canonical: 'primary',
      active_model_label: null,
      last_model_used_label: null,
    })
    expect(keeper?.primary_model).toBeUndefined()
    expect(keeper?.active_model).toBeUndefined()
    expect(keeper?.last_model_used).toBeUndefined()
    expect(keeper?.metrics_series?.[0]).toMatchObject({
      cascade_name: 'primary',
      cascade_selected_model: null,
      cascade_attempt_count: 2,
      cascade_outcome: 'passed_to_next_model',
      cascade_strategy: 'round_robin',
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
              display_total_tokens: 1000,
              estimated_known_tokens: 740,
              segments: {
                system_prompt: { bytes: 320, estimated_tokens: 120, fingerprint: null },
                history_user: { bytes: 210, estimated_tokens: 90, fingerprint: null },
                history_tool_use: { bytes: 90, estimated_tokens: 60, fingerprint: null },
                history_tool_result: { bytes: 540, estimated_tokens: 330, fingerprint: null },
                unattributed: { bytes: 0, estimated_tokens: 260, fingerprint: null },
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
      display_total_tokens: 1000,
      estimated_known_tokens: 740,
      segments: {
        system_prompt: { bytes: 320, estimated_tokens: 120, fingerprint: null },
        history_user: { bytes: 210, estimated_tokens: 90, fingerprint: null },
        history_tool_use: { bytes: 90, estimated_tokens: 60, fingerprint: null },
        history_tool_result: { bytes: 540, estimated_tokens: 330, fingerprint: null },
        unattributed: { bytes: 0, estimated_tokens: 260, fingerprint: null },
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
        runtime_blocker_class: 'ambiguous_post_commit_timeout',
        runtime_blocker_summary:
          'Mutating tools [keeper_fs_edit] committed before the turn timed out.',
        runtime_blocker_continue_gate: true,
        social_model: 'bdi_speech_v1',
        configured_social_model: 'experimental_v99',
        social_model_recognized: false,
        social_model_fallback: 'bdi_speech_v1',
        last_blocker: 'missing social headers',
        last_speech_act: 'defer',
        last_need: '현재 대화 맥락',
        last_autonomous_action_at: '2026-04-04T14:08:35Z',
        created_at: '2026-04-03T14:59:29Z',
        updated_at: '2026-04-04T14:08:35Z',
        last_activity_ago_s: 42,
      },
    ])

    expect(keeper).toMatchObject({
      paused: true,
      keepalive_running: true,
      runtime_blocker_class: 'ambiguous_post_commit_timeout',
      runtime_blocker_summary:
        'Mutating tools [keeper_fs_edit] committed before the turn timed out.',
      runtime_blocker_continue_gate: true,
      social_model: null,
      configured_social_model: null,
      social_model_recognized: false,
      social_model_fallback: null,
      last_blocker: 'missing social headers',
      last_speech_act: 'defer',
      last_need: '현재 대화 맥락',
      last_autonomous_action_at: '2026-04-04T14:08:35Z',
      created_at: '2026-04-03T14:59:29Z',
      updated_at: '2026-04-04T14:08:35Z',
      last_activity_ago_s: 42,
    })
  })
})

describe('normalizeKeepers turn_budget', () => {
  it('normalizes override reactive + env autonomous with provenance fields', () => {
    const [k] = normalizeKeepers([
      {
        name: 'poe',
        status: 'active',
        turn_budget: {
          reactive: {
            value: 25,
            source: 'override',
            env_default: 15,
            env_var: 'MASC_KEEPER_OAS_MAX_TURNS_PER_CALL',
          },
          scheduled_autonomous: {
            value: 2,
            source: 'env',
            env_default: 2,
            env_var: 'MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS',
          },
          manifest_path: '/abs/config/keepers/poe.toml',
          clamp_min: 1,
          clamp_max: 50,
        },
      },
    ])
    expect(k?.turn_budget).toEqual({
      reactive: {
        value: 25,
        source: 'override',
        env_default: 15,
        env_var: 'MASC_KEEPER_OAS_MAX_TURNS_PER_CALL',
        raw_override: null,
      },
      scheduled_autonomous: {
        value: 2,
        source: 'env',
        env_default: 2,
        env_var: 'MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS',
        raw_override: null,
      },
      manifest_path: '/abs/config/keepers/poe.toml',
      clamp_min: 1,
      clamp_max: 50,
    })
  })

  it('returns null when turn_budget is absent', () => {
    const [k] = normalizeKeepers([{ name: 'no-budget', status: 'active' }])
    expect(k?.turn_budget).toBeNull()
  })

  it('returns null when either slot is missing value', () => {
    const [k] = normalizeKeepers([
      {
        name: 'partial',
        status: 'active',
        turn_budget: {
          reactive: { value: 15, source: 'env' },
          // scheduled_autonomous missing — should reject the whole budget
        },
      },
    ])
    expect(k?.turn_budget).toBeNull()
  })

  it('defaults env_default to current value and clamp to [1,50] when backend omits them', () => {
    const [k] = normalizeKeepers([
      {
        name: 'minimal',
        status: 'active',
        turn_budget: {
          reactive: { value: 15, source: 'env' },
          scheduled_autonomous: { value: 2, source: 'env' },
        },
      },
    ])
    expect(k?.turn_budget?.reactive.env_default).toBe(15)
    expect(k?.turn_budget?.clamp_min).toBe(1)
    expect(k?.turn_budget?.clamp_max).toBe(50)
    expect(k?.turn_budget?.manifest_path).toBeNull()
  })

  it('coerces unknown source string to env (safe fallback)', () => {
    const [k] = normalizeKeepers([
      {
        name: 'unknown-source',
        status: 'active',
        turn_budget: {
          reactive: { value: 15, source: 'garbage' },
          scheduled_autonomous: { value: 2, source: 'override' },
        },
      },
    ])
    expect(k?.turn_budget?.reactive.source).toBe('env')
    expect(k?.turn_budget?.scheduled_autonomous.source).toBe('override')
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
      code: 'timeout_budget_exhausted',
      source: 'execution_receipt',
      severity: 'bad',
      summary: 'keeper timed out before completing the turn',
      next_action: 'adjust_timeout_budget',
    })
    expect(result).toEqual({
      code: 'timeout_budget_exhausted',
      source: 'execution_receipt',
      severity: 'bad',
      summary: 'keeper timed out before completing the turn',
      next_action: 'adjust_timeout_budget',
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
              tool_name: 'masc_worktree_create',
              task_id: 'task-187',
              blocker_class: 'blocked_before_worktree',
            },
          },
        },
      },
    ])
    expect(keeper?.trust?.approval_state?.pending_first).toEqual({
      id: 'appr_2cae9bec14f6',
      tool_name: 'masc_worktree_create',
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
