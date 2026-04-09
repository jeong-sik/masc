import { describe, expect, it } from 'vitest'
import { deriveLifecycleState, normalizeKeepers, toKeeperPhase } from './keeper-store-normalize'

describe('toKeeperPhase — backend lowercase to PascalCase normalization', () => {
  it('maps lowercase backend phase strings to PascalCase KeeperPhase', () => {
    expect(toKeeperPhase('offline')).toBe('Offline')
    expect(toKeeperPhase('running')).toBe('Running')
    expect(toKeeperPhase('failing')).toBe('Failing')
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
    expect(toKeeperPhase('HandingOff')).toBe('HandingOff')
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
      handoff_to_model: 'glm-5',
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
      handoff_to_model: 'llama:test-balanced',
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

  it('drops authored tool policy duplicates from shell rows while keeping runtime audit fields', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'delta',
        status: 'active',
        tool_policy_mode: 'custom',
        tool_preset: 'full',
        tool_also_allow: ['mcp__masc__masc_join'],
        tool_custom_allowlist: ['mcp__masc__masc_board_post'],
        tool_denylist: ['mcp__masc__masc_board_delete'],
        allowed_tool_names: ['compat_only_allowlist'],
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
    expect(keeper as unknown as Record<string, unknown>).not.toHaveProperty('tool_policy_mode')
    expect(keeper as unknown as Record<string, unknown>).not.toHaveProperty('tool_preset')
    expect(keeper as unknown as Record<string, unknown>).not.toHaveProperty('tool_also_allow')
    expect(keeper as unknown as Record<string, unknown>).not.toHaveProperty('tool_custom_allowlist')
    expect(keeper as unknown as Record<string, unknown>).not.toHaveProperty('tool_denylist')
    expect(keeper as unknown as Record<string, unknown>).not.toHaveProperty('allowed_tool_names')
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

  it('preserves paused runtime signals and blocker metadata for keeper UI', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'uranium666',
        status: 'idle',
        paused: true,
        keepalive_running: true,
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
