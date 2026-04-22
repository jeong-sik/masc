import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  fetchDashboardGovernance,
  fetchDashboardTools,
  fetchKeeperConfig,
  fetchRuntimeModelMetrics,
  fetchToolQuality,
} from './dashboard'

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('fetchDashboardTools', () => {
  it('fills missing category and tier with defaults', async () => {
    const rawResponse = {
      tool_inventory: {
        tools: [
          { name: 'tool_a' },
          { name: 'tool_b', category: 'keeper' },
          { name: 'tool_c', tier: 'essential' },
        ],
      },
      tool_usage: { total_calls: 0, distinct_tools_called: 0, top_20: [], never_called_count: 0, dispatch_v2_enabled: false, registered_count: 3 },
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardTools()

    const tools = result.tool_inventory.tools
    expect(tools[0]).toMatchObject({ name: 'tool_a', category: 'uncategorized', tier: 'standard' })
    expect(tools[1]).toMatchObject({ name: 'tool_b', category: 'keeper', tier: 'standard' })
    expect(tools[2]).toMatchObject({ name: 'tool_c', category: 'uncategorized', tier: 'essential' })
  })

  it('returns a new object without mutating the raw response', async () => {
    const tools = [{ name: 'tool_x' }]
    const rawResponse = {
      tool_inventory: { tools },
      tool_usage: { total_calls: 0, distinct_tools_called: 0, top_20: [], never_called_count: 0, dispatch_v2_enabled: false, registered_count: 1 },
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardTools()

    // The returned tools array should be a different reference
    expect(result.tool_inventory.tools).not.toBe(tools)
    // Original raw tools should not have category/tier injected
    expect(tools[0]).not.toHaveProperty('category')
    expect(tools[0]).not.toHaveProperty('tier')
  })

  it('handles missing tool_inventory gracefully', async () => {
    const rawResponse = {
      tool_inventory: {},
      tool_usage: { total_calls: 0, distinct_tools_called: 0, top_20: [], never_called_count: 0, dispatch_v2_enabled: false, registered_count: 0 },
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardTools()
    expect(result.tool_inventory).toBeDefined()
  })
})

describe('fetchToolQuality', () => {
  it('passes through the requested sample window', async () => {
    const rawResponse = {
      generated_at: '2026-04-14T00:00:00Z',
      sampling_mode: 'recent_n',
      sample_limit: 250,
      total: 1,
      success: 1,
      failure: 0,
      success_rate: 100,
      by_tool: [],
      by_keeper: [],
      failure_categories: [],
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchToolQuality({ n: 250 })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/tool-quality?n=250')
    expect(result.total).toBe(1)
    expect(result.sample_limit).toBe(250)
  })

  it('passes through the requested time window', async () => {
    const rawResponse = {
      generated_at: '2026-04-15T00:00:00Z',
      sampling_mode: 'window_hours',
      sample_limit: null,
      window_hours: 24,
      total: 3,
      success: 3,
      failure: 0,
      success_rate: 100,
      by_tool: [],
      by_keeper: [],
      failure_categories: [],
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchToolQuality({ windowHours: 24 })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/tool-quality?window_hours=24')
    expect(result.window_hours).toBe(24)
    expect(result.sampling_mode).toBe('window_hours')
  })
})

describe('fetchDashboardGovernance', () => {
  it('does not retry structured computation timeouts', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        error: 'computation_timeout',
        message: 'Dashboard governance timed out after 30s',
      }), {
        status: 504,
        statusText: 'Gateway Timeout',
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(fetchDashboardGovernance()).rejects.toMatchObject({
      name: 'ApiRequestError',
      status: 504,
      errorCode: 'computation_timeout',
    })
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})

describe('fetchKeeperConfig', () => {
  it('normalizes singleton string, numeric string, and boolean string fields', async () => {
    const rawResponse = {
      name: 'keeper-sangsu',
      execution_scope: 'workspace',
      sandbox_profile: 'docker',
      network_mode: 'none',
      shared_memory_scope: 'room',
      sandbox_last_error: 'sandbox docker exec failed',
      effective_sandbox_image: 'ubuntu:24.04@sha256:test',
      private_workspace_root: '.masc/playground/keeper-sangsu',
      sandbox_environment: {
        base_path: '/tmp/project-root/.masc',
        project_root: '/tmp/project-root',
        docker_playground_enabled: 'true',
        docker_container_name: 'keeper-playground',
        container_playground_root: '/home/keeper/playground',
        docker_image: 'ubuntu:24.04@sha256:test',
        pids_limit: '128',
        memory: '2g',
        tmpfs_size: '256m',
        seccomp_profile: '',
        require_rootless: 'false',
        require_userns: 'true',
      },
      allowed_paths: '/tmp/workspace',
      effective_allowed_paths: ['/tmp/workspace'],
      prompt: {
        goal: 'Ship stable keeper ops',
        short_goal: 'Diagnose agent liveness',
        mid_goal: 'Reduce restart confusion',
        long_goal: 'Keep coordination stable',
        will: 'Stay on call',
        needs: 'Accurate runtime state',
        desires: 'Clear operator feedback',
        instructions: 'Prefer direct remediation',
        system_prompt_blocks: {
          constitution: { key: 'keeper.constitution', source: 'file', text: 'constitution text' },
          world: { key: 'keeper.world', source: 'override', text: 'world text' },
          capabilities: { key: 'keeper.capabilities', source: 'file', text: 'capabilities text' },
        },
        effective_system_prompt: 'full prompt',
      },
      execution: {
        models: 'llama:test-balanced',
        active_model: 'llama:test-balanced',
        verify: 'true',
        selected_cascade_name: 'keeper_unified',
        selected_cascade_canonical: 'keeper_unified',
      },
      compaction: {
        profile: 'balanced',
        ratio_gate: '0.85',
        message_gate: '16',
        token_gate: '24000',
        cooldown_sec: '120',
      },
      proactive: {
        enabled: 'true',
        idle_sec: '900',
        cooldown_sec: '1800',
      },
      drift: {
        status: 'wired',
        enabled: 'true',
        min_turn_gap: '4',
        count_total: '2',
        last_reason: 'board quiet',
      },
      handoff: {
        auto: 'true',
        threshold: '0.85',
        cooldown_sec: '300',
      },
      hooks: {
        slots: {
          pre_tool_use: {
            active: 'true',
            source: 'keeper_hooks_oas',
            gates: 'keeper_deny_list',
          },
        },
        deny_list: 'keeper_bash',
        deny_list_count: '1',
        destructive_check_tools: 'dynamic_boundary (Tool_dispatch.is_destructive)',
        cost_budget: {
          active: 'false',
        },
      },
      runtime: {
        paused: 'false',
        registered: 'true',
        keepalive_running: 'true',
        registry_state: 'running',
        fiber_health: 'healthy',
        presence_keepalive: 'true',
        presence_keepalive_sec: '30',
        runtime_blocker_continue_gate: 'false',
      },
      coordination: {
        room_scope: 'global',
        mention_targets: 'sangsu',
        joined_room_ids: 'default',
      },
      tools: {
        tool_access: { kind: 'preset', preset: 'coding' },
        tool_policy_mode: 'preset',
        tool_preset: 'coding',
        tool_also_allow: 'keeper_board_post',
        tool_custom_allowlist: [],
        resolved_allowlist: 'keeper_fs_read',
        tool_denylist: 'keeper_bash',
        active_masc_tool_count: '1',
        active_keeper_tool_count: '2',
        total_active: '3',
      },
      sources: {
        live_meta_path: '/tmp/.masc/keepers/keeper-sangsu/live.json',
        default_manifest_path: null,
        default_source_kind: 'toml',
        precedence: 'live_meta',
        has_live_override: 'true',
        override_fields: 'goal',
        cascade_catalog_source_kind: 'toml',
        cascade_catalog_source_path: '/tmp/config/cascade.toml',
        cascade_runtime_json_path: '/tmp/config/cascade.json',
        cascade_runtime_json_editable: 'false',
      },
      metrics: {
        generation: '3',
        total_turns: '12',
        total_input_tokens: '1200',
        total_output_tokens: '800',
        total_tokens: '2000',
        total_cost_usd: '0.12',
        last_model_used: 'llama:test-balanced',
        last_input_tokens: '120',
        last_output_tokens: '80',
        last_total_tokens: '200',
        last_latency_ms: '2400',
        last_total_tokens_per_sec: '22.4',
        last_output_tokens_per_sec: '11.2',
        compaction_count: '1',
      },
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperConfig('keeper-sangsu')

    expect(result.allowed_paths).toEqual(['/tmp/workspace'])
    expect(result.sandbox_profile).toBe('docker')
    expect(result.network_mode).toBe('none')
    expect(result.shared_memory_scope).toBe('room')
    expect(result.sandbox_last_error).toBe('sandbox docker exec failed')
    expect(result.effective_sandbox_image).toBe('ubuntu:24.04@sha256:test')
    expect(result.private_workspace_root).toBe('.masc/playground/keeper-sangsu')
    expect(result.sandbox_environment?.base_path).toBe('/tmp/project-root/.masc')
    expect(result.sandbox_environment?.project_root).toBe('/tmp/project-root')
    expect(result.sandbox_environment?.docker_playground_enabled).toBe(true)
    expect(result.sandbox_environment?.docker_container_name).toBe('keeper-playground')
    expect(result.sandbox_environment?.container_playground_root).toBe('/home/keeper/playground')
    expect(result.sandbox_environment?.docker_image).toBe('ubuntu:24.04@sha256:test')
    expect(result.sandbox_environment?.pids_limit).toBe(128)
    expect(result.sandbox_environment?.memory).toBe('2g')
    expect(result.sandbox_environment?.tmpfs_size).toBe('256m')
    expect(result.sandbox_environment?.seccomp_profile).toBeNull()
    expect(result.sandbox_environment?.require_rootless).toBe(false)
    expect(result.sandbox_environment?.require_userns).toBe(true)
    expect(result.execution.models).toEqual(['llama:test-balanced'])
    expect(result.execution.verify).toBe(true)
    expect(result.execution.selected_cascade_name).toBe('keeper_unified')
    expect(result.execution.selected_cascade_canonical).toBe('keeper_unified')
    expect(result.hooks?.destructive_check_tools).toEqual(['dynamic_boundary (Tool_dispatch.is_destructive)'])
    expect(result.hooks?.slots.pre_tool_use?.gates).toEqual(['keeper_deny_list'])
    expect(result.tools.tool_also_allow).toEqual(['keeper_board_post'])
    expect(result.sources.precedence).toEqual(['live_meta'])
    expect(result.sources.cascade_catalog_source_kind).toBe('toml')
    expect(result.sources.cascade_catalog_source_path).toBe('/tmp/config/cascade.toml')
    expect(result.sources.cascade_runtime_json_path).toBe('/tmp/config/cascade.json')
    expect(result.sources.cascade_runtime_json_editable).toBe(false)
    expect(result.metrics.total_cost_usd).toBe(0.12)
    expect(result.runtime.presence_keepalive_sec).toBe(30)
  })
})

describe('fetchRuntimeModelMetrics', () => {
  it('preserves null telemetry fields instead of coercing them to zero', async () => {
    const rawResponse = {
      window_minutes: 30,
      bucket_minutes: 5,
      total_entries: 1,
      total_error_entries: 0,
      models: [
        {
          model_id: 'kimi_cli:kimi-for-coding',
          entry_count: 1,
          success_count: 1,
          usage_sample_count: 0,
          telemetry_sample_count: 0,
          avg_latency_ms: null,
          total_input_tokens: null,
          total_cost_usd: null,
          recent_entries: [
            {
              ts_unix: 1,
              input_tokens: null,
              output_tokens: null,
              latency_ms: null,
              cost_usd: null,
              tools_count: 0,
            },
          ],
          buckets: [
            {
              ts_start: 1,
              entry_count: 1,
              success_count: 1,
              error_count: 0,
              p50_latency_ms: null,
              p95_latency_ms: null,
              error_rate: 0,
              total_cost_usd: null,
              cache_hit_ratio: null,
            },
          ],
        },
      ],
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchRuntimeModelMetrics()
    const metric = result.models[0]!

    expect(metric.usage_sample_count).toBe(0)
    expect(metric.telemetry_sample_count).toBe(0)
    expect(metric.total_input_tokens).toBeNull()
    expect(metric.total_cost_usd).toBeNull()
    expect(metric.recent_entries?.[0]?.input_tokens).toBeNull()
    expect(metric.recent_entries?.[0]?.latency_ms).toBeNull()
    expect(metric.buckets?.[0]?.p95_latency_ms).toBeNull()
    expect(metric.buckets?.[0]?.cache_hit_ratio).toBeNull()
  })
})
