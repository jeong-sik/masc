import { afterEach, describe, expect, it, vi } from 'vitest'

const devTokenMock = vi.hoisted(() => ({
  ensureDevToken: vi.fn(() => Promise.resolve()),
}))

vi.mock('./dev-token', () => ({
  ensureDevToken: devTokenMock.ensureDevToken,
}))

import {
  fetchDashboardShell,
  fetchDashboardExecution,
  fetchDashboardExecutionTrust,
  fetchDashboardGate,
  fetchDashboardGoalDetail,
  fetchDashboardGoalsTree,
  fetchDashboardBriefing,
  fetchDashboardTools,
  fetchKeeperWaitingInventory,
  parseDashboardKeeperWaitingSource,
  normalizeSkillActivationProjection,
  fetchDashboardFullHealth,
  fetchKeeperToolCalls,
  fetchKeeperToolStats,
  fetchKeeperTurnRecords,
  parseMemoryOsFactCategory,
  fetchKeeperTurnTranscript,
  fetchDashboardMemory,
  fetchDashboardMission,
  fetchDashboardMissionBriefing,
  fetchDashboardRuntimeProbe,
  fetchCostLatency,
  fetchKeeperConfig,
  fetchKeeperCostMetrics,
  fetchKeeperDecisions,
  fetchRuntimeProviders,
  fetchRuntimeTomlConfig,
  fetchRuntimeDefaults,
  fetchRuntimeModelMetrics,
  fetchOfficialClientSession,
  resolveOfficialClientSession,
  probeOfficialClientLogin,
  patchRuntimeAssignment,
  patchRuntimeMediaFailover,
  patchRuntimeRouting,
  patchKeeperConfig,
  previewRuntimeTomlConfig,
  saveRuntimeTomlConfig,
  fetchDashboardCacheStats,
  fetchTelemetry,
  fetchTelemetrySummary,
  fetchTlcResults,
  fetchToolQuality,
  setGateMode,
  resolveGateApproval,
  deleteGateApprovalRule,
} from './dashboard'
import { fetchDashboardShell as fetchDashboardShellHot } from './dashboard-hot'
import { keeperRuntimeBlockerLabel } from '../lib/keeper-runtime-display'

afterEach(() => {
  vi.unstubAllGlobals()
  devTokenMock.ensureDevToken.mockClear()
  devTokenMock.ensureDevToken.mockResolvedValue(undefined)
})

function makeRawGoalNode(overrides: Record<string, unknown> = {}) {
  return {
    id: 'goal-1',
    title: 'Goal 1',
    status: 'active',
    status_color: '#fff',
    phase: 'executing',
    phase_color: '#0ea5e9',
    priority: 1,
    metric: null,
    target_value: null,
    due_date: null,
    tasks: [],
    task_count: 0,
    task_done_count: 0,
    timeline_events: [],
    children: [],
    child_count: 0,
    last_activity_at: '2026-04-23T00:00:00Z',
    stagnation_seconds: 0,
    linked_keeper_names: [],
    pending_approval_count: 0,
    latest_keeper_ref: null,
    latest_turn_ref: null,
    created_at: '2026-04-23T00:00:00Z',
    updated_at: '2026-04-23T00:00:00Z',
    ...overrides,
  }
}

describe('fetchDashboardShell', () => {
  it('uses the hot-path shell fetcher as the API SSOT', () => {
    expect(fetchDashboardShell).toBe(fetchDashboardShellHot)
  })

  it('uses the light shell query when requested', async () => {
    const rawResponse = {
      status: { project: 'default' },
      counts: { agents: 1, tasks: 2, keepers: 3 },
    }
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    await fetchDashboardShell({ light: true })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/shell?light=true')
  })
})

describe('fetchDashboardExecution', () => {
  it('uses the cached execution endpoint by default', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ agents: [], tasks: [], messages: [], keepers: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await fetchDashboardExecution()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/execution')
  })

  it('requests a forced execution snapshot when asked', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ agents: [], tasks: [], messages: [], keepers: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await fetchDashboardExecution({ force: true })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/execution?force=1')
  })
})

describe('fetchDashboardExecutionTrust', () => {
  it('requests the dedicated execution trust surface and preserves coverage gaps', async () => {
    const rawResponse = {
      generated_at: '2026-05-14T00:00:00Z',
      source: 'execution_receipt',
      producer: 'keeper_agent_run.execution_receipt',
      durable_store: '.masc/keepers/*/execution-receipts',
      dashboard_surface: '/api/v1/dashboard/execution-trust',
      dashboard_surface_envelope: {
        schema: 'masc.dashboard_surface.v1',
        schema_version: 1,
        surface: '/api/v1/dashboard/execution-trust',
        source: 'execution_receipt',
        generated_at_iso: '2026-05-14T00:00:00Z',
        cache: {
          state: 'request_cache',
          key: 'execution-trust:default',
          ttl_s: 15,
          stale: true,
          stale_reason: 'execution_receipt_append_failed',
          latest_age_s: null,
          health: 'coverage_gap',
        },
      },
      freshness_slo_s: 900,
      entry_count: 0,
      total: 0,
      keepers: [],
      health: 'coverage_gap',
      stale_reason: 'execution_receipt_append_failed',
      coverage_gap_count: 1,
      active_coverage_gap_count: 1,
      coverage_gaps: [
        {
          schema: 'masc.telemetry_coverage_gap.v1',
          source: 'execution_receipt',
          producer: 'keeper_agent_run.execution_receipt',
          durable_store: '.masc/keepers/*/execution-receipts',
          dashboard_surface: '/api/v1/dashboard/execution-trust',
          stale_reason: 'execution_receipt_append_failed',
          keeper_name: 'sangsu',
          trace_id: 'trace-exec-gap',
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

    const result = await fetchDashboardExecutionTrust()

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/execution-trust')
    expect(result.coverage_gap_count).toBe(1)
    expect(result.active_coverage_gap_count).toBe(1)
    expect(result.dashboard_surface_envelope).toMatchObject({
      schema: 'masc.dashboard_surface.v1',
      surface: '/api/v1/dashboard/execution-trust',
      source: 'execution_receipt',
      cache: {
        state: 'request_cache',
        key: 'execution-trust:default',
        stale_reason: 'execution_receipt_append_failed',
      },
    })
    expect(result.coverage_gaps?.[0]).toMatchObject({
      producer: 'keeper_agent_run.execution_receipt',
      durable_store: '.masc/keepers/*/execution-receipts',
      dashboard_surface: '/api/v1/dashboard/execution-trust',
      stale_reason: 'execution_receipt_append_failed',
      keeper_name: 'sangsu',
      trace_id: 'trace-exec-gap',
    })
  })
})

describe('dashboard briefing fetchers', () => {
  it('requests the canonical briefing surface', async () => {
    const rawResponse = {
      summary: { workspace_health: 'ok' },
      incidents: [],
      recommended_actions: [],
      command_focus: {},
      operator_targets: { keepers: [], available_actions: [] },
      attention_queue: [],
      sessions: [],
      agent_briefs: [],
      keeper_briefs: [],
      internal_signals: [],
    }
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await fetchDashboardBriefing()

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/briefing')
  })

  it('keeps the mission snapshot fetcher as a compatibility alias', async () => {
    const rawResponse = {
      summary: { workspace_health: 'ok' },
      incidents: [],
      recommended_actions: [],
      command_focus: {},
      operator_targets: { keepers: [], available_actions: [] },
      attention_queue: [],
      sessions: [],
      agent_briefs: [],
      keeper_briefs: [],
      internal_signals: [],
    }
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await fetchDashboardMission()

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/briefing')
  })

  it('requests canonical briefing sections and preserves force', async () => {
    const rawResponse = {
      status: 'ok',
      criteria: [],
      sections: [],
    }
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await fetchDashboardMissionBriefing(true)

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/briefing/sections?force=1')
  })
})

describe('keeper tool telemetry fetchers', () => {
  it('preserves tool-stats coverage gap rows', async () => {
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(
      new Response(JSON.stringify({
        keeper: 'keeper-alpha',
        window_hours: 24,
        total_entries: 0,
        source: 'trajectory_tool_call',
        health: 'coverage_gap',
        stale_reason: 'trajectory_append_failed',
        coverage_gaps: [
          {
            schema: 'masc.telemetry_coverage_gap.v1',
            ts: 1_777_100_000,
            ts_iso: '2026-05-14T00:00:00Z',
            source: 'trajectory_tool_call',
            producer: 'keeper_hooks_agentCore.post_tool_use',
            durable_store: '.masc/keepers/keeper-alpha/trajectories',
            dashboard_surface: '/api/v1/keepers/:name/tool-stats',
            stale_reason: 'trajectory_append_failed',
            keeper_name: 'keeper-alpha',
            trace_id: 'trace-tool-stats-gap',
            error: 'append denied',
          },
        ],
        tools: [],
        timeline: [],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperToolStats('keeper-alpha')

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/keepers/keeper-alpha/tool-stats')
    expect(result.coverage_gap_count).toBe(1)
    expect(result.coverage_gaps?.[0]).toMatchObject({
      producer: 'keeper_hooks_agentCore.post_tool_use',
      durable_store: '.masc/keepers/keeper-alpha/trajectories',
      dashboard_surface: '/api/v1/keepers/:name/tool-stats',
      stale_reason: 'trajectory_append_failed',
      trace_id: 'trace-tool-stats-gap',
      error: 'append denied',
    })
  })

  it('preserves tool-call coverage gap rows', async () => {
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(
      new Response(JSON.stringify({
        keeper: 'keeper-alpha',
        count: 0,
        source: 'tool_call_io',
        health: 'coverage_gap',
        stale_reason: 'tool_call_io_append_failed',
        coverage_gaps: [
          {
            schema: 'masc.telemetry_coverage_gap.v1',
            source: 'tool_call_io',
            producer: 'keeper_tool_call_log.append',
            durable_store: '.masc/tool_calls',
            dashboard_surface: '/api/v1/keepers/:name/tool-calls',
            stale_reason: 'tool_call_io_append_failed',
            keeper_name: 'keeper-alpha',
            trace_id: 'trace-tool-call-gap',
          },
        ],
        entries: [],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperToolCalls('keeper-alpha')

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/keepers/keeper-alpha/tool-calls')
    expect(result.coverage_gap_count).toBe(1)
    expect(result.coverage_gaps?.[0]).toMatchObject({
      producer: 'keeper_tool_call_log.append',
      durable_store: '.masc/tool_calls',
      dashboard_surface: '/api/v1/keepers/:name/tool-calls',
      stale_reason: 'tool_call_io_append_failed',
      trace_id: 'trace-tool-call-gap',
    })
  })

  it('decodes objective success, goals, and exact Agent Core occurrence', async () => {
    const fetchMock = vi.fn(() => Promise.resolve(
      new Response(JSON.stringify({
        keeper: 'keeper-alpha',
        count: 1,
        source: 'tool_call_io',
        entries: [
          {
            ts: 1,
            keeper: 'keeper-alpha',
            tool: 'keeper_context_status',
            input: {},
            output: 'ok',
            success: true,
            duration_ms: 5,
            tool_use_id: '',
            turn: 6,
            planned_index: 2,
            batch_index: 1,
            batch_size: 3,
            execution_mode: 'concurrent',
            disposition: 'deferred',
            composition_tool: 'keeper_research_pipeline',
            composition_run_id: 'run-42',
            composition_node_id: 'fetch_sources',
            composition_execution: 'async',
            parent_tool_use_id: 'outer-7',
            goal_ids: ['g-1', 'g-2'],
          },
        ],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperToolCalls('keeper-alpha')
    const entry = result.entries[0]
    expect(entry?.success).toBe(true)
    expect(entry?.goal_ids).toEqual(['g-1', 'g-2'])
    expect(entry?.tool_use_id).toBe('')
    expect(entry?.turn).toBe(6)
    expect(entry?.planned_index).toBe(2)
    expect(entry?.batch_index).toBe(1)
    expect(entry?.batch_size).toBe(3)
    expect(entry?.execution_mode).toBe('concurrent')
    expect(entry?.disposition).toBe('deferred')
    expect(entry?.composition_tool).toBe('keeper_research_pipeline')
    expect(entry?.composition_run_id).toBe('run-42')
    expect(entry?.composition_node_id).toBe('fetch_sources')
    expect(entry?.composition_execution).toBe('async')
    expect(entry?.parent_tool_use_id).toBe('outer-7')
  })

  it('decodes recorded execution evidence (runtime contract, action radius, route evidence)', async () => {
    const fetchMock = vi.fn(() => Promise.resolve(
      new Response(JSON.stringify({
        keeper: 'keeper-alpha',
        count: 1,
        source: 'tool_call_io',
        entries: [
          {
            // Field shapes mirror a recorded .masc/tool_calls row (2026-08-18),
            // anonymized. Nested nullable fields arrive as explicit nulls.
            ts: 1787024860.1,
            keeper: 'keeper-alpha',
            tool: 'keeper_time_now',
            input: {},
            output: '{"now_iso":"2026-08-18T05:00:00Z"}',
            success: true,
            duration_ms: 0.5,
            thinking_enabled: true,
            prompt_fingerprint: '464ce7b3280c24fe1cbdcd990a70db87',
            runtime_contract: {
              keeper_name: 'keeper-alpha',
              trace_id: 'trace-1',
              session_id: 'trace-1',
              generation: 1,
              keeper_turn_id: 29567,
              task_id: null,
              goal_ids: [],
              sandbox_profile: 'local',
              sandbox_root: '/sandbox/keeper-alpha/',
              sandbox_roots: ['.masc/playground/keeper-alpha/'],
              path_resolution: {
                read_implicit_cwd: false,
                read_explicit_cwd_supported: true,
                read_basis: 'Read file_path resolves against explicit cwd when cwd is provided.',
                discover_before_read: 'Inspect visible paths before Read.',
                execute_path_basis: 'Execute path arguments resolve against cwd.',
                masc_state_basis: '.masc runtime state is not a sandbox filesystem target.',
              },
              network_mode: 'inherit',
              runtime_profile: 'ollama_cloud.example-model',
            },
            action_radius: {
              tool_name: 'keeper_time_now',
              action_key: 'keeper_time_now',
              target_kind: 'tool',
              target_path: null,
              sandbox_target: 'local',
              observed_paths: [],
              success: true,
              duration_ms: 0.5,
              error: null,
            },
            route_evidence: {
              descriptor_id: 'keeper.time.now',
              capability_id: 'keeper_time_now',
              keeper_model_projection: 'internal_name',
              public_name: 'keeper_time_now',
              canonical_name: 'keeper_time_now',
              executor: 'in_process',
              backend: 'ocaml_runtime',
              sandbox: 'none',
              runtime_handler: 'tool_time_now',
              execution: 'concurrent',
              composable_output: { kind: 'json' },
              receipt_labels: {
                descriptor_id: 'keeper.time.now',
                executor: 'in_process',
                input_schema_source: 'descriptor_owned',
              },
              eval_tags: [],
              readonly: true,
              cwd_scope: null,
              polling_read: false,
              tool_name: 'keeper_time_now',
            },
          },
        ],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperToolCalls('keeper-alpha')
    const entry = result.entries[0]
    expect(entry?.thinking_enabled).toBe(true)
    expect(entry?.thinking_budget).toBeUndefined()
    expect(entry?.tool_choice).toBeUndefined()
    expect(entry?.prompt_fingerprint).toBe('464ce7b3280c24fe1cbdcd990a70db87')
    expect(entry?.runtime_contract).toMatchObject({
      keeper_name: 'keeper-alpha',
      generation: 1,
      sandbox_root: '/sandbox/keeper-alpha/',
      sandbox_roots: ['.masc/playground/keeper-alpha/'],
      network_mode: 'inherit',
      runtime_profile: 'ollama_cloud.example-model',
    })
    expect(entry?.runtime_contract?.path_resolution).toMatchObject({
      read_implicit_cwd: false,
      read_explicit_cwd_supported: true,
    })
    expect(entry?.action_radius).toMatchObject({
      action_key: 'keeper_time_now',
      target_kind: 'tool',
      observed_paths: [],
    })
    // Explicit wire nulls decode to absent, not to empty strings.
    expect(entry?.action_radius?.target_path).toBeUndefined()
    expect(entry?.action_radius?.error).toBeUndefined()
    expect(entry?.route_evidence).toMatchObject({
      descriptor_id: 'keeper.time.now',
      capability_id: 'keeper_time_now',
      executor: 'in_process',
      backend: 'ocaml_runtime',
      runtime_handler: 'tool_time_now',
      readonly: true,
    })
    expect(entry?.route_evidence?.receipt_labels).toEqual({
      descriptor_id: 'keeper.time.now',
      executor: 'in_process',
      input_schema_source: 'descriptor_owned',
    })
  })

  it('projects route_evidence.status from both wire shapes', async () => {
    const fetchMock = vi.fn(() => Promise.resolve(
      new Response(JSON.stringify({
        keeper: 'keeper-alpha',
        count: 2,
        source: 'tool_call_io',
        entries: [
          {
            ts: 1,
            keeper: 'keeper-alpha',
            tool: 'WebSearch',
            input: {},
            output: 'ok',
            success: true,
            duration_ms: 5,
            route_evidence: { descriptor_id: 'agent.search_web', status: 'ok' },
          },
          {
            ts: 2,
            keeper: 'keeper-alpha',
            tool: 'Execute',
            input: {},
            output: 'done',
            success: true,
            duration_ms: 5,
            route_evidence: { descriptor_id: 'agent.execute', status: { kind: 'exit', code: 0 } },
          },
        ],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperToolCalls('keeper-alpha')

    expect(result.entries[0]?.route_evidence?.status).toBe('ok')
    expect(result.entries[1]?.route_evidence?.status).toBe('exit 0')
  })

  it('leaves execution evidence absent on rows recorded before it was written', async () => {
    const fetchMock = vi.fn(() => Promise.resolve(
      new Response(JSON.stringify({
        keeper: 'keeper-alpha',
        count: 1,
        source: 'tool_call_io',
        entries: [
          {
            ts: 1,
            keeper: 'keeper-alpha',
            tool: 'keeper_context_status',
            input: {},
            output: 'ok',
            success: true,
            duration_ms: 5,
          },
        ],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperToolCalls('keeper-alpha')
    const entry = result.entries[0]
    expect(entry?.runtime_contract).toBeUndefined()
    expect(entry?.action_radius).toBeUndefined()
    expect(entry?.route_evidence).toBeUndefined()
    expect(entry?.thinking_enabled).toBeUndefined()
    expect(entry?.prompt_fingerprint).toBeUndefined()
  })

  it('keeps missing or malformed tool-call duration unmeasured', async () => {
    const fetchMock = vi.fn(() => Promise.resolve(
      new Response(JSON.stringify({
        keeper: 'keeper-alpha',
        count: 2,
        source: 'tool_call_io',
        entries: [
          {
            ts: 1,
            keeper: 'keeper-alpha',
            tool: 'keeper_context_status',
            input: {},
            output: 'ok',
            success: true,
          },
          {
            ts: 2,
            keeper: 'keeper-alpha',
            tool: 'masc_board_post_get',
            input: {},
            output: 'ok',
            success: true,
            duration_ms: 'not recorded',
          },
        ],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperToolCalls('keeper-alpha')

    expect(result.entries.map(entry => entry.duration_ms)).toEqual([null, null])
  })

  it('grounds turn-record selected_model / finish_reason, leaving absent fields undefined', async () => {
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(
      new Response(JSON.stringify({
        keeper: 'keeper-alpha',
        count: 2,
        skipped_rows: 0,
        source: 'turn_record',
        producer: 'keeper_agent_run.run_turn|keeper_turn_record_writer',
        durable_store: '.masc/keepers/keeper-alpha/turn-records',
        dashboard_surface: '/api/v1/keepers/:name/turn-records',
        freshness_slo_s: 300,
        live_turn_in_progress: false,
        live_turn_started_at_unix: null,
        live_turn_last_progress_at_unix: null,
        latest_ts_unix: 11,
        latest_ts_iso: '1970-01-01T00:00:11Z',
        latest_age_s: 1,
        health: 'ok',
        stale_reason: null,
        memory_os: {
          keeper: 'keeper-alpha',
          snapshot_store: '.masc/keepers/keeper-alpha.memory-current.json',
          recall_enabled: true,
          revision: 0,
          updated_at: null,
          update_source: null,
          read_errors: [],
          facts: { shown: 0, current: 0, items: [] },
          change: { added: [], removed: [], retained: 0, invalidated: [] },
        },
        entries: [
          {
            record: {
              keeper: 'keeper-alpha',
              agent_name: 'keeper-keeper-alpha-agent',
              generation: 1,
              turn_kind: 'autonomous',
              raw_trace_run_ref: null,
              trace_id: 'trace-grounded',
              absolute_turn: 7,
              turn_ref: 'trace-grounded#7',
              ts: 10,
              runtime_profile: 'local',
              selected_model: 'deepseek-v4-flash',
              finish_reason: 'completed',
              blocks: [],
              input_components: [],
              request_runtime_profile: null,
              request_body_bytes: null,
              execution_ids: [],
            },
            diff_vs_prev: null,
          },
          {
            // RFC-0233 §2.3: error turn omits selected_model/finish_reason — must
            // decode to undefined, never a fabricated "stop"/placeholder.
            record: {
              keeper: 'keeper-alpha',
              agent_name: 'keeper-keeper-alpha-agent',
              generation: 1,
              turn_kind: 'autonomous',
              raw_trace_run_ref: null,
              trace_id: 'trace-grounded',
              absolute_turn: 8,
              turn_ref: 'trace-grounded#8',
              ts: 11,
              runtime_profile: 'local',
              blocks: [],
              input_components: [],
              request_runtime_profile: null,
              request_body_bytes: null,
              execution_ids: [],
            },
            diff_vs_prev: null,
          },
        ],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperTurnRecords('keeper-alpha')

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/keepers/keeper-alpha/turn-records')
    expect(result.entries[0]?.record.selected_model).toBe('deepseek-v4-flash')
    expect(result.entries[0]?.record.finish_reason).toBe('completed')
    expect(result.entries[1]?.record.selected_model).toBeUndefined()
    expect(result.entries[1]?.record.finish_reason).toBeUndefined()
  })
})

describe('parseMemoryOsFactCategory (SSOT mirror of category_of_string)', () => {
  it('accepts only the exact tokens emitted by the closed backend sum', () => {
    const known = [
      'code_change',
      'fact',
      'preference',
      'blocker',
      'goal',
      'constraint',
      'validated_approach',
      'lesson',
    ] as const
    for (const token of known) {
      expect(parseMemoryOsFactCategory(token)).toEqual({ tag: token })
    }
    expect(parseMemoryOsFactCategory('  FACT ')).toBeNull()
    expect(parseMemoryOsFactCategory('Speculation')).toBeNull()
    expect(parseMemoryOsFactCategory('ephemeral')).toBeNull()
    expect(parseMemoryOsFactCategory('')).toBeNull()
  })
})

describe('decodeMemoryOsFact via fetchKeeperTurnRecords', () => {
  const memoryId = (digit: string) => `sha256:${digit.repeat(64)}`

  function turnRecordsPayload() {
    const first = {
      memory_id: memoryId('a'),
      claim: 'retention D0 = signup day',
      category: 'constraint',
      first_seen: 1_789_000_000,
      current: true,
      basis: { kind: 'observed' },
    }
    const second = {
      memory_id: memoryId('b'),
      claim: 'provider observation',
      category: 'fact',
      first_seen: 1_789_100_000,
      current: true,
      basis: {
        kind: 'derived',
        derivations: [{ rule_id: 'provider_rule', premise_ids: [memoryId('a')] }],
      },
    }
    return {
      keeper: 'keeper-alpha',
      count: 0,
      skipped_rows: 0,
      source: 'turn_record',
      producer: 'keeper_agent_run.run_turn|keeper_turn_record_writer',
      durable_store: '.masc/keepers/keeper-alpha/turn-records',
      dashboard_surface: '/api/v1/keepers/:name/turn-records',
      freshness_slo_s: 300,
      live_turn_in_progress: false,
      live_turn_started_at_unix: null,
      live_turn_last_progress_at_unix: null,
      latest_ts_unix: null,
      latest_ts_iso: null,
      latest_age_s: null,
      health: 'empty',
      stale_reason: 'no_entries',
      entries: [],
      memory_os: {
        keeper: 'keeper-alpha',
        snapshot_store: '.masc/keepers/keeper-alpha.memory-current.json',
        recall_enabled: true,
        revision: 1,
        updated_at: 1_789_000_000,
        update_source: {
          kind: 'librarian',
          trace_id: 't-1',
        },
        read_errors: [],
        facts: {
          shown: 2,
          current: 2,
          items: [first, second],
        },
        change: { added: [first, second], removed: [], retained: 0, invalidated: [] },
      },
    }
  }

  function stubTurnRecords(payload: unknown): void {
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(
      new Response(JSON.stringify(payload), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
    vi.stubGlobal('fetch', fetchMock)
  }

  it('decodes the exact current fact, provenance, and selection-policy contract', async () => {
    const payload = turnRecordsPayload()
    payload.memory_os.update_source.kind = 'explicit_retract'
    stubTurnRecords(payload)

    const result = await fetchKeeperTurnRecords('keeper-alpha')
    expect(result.memory_os.update_source?.kind).toBe('explicit_retract')
    const items = result.memory_os.facts.items
    expect(items).toHaveLength(2)

    const [first, second] = items
    expect(first?.claim).toBe('retention D0 = signup day')
    expect(first?.category).toEqual({ tag: 'constraint' })

    expect(second?.category).toEqual({ tag: 'fact' })
  })

  it('closes a reverse-ordered derived chain with the worklist projection', async () => {
    const payload = turnRecordsPayload()
    const indexedMemoryId = (index: number) => `sha256:${index.toString(16).padStart(64, '0')}`
    const root = {
      memory_id: indexedMemoryId(0),
      claim: 'chain root',
      category: 'fact',
      first_seen: 1_789_000_000,
      current: true,
      basis: { kind: 'observed' },
    }
    const forward: Array<Record<string, unknown>> = [root]
    let premiseId = root.memory_id
    const chainLength = 256
    for (let index = 1; index <= chainLength; index += 1) {
      const conclusion = {
        memory_id: indexedMemoryId(index),
        claim: `chain conclusion ${index}`,
        category: 'fact',
        first_seen: 1_789_000_000 + index,
        current: true,
        basis: {
          kind: 'derived',
          derivations: [{
            rule_id: `chain_rule_${index}`,
            premise_ids: [premiseId],
          }],
        },
      }
      forward.push(conclusion)
      premiseId = conclusion.memory_id
    }
    const reverseTopological = [...forward].reverse()
    Object.assign(payload.memory_os.facts, {
      shown: reverseTopological.length,
      current: reverseTopological.length,
      items: reverseTopological,
    })
    Object.assign(payload.memory_os.change, {
      added: reverseTopological,
      removed: [],
      retained: 0,
      invalidated: [],
    })
    stubTurnRecords(payload)

    const result = await fetchKeeperTurnRecords('keeper-alpha')
    expect(result.memory_os.facts.items).toHaveLength(chainLength + 1)
  })

  it('preserves exact persisted claim bytes instead of trimming them', async () => {
    const payload = turnRecordsPayload()
    payload.memory_os.facts.items[0]!.claim = '  exact claim bytes  '
    stubTurnRecords(payload)

    const result = await fetchKeeperTurnRecords('keeper-alpha')

    expect(result.memory_os.facts.items[0]?.claim).toBe('  exact claim bytes  ')
  })

  // decodeMemoryOsSnapshot closes the memory_os key set with hasExactKeys, so an
  // unexpected key is rejected before its name is ever read. One case covers the
  // arm; naming retired fields one per test asserted the same comparison N times.
  it('rejects a memory_os projection carrying any key outside the closed set', async () => {
    const payload = turnRecordsPayload()
    Object.assign(payload.memory_os, { unexpected_key: 1 })
    stubTurnRecords(payload)

    await expect(fetchKeeperTurnRecords('keeper-alpha')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects keeper identity drift across the response and Memory OS projection', async () => {
    const payload = turnRecordsPayload()
    payload.memory_os.keeper = 'other-keeper'
    stubTurnRecords(payload)

    await expect(fetchKeeperTurnRecords('keeper-alpha')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects inconsistent fact counts instead of rendering a misleading store total', async () => {
    const payload = turnRecordsPayload()
    payload.memory_os.facts.shown = 3
    stubTurnRecords(payload)

    await expect(fetchKeeperTurnRecords('keeper-alpha')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects an added fact that is not the exact current payload', async () => {
    const payload = turnRecordsPayload()
    payload.memory_os.change.added[1] = {
      ...payload.memory_os.change.added[1]!,
      claim: 'forged delta claim',
    }
    stubTurnRecords(payload)

    await expect(fetchKeeperTurnRecords('keeper-alpha')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects duplicate removed identities in one exact delta', async () => {
    const payload = turnRecordsPayload()
    const removed = {
      ...payload.memory_os.facts.items[0]!,
      category: 'lesson',
      current: false,
    }
    Object.assign(payload.memory_os.change, { removed: [removed, removed] })
    stubTurnRecords(payload)

    await expect(fetchKeeperTurnRecords('keeper-alpha')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it.each([
    'claim_kind',
    'salience',
    'uses',
    'confidence',
    'access_count',
    'last_accessed',
  ])('rejects retired fact field %s instead of silently stripping it', async (field) => {
    const payload = turnRecordsPayload()
    Object.assign(payload.memory_os.facts.items[0]!, { [field]: 'retired' })
    stubTurnRecords(payload)
    await expect(fetchKeeperTurnRecords('keeper-alpha')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it.each(['Speculation', '  FACT '])(
    'rejects non-canonical category token %s',
    async (category) => {
      const payload = turnRecordsPayload()
      payload.memory_os.facts.items[0]!.category = category
      stubTurnRecords(payload)
      await expect(fetchKeeperTurnRecords('keeper-alpha')).rejects.toThrow(
        '유효하지 않은 keeper turn record payload',
      )
    },
  )

  it('rejects an empty claim instead of rendering a blank fact', async () => {
    const payload = turnRecordsPayload()
    Object.assign(payload.memory_os.facts.items[0]!, { claim: '' })
    stubTurnRecords(payload)
    await expect(fetchKeeperTurnRecords('keeper-alpha')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it.each([
    `sha256:${'a'.repeat(63)}`,
    `sha256:${'a'.repeat(65)}`,
    `sha256:${'A'.repeat(64)}`,
    `sha256:${'a'.repeat(64)}\n`,
  ])('rejects non-canonical memory identity %s', async (memoryId) => {
    const payload = turnRecordsPayload()
    payload.memory_os.facts.items[0]!.memory_id = memoryId
    payload.memory_os.change.added[0]!.memory_id = memoryId
    stubTurnRecords(payload)
    await expect(fetchKeeperTurnRecords('keeper-alpha')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects removed fact provenance', async () => {
    const payload = turnRecordsPayload()
    Object.assign(payload.memory_os.facts.items[0]!, {
      source: { trace_id: 'retired', turn: 1 },
    })
    stubTurnRecords(payload)
    await expect(fetchKeeperTurnRecords('keeper-alpha')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects the removed first-seen ISO projection', async () => {
    const payload = turnRecordsPayload()
    Object.assign(payload.memory_os.facts.items[0]!, {
      first_seen_iso: '2026-09-10T00:26:40Z',
    })
    stubTurnRecords(payload)

    await expect(fetchKeeperTurnRecords('keeper-alpha')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects removed validity fields', async () => {
    const payload = turnRecordsPayload()
    Object.assign(payload.memory_os.facts.items[1]!, {
      valid_until: 1_789_900_000,
      valid_until_iso: '2026-09-20T10:26:40Z',
      current: true,
    })
    stubTurnRecords(payload)

    await expect(fetchKeeperTurnRecords('keeper-alpha')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

})

describe('fetchKeeperTurnTranscript', () => {
  it('encodes the turn_ref join key and decodes operator/keeper lines (RFC-0233 §7)', async () => {
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(
      new Response(JSON.stringify({
        keeper: 'keeper-alpha',
        turn_ref: 'trace-xyz#3',
        found: true,
        source: 'keeper_chat_store',
        user: [{ role: 'user', content: 'request A', ts: 10 }],
        assistant: [
          { role: 'assistant', content: 'reply A', ts: 11 },
          { role: 'assistant', content: 'failed', ts: 12, kind: 'transport_failure' },
        ],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperTurnTranscript('keeper-alpha', 'trace-xyz#3')

    // The '#' must be percent-encoded so it reaches the server as a query value.
    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      '/api/v1/keepers/keeper-alpha/turn-transcript?turn_ref=trace-xyz%233',
    )
    expect(result.found).toBe(true)
    expect(result.user[0]?.content).toBe('request A')
    expect(result.assistant[0]?.content).toBe('reply A')
    expect(result.assistant[1]?.kind).toBe('transport_failure')
  })

  it('decodes explicit absence (found=false) without fabricating lines', async () => {
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(
      new Response(JSON.stringify({
        keeper: 'keeper-alpha',
        turn_ref: 'trace-xyz#99',
        found: false,
        source: 'keeper_chat_store',
        user: [],
        assistant: [],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperTurnTranscript('keeper-alpha', 'trace-xyz#99')

    expect(result.found).toBe(false)
    expect(result.user).toEqual([])
    expect(result.assistant).toEqual([])
  })
})

describe('fetchTlcResults', () => {
  it('uses the TLC verification results endpoint', async () => {
    const rawResponse = {
      updated_at: '2026-04-30T00:00:00Z',
      results_dir: null,
      count: 0,
      entries: [],
    }
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchTlcResults()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/verification/tlc-results')
    expect(result).toEqual(rawResponse)
  })
})

function validSkillActivationProjectionFixture() {
  const reference = {
    identity: {
      source_id: 'workspace',
      package_id: 'review-skill',
      name: 'review-skill',
    },
    content_revision: 'a'.repeat(64),
  }
  const summary = {
    instruction_invocations: 1,
    skill_bodies_served: 1,
    skill_resources_served: 0,
    instruction_provider_deliveries: 1,
    instruction_official_client_handoffs: 0,
    instruction_actions_observed: 1,
    composition_invocations: 0,
    composition_provider_deliveries: 0,
    composition_official_client_handoffs: 0,
    composition_actions_observed: 0,
    invalid_transitions: 0,
  }
  return {
    status: 'available',
    keeper_name: 'keeper/one',
    summary,
    scoped_summaries: [{
      scope: {
        snapshot_revision: 'b'.repeat(64),
        turn_ref: 'trace-one#1',
        invocation_runtime_id: 'openai.codex',
        reference,
      },
      summary,
      provider_delivery_runtime_counts: [{ runtime_id: 'anthropic.claude', count: 1 }],
      official_client_handoff_runtime_counts: [],
      action_runtime_counts: [{ runtime_id: 'anthropic.claude', count: 1 }],
    }],
    ledger: {
      schema: 'masc.skill-activations/v5',
      workspace_key: 'c'.repeat(64),
      session_id: 'trace-one',
      revision: 'd'.repeat(64),
      activations: [{
        ...reference,
        snapshot_revision: 'b'.repeat(64),
        turn_ref: 'trace-one#1',
        runtime_id: 'openai.codex',
        skill_tool_use_id: 'call-skill-1',
        agent_core_turn: 0,
        invocation: {
          kind: 'instruction',
          origin: { kind: 'task_instruction', task_ids: ['task-one', 'task-two'] },
          served_content: { kind: 'skill_body', bytes: 12, sha256: 'e'.repeat(64) },
        },
        delivery: {
          boundary: { kind: 'model_response', agent_core_turn: 1 },
          runtime_id: 'anthropic.claude',
          delivered_at: '2026-08-27T00:00:01Z',
          content_bytes: 12,
          content_sha256: 'e'.repeat(64),
        },
        actions: [{
          identity: { kind: 'call_id', call_id: 'call-action-1' },
          tool_name: 'keeper_time_now',
          runtime_id: 'anthropic.claude',
          agent_core_turn: 1,
          observed_at: '2026-08-27T00:00:02Z',
        }],
        activated_at: '2026-08-27T00:00:00Z',
      }],
      transition_rejections: [{
        kind: 'delivery_order',
        skill_tool_use_id: 'call-skill-1',
        activation_turn_ref: 'trace-one#1',
        observed_turn_ref: 'trace-one#2',
        activation_agent_core_turn: 0,
        observed_agent_core_turn: 1,
        observed_at: '2026-08-27T00:00:03Z',
      }],
    },
  }
}

describe('fetchDashboardTools', () => {
  it('hard-cuts stale Skill activation schemas before rendering', () => {
    expect(() => normalizeSkillActivationProjection({
      status: 'available',
      keeper_name: 'keeper/one',
      scoped_summaries: [],
      ledger: { schema: 'masc.skill-activations/v3', activations: [] },
    })).toThrow('skill_activations schema is not v5')
  })

  it('decodes every nested field of an available v5 Skill activation projection', () => {
    const projection = validSkillActivationProjectionFixture()

    expect(normalizeSkillActivationProjection(projection)).toEqual(projection)
  })

  it('rejects a null entry inside scoped delivery runtime counts', () => {
    const projection = validSkillActivationProjectionFixture()
    Object.assign(projection.scoped_summaries[0]!, { provider_delivery_runtime_counts: [null] })

    expect(() => normalizeSkillActivationProjection(projection)).toThrow(
      'available.scoped_summaries[0].provider_delivery_runtime_counts[0] is not an object',
    )
  })

  it.each([
    {
      name: 'missing ledger session id',
      mutate: (projection: ReturnType<typeof validSkillActivationProjectionFixture>) => {
        delete (projection.ledger as Partial<typeof projection.ledger>).session_id
      },
      message: 'available.ledger.session_id must be a nonempty string',
    },
    {
      name: 'null nested summary',
      mutate: (projection: ReturnType<typeof validSkillActivationProjectionFixture>) => {
        Object.assign(projection.scoped_summaries[0]!, { summary: null })
      },
      message: 'available.scoped_summaries[0].summary is not an object',
    },
    {
      name: 'unknown action field',
      mutate: (projection: ReturnType<typeof validSkillActivationProjectionFixture>) => {
        Object.assign(projection.ledger.activations[0]!.actions[0]!, { unchecked: true })
      },
      message: 'available.ledger.activations[0].actions[0] has unexpected field unchecked',
    },
    {
      name: 'negative served bytes',
      mutate: (projection: ReturnType<typeof validSkillActivationProjectionFixture>) => {
        projection.ledger.activations[0]!.invocation.served_content.bytes = -1
      },
      message: 'available.ledger.activations[0].invocation.served_content.bytes must be a nonnegative integer',
    },
    {
      name: 'non-sha256 delivery digest',
      mutate: (projection: ReturnType<typeof validSkillActivationProjectionFixture>) => {
        projection.ledger.activations[0]!.delivery.content_sha256 = 'not-a-digest'
      },
      message: 'available.ledger.activations[0].delivery.content_sha256 must be a 64-character sha256',
    },
  ])('rejects malformed nested v4 evidence: $name', ({ mutate, message }) => {
    const projection = validSkillActivationProjectionFixture()
    mutate(projection)

    expect(() => normalizeSkillActivationProjection(projection)).toThrow(message)
  })

  it('requests an exact Keeper surface when selected', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        tool_inventory: { tools: [] },
        tool_usage: {
          total_calls: 0,
          distinct_tools_called: 0,
          top_20: [],
          never_called_count: 0,
          registered_count: 0,
        },
        effective_keeper_surface: { status: 'warming', keeper_name: 'keeper/one' },
        skill_activations: { status: 'no_session', keeper_name: 'keeper/one' },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardTools({ keeperName: 'keeper/one' })

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/tools?keeper=keeper%2Fone')
    expect(result.skill_activations).toEqual({
      status: 'no_session',
      keeper_name: 'keeper/one',
    })
  })

  it('parses the owner shutdown source without accepting source drift', () => {
    expect(parseDashboardKeeperWaitingSource('owner_shutdown')).toBe('owner_shutdown')
    expect(parseDashboardKeeperWaitingSource('chat_operation_queued')).toBe('chat_operation_queued')
    expect(parseDashboardKeeperWaitingSource('chat_operation_running')).toBe('chat_operation_running')
    expect(parseDashboardKeeperWaitingSource(' owner_shutdown ')).toBeNull()
    expect(parseDashboardKeeperWaitingSource('owner_stopping')).toBeNull()
    expect(parseDashboardKeeperWaitingSource(null)).toBeNull()
  })

  it('reads the keeper-scoped waiting inventory after auth bootstrap', async () => {
    const rawResponse = {
      keeper_count: 1,
      waiting_keeper_count: 1,
      row_count: 1,
      keepers: [{
        keeper_name: 'kidsnote',
        state: 'waiting',
        waiting_count: 1,
        waiting_on: [{
          keeper_name: 'kidsnote',
          source: 'event_queue_pending',
          waiting_on: 'schedule_due',
          next_action: 'keeper_consume_event',
        }],
      }],
    }
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperWaitingInventory('kidsnote')

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/keepers/kidsnote/waiting-inventory')
    expect(result.keepers[0]?.waiting_on[0]?.source).toBe('event_queue_pending')
  })

  it('fills missing category and tier with defaults', async () => {
    const rawResponse = {
      tool_inventory: {
        tools: [
          { name: 'tool_a' },
          { name: 'tool_b', category: 'keeper' },
          { name: 'tool_c', tier: 'essential' },
        ],
      },
      tool_usage: { total_calls: 0, distinct_tools_called: 0, top_20: [], never_called_count: 0, registered_count: 3 },
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardTools()

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    expect(devTokenMock.ensureDevToken.mock.invocationCallOrder[0]).toBeLessThan(
      fetchMock.mock.invocationCallOrder[0]!,
    )
    const tools = result.tool_inventory.tools
    expect(tools[0]).toMatchObject({ name: 'tool_a', category: 'uncategorized', tier: '(unknown tier)' })
    expect(tools[1]).toMatchObject({ name: 'tool_b', category: 'keeper', tier: '(unknown tier)' })
    expect(tools[2]).toMatchObject({ name: 'tool_c', category: 'uncategorized', tier: 'essential' })
  })

  it('totalizes a missing surfaces field to an empty array', async () => {
    // Tool-layer decoupling groundwork: the OCaml tool layer is shedding the
    // `surfaces` classification. Once the endpoint stops emitting it, the
    // normalizer must still hand consumers an array, not undefined.
    const rawResponse = {
      tool_inventory: {
        tools: [
          { name: 'tool_no_surfaces' },
          { name: 'tool_with_surfaces', surfaces: ['public_mcp'] },
        ],
      },
      tool_usage: { total_calls: 0, distinct_tools_called: 0, top_20: [], never_called_count: 0, registered_count: 2 },
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
    expect(tools[0]).toMatchObject({ name: 'tool_no_surfaces', surfaces: [] })
    expect(tools[1]).toMatchObject({ name: 'tool_with_surfaces', surfaces: ['public_mcp'] })
  })

  it('returns a new object without mutating the raw response', async () => {
    const tools = [{ name: 'tool_x' }]
    const rawResponse = {
      tool_inventory: { tools },
      tool_usage: { total_calls: 0, distinct_tools_called: 0, top_20: [], never_called_count: 0, registered_count: 1 },
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
      tool_usage: { total_calls: 0, distinct_tools_called: 0, top_20: [], never_called_count: 0, registered_count: 0 },
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

  it('preserves tool usage coverage gap rows', async () => {
    const rawResponse = {
      tool_inventory: { tools: [] },
      tool_usage: {
        total_calls: 0,
        distinct_tools_called: 0,
        top_20: [],
        never_called_count: 0,
        registered_count: 0,
        source: 'tool_usage',
        health: 'coverage_gap',
        stale_reason: 'tool_usage_append_failed',
        coverage_gap_count: 1,
        coverage_gaps: [
          {
            schema: 'masc.telemetry_coverage_gap.v1',
            source: 'tool_usage',
            producer: 'tool_usage_log',
            durable_store: '.masc/tool_usage',
            dashboard_surface: '/api/v1/dashboard/tools',
            stale_reason: 'tool_usage_append_failed',
            error: 'synthetic append failure',
          },
        ],
      },
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardTools()

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/tools')
    expect(result.tool_usage.coverage_gap_count).toBe(1)
    expect(result.tool_usage.coverage_gaps?.[0]).toMatchObject({
      producer: 'tool_usage_log',
      durable_store: '.masc/tool_usage',
      dashboard_surface: '/api/v1/dashboard/tools',
      stale_reason: 'tool_usage_append_failed',
      error: 'synthetic append failure',
    })
  })
})

describe('fetchDashboardFullHealth', () => {
  it('uses the full health path', async () => {
    const rawResponse = {
      health_detail: 'full',
      full_health_snapshot: {
        status: 'ready',
        stale_reason: null,
        last_good_available: true,
        component_timed_out: false,
      },
      overall_status: 'degraded',
      operator_action_required: true,
      operator_action_reasons: ['keeper_fleet_safety', 'keeper_event_queue'],
      schedule_runner: {
        schema: 'masc.schedule.runner_status.v1',
        status: 'ok',
        tick_in_flight: true,
        tick_count: 10,
        success_count: 8,
        failure_count: 1,
        crash_count: 0,
        last_tick_started_at: 1_700_000_000,
        last_tick_finished_at: 1_700_000_100,
        last_success_at: 1_700_000_100,
        last_error_at: null,
        last_error: null,
        last_duration_sec: 0.15,
        stale_after_sec: 60,
        last_tick_age_sec: 12.5,
        last_success_age_sec: 12.5,
        last_error_age_sec: null,
      },
      keeper_event_queue: {
        schema: 'masc.keeper_event_queue.fleet_summary.v4',
        status: 'degraded',
        operator_action_required: true,
        status_reasons: ['runnable_backlog', 'runnable_backlog_stale'],
        backlog_clean: false,
        storage_integrity: {
          status: 'ok',
          counts_complete: true,
          read_error_count: 0,
          transition_outbox_count: 0,
          operator_action_required: false,
        },
        work_liveness: {
          status: 'degraded',
          state: 'stalled',
          runnable_backlog_count: 18,
          runnable_oldest_age_seconds: 3360,
          stale_after_seconds: 300,
          operator_action_required: true,
        },
      },
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardFullHealth()

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/health?full=1')
    expect(result.health_detail).toBe('full')
    expect(result).toMatchObject({
      full_health_snapshot: {
        status: 'ready',
        stale_reason: null,
        last_good_available: true,
        component_timed_out: false,
      },
      overall_status: 'degraded',
      operator_action_required: true,
      operator_action_reasons: ['keeper_fleet_safety', 'keeper_event_queue'],
    })
    expect(result.schedule_runner).toMatchObject({
      schema: 'masc.schedule.runner_status.v1',
      status: 'ok',
      tick_in_flight: true,
      tick_count: 10,
      success_count: 8,
      failure_count: 1,
      crash_count: 0,
      last_duration_sec: 0.15,
      stale_after_sec: 60,
      last_tick_age_sec: 12.5,
      last_error_age_sec: null,
    })
    expect(result.keeper_event_queue).toMatchObject({
      status: 'degraded',
      backlog_clean: false,
      storage_integrity: { status: 'ok', counts_complete: true },
      work_liveness: {
        status: 'degraded',
        state: 'stalled',
        runnable_backlog_count: 18,
      },
    })
  })

  it('preserves the backend blocked queue liveness state', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        keeper_event_queue: {
          status: 'warning',
          operator_action_required: false,
          status_reasons: ['non_runnable_backlog'],
          backlog_clean: false,
          work_liveness: {
            status: 'warning',
            state: 'blocked',
            runnable_backlog_count: 0,
            runnable_oldest_age_seconds: null,
            stale_after_seconds: 300,
            operator_action_required: false,
          },
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    const result = await fetchDashboardFullHealth()

    expect(result.keeper_event_queue?.work_liveness?.state).toBe('blocked')
    expect(result.keeper_event_queue?.work_liveness?.runnable_backlog_count).toBe(0)
  })

  it('normalizes invalid schedule_runner values safely', async () => {
    const rawResponse = {
      health_detail: 'full',
      schedule_runner: {
        status: 'degraded',
        tick_in_flight: 'yes',
        tick_count: 'not-a-number',
        success_count: 5,
      },
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardFullHealth()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(result.health_detail).toBe('full')
    expect(result.schedule_runner).toMatchObject({
      status: 'degraded',
      tick_in_flight: false,
      tick_count: 0,
      success_count: 5,
      failure_count: 0,
      crash_count: 0,
      last_error: null,
      last_error_age_sec: null,
    })
    expect(result.schedule_runner?.last_duration_sec).toBe(null)
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

  it('preserves tool-quality coverage gap rows', async () => {
    const rawResponse = {
      generated_at: '2026-05-14T00:00:00Z',
      sampling_mode: 'window_hours',
      sample_limit: null,
      window_hours: 24,
      total: 2,
      success: 1,
      failure: 1,
      success_rate: 50,
      source: 'tool_call_io',
      health: 'coverage_gap',
      stale_reason: 'append_failed',
      coverage_gap_count: 1,
      coverage_gaps: [
        {
          schema: 'masc.telemetry_coverage_gap.v1',
          source: 'tool_call_io',
          producer: 'keeper_tool_call_log.append',
          durable_store: '.masc/tool_calls',
          dashboard_surface: '/api/v1/dashboard/tool-quality',
          stale_reason: 'append_failed',
          trace_id: 'trace-quality-gap',
          error: 'disk full',
        },
      ],
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

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/tool-quality?window_hours=24')
    expect(result.coverage_gap_count).toBe(1)
    expect(result.coverage_gaps?.[0]).toMatchObject({
      producer: 'keeper_tool_call_log.append',
      durable_store: '.masc/tool_calls',
      dashboard_surface: '/api/v1/dashboard/tool-quality',
      stale_reason: 'append_failed',
      trace_id: 'trace-quality-gap',
      error: 'disk full',
    })
  })
})

describe('fetchTelemetrySummary', () => {
  it('preserves telemetry envelope metadata', async () => {
    const rawResponse = {
      generated_at: '2026-05-14T00:00:00Z',
      generated_at_iso: '2026-05-14T00:00:00Z',
      dashboard_surface: '/api/v1/dashboard/telemetry',
      source: 'telemetry_unified',
      retention: { window_days: 7 },
      query: { source: 'tool_metric', n: 100 },
      count: 1,
      offset: 0,
      total_matching_entries: 2,
      truncated: true,
      entries: [
        {
          source: 'tool_metric',
          ts_unix: 1_775_709_000,
          tool_name: 'mcp__masc__masc_status',
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

    const result = await fetchTelemetry({ source: 'tool_metric', n: 100 })

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/telemetry?source=tool_metric&n=100')
    expect(result.dashboard_surface).toBe('/api/v1/dashboard/telemetry')
    expect(result.source).toBe('telemetry_unified')
    expect(result.retention).toMatchObject({ window_days: 7 })
    expect(result.query).toMatchObject({ source: 'tool_metric', n: 100 })
    expect(result.offset).toBe(0)
    expect(result.total_matching_entries).toBe(2)
    expect(result.truncated).toBe(true)
  })

  it('decodes dashboard cache stats details', async () => {
    const rawResponse = {
      entries: 3,
      fresh: 1,
      stale: 1,
      expired: 0,
      ready_fresh: 1,
      ready_stale: 1,
      computing: 1,
      max_entries: 500,
      hits_total: 8,
      misses_total: 2,
      hit_ratio: 0.8,
      timeout_circuit_open: 0,
      timeout_circuit_tracked: 1,
      entries_truncated_to: 50,
      entry_details: [
        {
          key: 'telemetry:/Users/dancer/me/.masc:src=tool_metric:n=100',
          kind: 'fresh',
          ttl_remaining_ms: 750,
          stale_remaining_ms: 10_000,
        },
        {
          key: 'health:full',
          kind: 'computing',
          computing_for_ms: 12,
          has_stale_fallback: true,
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

    const result = await fetchDashboardCacheStats()

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/cache-stats')
    expect(result.hit_ratio).toBe(0.8)
    expect(result.entry_details[0]).toMatchObject({
      key: 'telemetry:/Users/dancer/me/.masc:src=tool_metric:n=100',
      kind: 'fresh',
      ttl_remaining_ms: 750,
      stale_remaining_ms: 10_000,
    })
    expect(result.entry_details[1]).toMatchObject({
      kind: 'computing',
      computing_for_ms: 12,
      has_stale_fallback: true,
    })
  })

  it('preserves per-source coverage gap rows', async () => {
    const rawResponse = {
      generated_at: '2026-05-14T00:00:00Z',
      total_entries: 0,
      sources: [
        {
          source: 'agent_event',
          entry_count: 0,
          health: 'coverage_gap',
          stale_reason: 'append_failed',
          coverage_gaps: [
            {
              schema: 'masc.telemetry_coverage_gap.v1',
              source: 'agent_event',
              producer: 'telemetry_eio',
              durable_store: '.masc/telemetry',
              dashboard_surface: '/api/v1/dashboard/telemetry/summary',
              stale_reason: 'append_failed',
              error: 'disk full',
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

    const result = await fetchTelemetrySummary()

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/telemetry/summary')
    expect(result.sources[0]?.coverage_gap_count).toBe(1)
    expect(result.sources[0]?.coverage_gaps?.[0]).toMatchObject({
      producer: 'telemetry_eio',
      durable_store: '.masc/telemetry',
      dashboard_surface: '/api/v1/dashboard/telemetry/summary',
      stale_reason: 'append_failed',
      error: 'disk full',
    })
  })
})

describe('fetchDashboardMemory', () => {
  it('requests dashboard board rows for the current actor', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ posts: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await fetchDashboardMemory('hot')

    const [url] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/dashboard/board?')
    expect(url).toContain('voter=')
  })
})

describe('fetchDashboardGate', () => {
  const gateHitl = {
    gate_mode: { mode: 'manual', configured: true, state: 'ready' },
    external_gate_mode: { mode: 'manual', configured: false, state: 'ready' },
    judge_lane: { status: 'available', lane_id: 'gate-judge', slots: ['judge'] },
  } as const

  const emptyResolvedHistory = {
    recent_resolved: [],
    recent_resolved_page: {
      returned: 0,
      matched: 0,
      limit: 20,
      window_minutes: 1440,
      truncated: false,
      scan_exhausted: false,
    },
    recent_resolved_state: { state: 'ready' },
  } as const

  function currentResolvedRow(overrides: Record<string, unknown> = {}) {
    const decisionKind = overrides.decision_kind === 'reject' ? 'reject' : 'approve'
    return {
      id: 'appr-current',
      event: 'resolved',
      keeper_name: 'keeper-a',
      tool_name: 'fs_write',
      decision: decisionKind === 'approve' ? 'approve' : 'reject:operator denied',
      decision_kind: decisionKind,
      decision_reason: decisionKind === 'approve' ? null : 'operator denied',
      resolved_at: 1_782_522_123,
      turn_id: null,
      task_id: null,
      goal_id: null,
      actor: 'operator',
      decision_source: 'human_operator',
      summary_status: 'not_requested',
      exact_attempt: { state: 'unbound' },
      ...overrides,
    }
  }

  it('requests a forced Gate snapshot when asked', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        ...emptyResolvedHistory,
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await fetchDashboardGate({ force: true })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/gate?force=1')
  })

  it('keeps the Gate snapshot when a resolved row carries an unknown key', async () => {
    // #31695: an exact-key gate on this read-only projection turned one
    // unrecognized field into a blank open-Gate count.  A key the client does
    // not know yet is what a rolling deploy looks like; the row must still
    // decode.
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        recent_resolved: [
          { ...currentResolvedRow({ id: 'appr-future' }), field_this_client_does_not_know: ['x'] },
        ],
        recent_resolved_page: {
          returned: 1,
          matched: 1,
          limit: 20,
          window_minutes: 1440,
          truncated: false,
          scan_exhausted: false,
        },
        recent_resolved_state: { state: 'ready' },
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardGate()

    expect(result.recent_resolved).toHaveLength(1)
    expect(result.recent_resolved?.[0]?.id).toBe('appr-future')
    expect(result.recent_resolved_violations).toEqual([])
  })

  it('salvages the valid resolved rows and reports the undecodable one', async () => {
    // #26094 taught approval_queue this; recent_resolved threw the whole
    // snapshot away instead.  One bad row must cost one row, not the screen.
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        recent_resolved: [
          currentResolvedRow({ id: 'appr-good' }),
          currentResolvedRow({ id: 'appr-bad', keeper_name: 'keeper-b', tool_name: 'fs_write', decision_source: 'not_a_source' }),
        ],
        recent_resolved_page: {
          returned: 2,
          matched: 2,
          limit: 20,
          window_minutes: 1440,
          truncated: false,
          scan_exhausted: false,
        },
        recent_resolved_state: { state: 'ready' },
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardGate()

    expect(result.recent_resolved?.map(row => row.id)).toEqual(['appr-good'])
    expect(result.recent_resolved_violations).toEqual([
      { index: 1, id: 'appr-bad', keeper_name: 'keeper-b', tool_name: 'fs_write' },
    ])
  })

  it('normalizes resolved approval history separately from pending queue items', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        recent_resolved: [
          currentResolvedRow({
            id: 'appr-done',
            keeper_name: 'keeper-a',
            tool_name: 'fs_write',
            decision: 'reject:operator denied',
            decision_kind: 'reject',
            decision_reason: 'operator denied',
            resolved_at: 1_782_522_123,
          }),
          currentResolvedRow({
            id: 'appr-approved',
            keeper_name: 'keeper-a',
            tool_name: 'shell_exec',
            decision: 'approve',
            decision_kind: 'approve',
            actor: null,
            resolved_at: 1_782_522_183,
          }),
        ],
        recent_resolved_page: {
          returned: 2,
          matched: 2,
          limit: 20,
          window_minutes: 1440,
          truncated: false,
          scan_exhausted: false,
        },
        recent_resolved_state: { state: 'ready' },
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardGate()

    expect(result.recent_resolved).toEqual([
      expect.objectContaining({
        id: 'appr-done',
        keeper_name: 'keeper-a',
        tool_name: 'fs_write',
        decision: 'reject',
        decision_raw: 'reject:operator denied',
        decision_reason: 'operator denied',
        resolved_at: '2026-06-27T01:02:03.000Z',
      }),
      expect.objectContaining({
        id: 'appr-approved',
        keeper_name: 'keeper-a',
        tool_name: 'shell_exec',
        decision: 'approve',
        decision_raw: 'approve',
        decision_reason: null,
        actor: null,
        resolved_at: '2026-06-27T01:03:03.000Z',
      }),
    ])
    expect(result.recent_resolved?.[0]).not.toHaveProperty('requested_at')
  })

  it('derives the immutable Always rule timestamp from its canonical numeric field', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        ...emptyResolvedHistory,
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        approval_rules: [{
          id: 'rule-1',
          keeper_name: 'keeper-a',
          tool_name: 'fs_write',
          request_fingerprint: 'a'.repeat(64),
          created_at: 1_783_123_200,
          created_by: 'operator',
          source_approval_id: 'appr-1',
          expires_at: null,
        }],
        hitl: gateHitl,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardGate()

    expect(result.approval_rules).toEqual([
      expect.objectContaining({
        request_fingerprint: 'a'.repeat(64),
        created_at: 1_783_123_200,
        expires_at: null,
      }),
    ])
  })

  it('decodes per-keeper Gate settings', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        ...emptyResolvedHistory,
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [
          {
            keeper_name: 'kidsnote',
            mode: 'manual',
            updated_by: 'vincent',
            updated_at: '2026-08-27T05:00:00Z',
          },
        ],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [
          {
            keeper_name: 'kidsnote',
            lane_id: 'hitl_auto_judge',
            slot_id: 'glm-coding.glm-5-turbo',
            updated_by: 'vincent',
            updated_at: '2026-08-27T05:00:00Z',
          },
        ],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    const result = await fetchDashboardGate()

    expect(result.keeper_modes).toEqual([
      {
        keeper_name: 'kidsnote',
        mode: 'manual',
        updated_by: 'vincent',
        updated_at: '2026-08-27T05:00:00Z',
      },
    ])
    expect(result.keeper_exact_lanes[0]).toMatchObject({
      lane_id: 'hitl_auto_judge',
      slot_id: 'glm-coding.glm-5-turbo',
    })
  })

  it('rejects the retired Judge-only preference shape', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        ...emptyResolvedHistory,
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_judges: [],
        keeper_judges_state: { state: 'ready' },
        hitl: gateHitl,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    await expect(fetchDashboardGate()).rejects.toThrow(/keeper_exact_lanes_state/)
  })

  it('requires lane identity on every exact-lane preference', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        ...emptyResolvedHistory,
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [{
          keeper_name: 'kidsnote',
          slot_id: 'glm-coding.glm-5-turbo',
          updated_by: 'vincent',
          updated_at: '2026-08-27T05:00:00Z',
        }],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    await expect(fetchDashboardGate()).rejects.toThrow(
      /keeper_exact_lanes contains an invalid row/,
    )
  })

  it('refuses per-keeper rows alongside an unavailable state', async () => {
    // Unavailable means the file could not be read, so there was nothing to
    // parse. Rows beside it would be two sources disagreeing about the same
    // question, and the looser one would win by being the one on screen.
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        ...emptyResolvedHistory,
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [
          {
            keeper_name: 'kidsnote',
            mode: 'manual',
            updated_by: 'vincent',
            updated_at: '2026-08-27T05:00:00Z',
          },
        ],
        keeper_modes_state: { state: 'unavailable', error: 'overrides unreadable' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    await expect(fetchDashboardGate()).rejects.toThrow(/unavailable keeper_modes must be empty/)
  })

  it('refuses a per-keeper mode the Gate does not define', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        ...emptyResolvedHistory,
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [
          {
            keeper_name: 'kidsnote',
            mode: 'ask_nicely',
            updated_by: 'vincent',
            updated_at: '2026-08-27T05:00:00Z',
          },
        ],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    await expect(fetchDashboardGate()).rejects.toThrow(/keeper_modes contains an invalid row/)
  })

  it('preserves approval rule-store unavailability', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        ...emptyResolvedHistory,
        approval_rules: [],
        approval_rules_state: {
          state: 'unavailable',
          error: 'approval rules store unreadable',
        },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    const result = await fetchDashboardGate()

    expect(result.approval_rules_state).toEqual({
      state: 'unavailable',
      error: 'approval rules store unreadable',
    })
  })

  it('rejects a malformed approval rule instead of dropping it', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        ...emptyResolvedHistory,
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        approval_rules: [{
          id: 'rule-invalid',
          keeper_name: 'keeper-a',
          tool_name: 'fs_write',
          request_fingerprint: 'not-a-sha256',
          created_at: 1_783_123_200,
          created_by: null,
          source_approval_id: null,
          expires_at: null,
        }],
        hitl: gateHitl,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    await expect(fetchDashboardGate()).rejects.toThrow('approval_rules contains an invalid rule')
  })

  // Rows, bounds, and availability form one exact current snapshot contract.
  function gateResponseWithPage(page: unknown) {
    return vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        recent_resolved: [],
        recent_resolved_page: page,
        recent_resolved_state: { state: 'ready' },
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
  }

  it('normalizes a complete resolved-history page', async () => {
    vi.stubGlobal('fetch', gateResponseWithPage({
      returned: 0,
      matched: 0,
      limit: 20,
      window_minutes: 1440,
      truncated: false,
      scan_exhausted: false,
    }))

    const result = await fetchDashboardGate()

    expect(result.recent_resolved_page).toEqual({
      returned: 0,
      matched: 0,
      limit: 20,
      window_minutes: 1440,
      truncated: false,
      scan_exhausted: false,
    })
  })

  it('rejects a partial resolved-history page', async () => {
    vi.stubGlobal('fetch', gateResponseWithPage({
      returned: 20,
      matched: 149,
      limit: 20,
      // window_minutes and the two flags are missing: an older server, or drift.
    }))

    await expect(fetchDashboardGate()).rejects.toThrow('ready recent_resolved_page is invalid')
  })

  it('rejects an absent resolved-history page', async () => {
    vi.stubGlobal('fetch', gateResponseWithPage(undefined))

    await expect(fetchDashboardGate()).rejects.toThrow('ready recent_resolved_page is invalid')
  })

  it('rejects a resolved-history page with a nonsensical window', async () => {
    vi.stubGlobal('fetch', gateResponseWithPage({
      returned: 1,
      matched: 1,
      limit: 20,
      window_minutes: 0,
      truncated: false,
      scan_exhausted: false,
    }))

    await expect(fetchDashboardGate()).rejects.toThrow('ready recent_resolved_page is invalid')
  })

  it('preserves resolved-history storage unavailability', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        recent_resolved: null,
        recent_resolved_page: null,
        recent_resolved_state: {
          state: 'unavailable',
          stage: 'list_recent_resolved',
          error: 'audit JSONL unreadable',
        },
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    const result = await fetchDashboardGate()

    expect(result.recent_resolved).toBeNull()
    expect(result.recent_resolved_state).toEqual({
      state: 'unavailable',
      stage: 'list_recent_resolved',
      error: 'audit JSONL unreadable',
    })
  })

  it('preserves typed unavailable queue state without fabricating an empty ready queue', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: null,
        approval_queue_state: {
          state: 'unavailable',
          code: 'reset_required',
          title: 'Gate durable queue unavailable · runtime reset required',
          operator_detail: 'pending store requires reset',
          severity: 'bad',
          icon: '!',
        },
        ...emptyResolvedHistory,
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardGate()

    expect(result.approval_queue).toBeNull()
    expect(result.approval_queue_state).toEqual({
      state: 'unavailable',
      code: 'reset_required',
      title: 'Gate durable queue unavailable · runtime reset required',
      operator_detail: 'pending store requires reset',
      severity: 'bad',
      icon: '!',
    })
  })

  it('does not retry structured computation timeouts', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        error: 'computation_timeout',
        message: 'Dashboard Gate timed out after 30s',
      }), {
        status: 504,
        statusText: 'Gateway Timeout',
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(fetchDashboardGate()).rejects.toMatchObject({
      name: 'ApiRequestError',
      status: 504,
      errorCode: 'computation_timeout',
    })
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('quarantines a contract-violating queue row instead of blanking the queue (#26094)', async () => {
    const validItem = {
      id: 'appr-valid',
      keeper_name: 'keeper-a',
      tool_name: 'shell_exec',
      input_hash: 'a'.repeat(64),
      sequence: 3,
      requested_at: 1_782_522_100,
      waiting_s: 30,
      turn_id: null,
      task_id: null,
      goal_id: null,
      goal_ids: [],
      summary_status: 'not_requested',
      exact_attempt: { state: 'unbound' },
      summary_attempt_disposition: { code: 'ready' },
    }
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [
          validItem,
          {
            id: 'appr-drifted',
            keeper_name: 'keeper-b',
            tool_name: 'fs_write',
            input_hash: 'b'.repeat(64),
            sequence: 4,
            summary_status: { status: 'failed', reason: 'x', retryable: true },
            exact_attempt: { state: 'unbound' },
            summary_attempt_disposition: { code: 'ready' },
          },
        ],
        approval_queue_state: { state: 'ready' },
        ...emptyResolvedHistory,
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    const result = await fetchDashboardGate()

    expect(result.approval_queue).toHaveLength(1)
    expect(result.approval_queue?.[0]?.id).toBe('appr-valid')
    expect(result.approval_queue_violations).toEqual([
      { index: 1, id: 'appr-drifted', keeper_name: 'keeper-b', tool_name: 'fs_write' },
    ])
  })

  it('carries judge evidence on resolved rows', async () => {
    const judgeSummary = {
      summary_version: 2,
      generated_at: 1_782_522_120,
      model_run_id: 'run-1',
      context_summary: 'Keeper requested a read-only listing.',
      key_questions: ['Is the path inside the sandbox?'],
      judgment: 'approve',
      rationale: 'Read-only and scoped.',
    }
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        approval_queue_state: { state: 'ready' },
        recent_resolved: [
          currentResolvedRow({
            id: 'appr-judged',
            keeper_name: 'keeper-a',
            tool_name: 'shell_exec',
            decision: 'approve',
            decision_kind: 'approve',
            decision_source: 'auto_judge',
            resolved_at: 1_782_522_183,
            summary_status: { status: 'available', summary: judgeSummary },
            exact_attempt: {
              state: 'bound',
              approval_id: 'appr-judged',
              input_hash: 'a'.repeat(64),
              sequence: 7,
              slot_id: 'glm-coding.glm-5-turbo',
              call_id: 'call-1',
              plan_fingerprint: 'plan-1',
              request_body_sha256: 'c'.repeat(64),
              status: 'completed',
              quarantine_cause: null,
            },
          }),
        ],
        recent_resolved_page: {
          returned: 1,
          matched: 1,
          limit: 20,
          window_minutes: 1440,
          truncated: false,
          scan_exhausted: false,
        },
        recent_resolved_state: { state: 'ready' },
        approval_rules: [],
        approval_rules_state: { state: 'ready' },
        keeper_modes: [],
        keeper_modes_state: { state: 'ready' },
        keeper_exact_lanes: [],
        keeper_exact_lanes_state: { state: 'ready' },
        hitl: gateHitl,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    const result = await fetchDashboardGate()

    const judged = result.recent_resolved?.find(item => item.id === 'appr-judged')
    expect(judged?.summary_status?.status).toBe('available')
    expect(
      judged?.summary_status?.status === 'available'
        ? judged.summary_status.summary.context_summary
        : null,
    ).toBe('Keeper requested a read-only listing.')
    expect(
      judged?.exact_attempt?.state === 'bound' ? judged.exact_attempt.slot_id : null,
    ).toBe('glm-coding.glm-5-turbo')
  })

  it('parses the closed judge_lane variant and rejects shapes outside it', async () => {
    const snapshot = (judgeLane: unknown) => new Response(JSON.stringify({
      approval_queue: [],
      approval_queue_state: { state: 'ready' },
      ...emptyResolvedHistory,
      approval_rules: [],
      approval_rules_state: { state: 'ready' },
      keeper_modes: [],
      keeper_modes_state: { state: 'ready' },
      keeper_exact_lanes: [],
      keeper_exact_lanes_state: { state: 'ready' },
      hitl: {
        gate_mode: { mode: 'auto_judge', configured: false, state: 'ready' },
        external_gate_mode: { mode: 'manual', configured: false, state: 'ready' },
        judge_lane: judgeLane,
      },
    }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })

    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(snapshot({
      status: 'available',
      lane_id: 'hitl_auto_judge',
      slots: ['glm-coding.glm-5-turbo', 'ollama_cloud.deepseek-v4-flash'],
    })))
    expect((await fetchDashboardGate()).hitl?.judge_lane).toEqual({
      status: 'available',
      lane_id: 'hitl_auto_judge',
      slots: ['glm-coding.glm-5-turbo', 'ollama_cloud.deepseek-v4-flash'],
    })

    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(snapshot({
      status: 'unavailable',
      lane_id: 'hitl_auto_judge',
      reason: 'registry_not_published',
    })))
    expect((await fetchDashboardGate()).hitl?.judge_lane).toEqual({
      status: 'unavailable',
      lane_id: 'hitl_auto_judge',
      reason: 'registry_not_published',
    })

    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(snapshot({
      status: 'available',
      lane_id: 'hitl_auto_judge',
      slots: [],
    })))
    await expect(fetchDashboardGate()).rejects.toThrow('hitl.judge_lane.slots is invalid')
  })
})

describe('Gate mutation audit receipts', () => {
  it('keeps a committed resolution successful while decoding failed audit writes', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        id: 'appr-audit',
        decision: 'approve',
        rule_id: null,
        audit_receipts: [{
          event: 'resolved',
          recorded: false,
          stage: 'append',
          detail: 'audit append unavailable',
        }],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    await expect(resolveGateApproval('appr-audit', {
      decision: 'approve',
      rememberRule: false,
    })).resolves.toMatchObject({
      ok: true,
      audit_receipts: [{ recorded: false, stage: 'append' }],
    })
  })

  it('rejects a committed resolution response that hides its audit receipt', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        id: 'appr-audit',
        decision: 'approve',
        rule_id: null,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    await expect(resolveGateApproval('appr-audit', {
      decision: 'approve',
      rememberRule: false,
    })).rejects.toMatchObject({
      name: 'ApiRequestError',
      errorCode: 'protocol_drift',
    })
  })

  it('decodes a committed rule deletion with its exact failed audit stage', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        id: 'rule-audit',
        audit: {
          event: 'rule_deleted',
          recorded: false,
          stage: 'store_create',
          detail: 'audit store unavailable',
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    await expect(deleteGateApprovalRule('rule-audit')).resolves.toMatchObject({
      ok: true,
      audit: { recorded: false, stage: 'store_create' },
    })
  })

  it('rejects a resolution receipt for an unrelated mutation', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        id: 'appr-audit',
        decision: 'approve',
        rule_id: null,
        audit_receipts: [{ event: 'pending', recorded: true }],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    await expect(resolveGateApproval('appr-audit', {
      decision: 'approve',
      rememberRule: false,
    })).rejects.toMatchObject({ errorCode: 'protocol_drift' })
  })

  it('rejects a rule deletion receipt for an unrelated mutation', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        id: 'rule-audit',
        audit: { event: 'resolved', recorded: true },
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    await expect(deleteGateApprovalRule('rule-audit'))
      .rejects.toMatchObject({ errorCode: 'protocol_drift' })
  })

  it('preserves a recorded resolution receipt with cleanup failure evidence', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        id: 'appr-cleanup',
        decision: 'approve',
        rule_id: null,
        audit_receipts: [{
          event: 'resolved',
          recorded: true,
          cleanup_failure: {
            stage: 'append_cleanup',
            detail: 'descriptor cleanup failed',
          },
        }],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    await expect(resolveGateApproval('appr-cleanup', {
      decision: 'approve',
      rememberRule: false,
    })).resolves.toMatchObject({
      audit_receipts: [{
        recorded: true,
        cleanup_failure: { stage: 'append_cleanup' },
      }],
    })
  })
})

describe('setGateMode', () => {
  const completedResponse = {
    ok: true,
    mode: 'auto_judge',
    previous_mode: 'manual',
    actor: 'operator',
    changed_at: '2026-07-12T00:00:00Z',
    recovery_status: 'completed',
    recovery_error: null,
    started: 1,
    queued: 1,
    recovery_failure_count: 0,
    recovery_failures: [],
  } as const

  it('posts the exact non-hierarchical Gate mode contract', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(completedResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await setGateMode('auto_judge')

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/gate/mode')
    const init = fetchMock.mock.calls[0]?.[1] as RequestInit
    expect(init.method).toBe('POST')
    expect(JSON.parse(String(init.body))).toEqual({ mode: 'auto_judge' })
    expect(result).toMatchObject({
      recovery_status: 'completed',
      recovery_error: null,
      started: 1,
      queued: 1,
    })
  })

  it.each([
    {
      label: 'partial owner recovery',
      requestedMode: 'auto_judge' as const,
      response: {
        ...completedResponse,
        recovery_status: 'partial',
        recovery_failure_count: 1,
        recovery_failures: [{
          keeper_name: 'keeper-a',
          approval_id: 'approval-a',
          operator_detail: 'worker unavailable',
        }],
      },
    },
    {
      label: 'failed recovery',
      requestedMode: 'auto_judge' as const,
      response: {
        ...completedResponse,
        recovery_status: 'failed',
        recovery_error: 'judge worker unavailable',
        started: 0,
        queued: 0,
      },
    },
    {
      label: 'non-auto mode without recovery',
      requestedMode: 'manual' as const,
      response: {
        ...completedResponse,
        mode: 'manual',
        recovery_status: 'not_requested',
        recovery_error: null,
        started: 0,
        queued: 0,
        replaced_read_error: 'replaced invalid persisted mode',
      },
    },
  ])('decodes $label', async ({ requestedMode, response }) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify(response), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    await expect(setGateMode(requestedMode)).resolves.toMatchObject(response)
  })

  it.each([
    ['non-object', null],
    ['unsuccessful envelope', { ...completedResponse, ok: false }],
    ['requested mode mismatch', { ...completedResponse, mode: 'manual' }],
    ['unknown recovery status', { ...completedResponse, recovery_status: 'pending' }],
    ['completed recovery with error', { ...completedResponse, recovery_error: 'unexpected' }],
    ['failed recovery without error', {
      ...completedResponse,
      recovery_status: 'failed',
      started: 0,
      queued: 0,
    }],
    ['partial recovery without owner failure', {
      ...completedResponse,
      recovery_status: 'partial',
    }],
    ['owner failure count mismatch', {
      ...completedResponse,
      recovery_status: 'partial',
      recovery_failure_count: 1,
    }],
    ['owner failure with unknown field', {
      ...completedResponse,
      recovery_status: 'partial',
      recovery_failure_count: 1,
      recovery_failures: [{
        keeper_name: 'keeper-a',
        approval_id: null,
        operator_detail: 'queue unavailable',
        extra: true,
      }],
    }],
    ['negative count', { ...completedResponse, started: -1 }],
    ['non-zero not-requested outcome', {
      ...completedResponse,
      recovery_status: 'not_requested',
    }],
    ['unknown field', { ...completedResponse, legacy_status: 'ok' }],
  ])('rejects protocol drift: %s', async (_label, response) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify(response), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    await expect(setGateMode('auto_judge')).rejects.toMatchObject({
      name: 'ApiRequestError',
      errorCode: 'protocol_drift',
    })
  })
})

describe('dashboard goals decoding', () => {
  it('retains direct keeper references without projecting blocker metadata', async () => {
    const rawResponse = {
      approval_queue_state: { state: 'ready' },
      tree: [
        makeRawGoalNode({
          latest_keeper_ref: 'keeper-sangsu',
          latest_turn_ref: 42,
        }),
      ],
      summary: {},
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardGoalsTree()

    expect(result.tree[0]).toMatchObject({
      latest_keeper_ref: 'keeper-sangsu',
      latest_turn_ref: 42,
    })
  })

  it('decodes explicit phase counts separately from active status', async () => {
    const rawResponse = {
      approval_queue_state: { state: 'ready' },
      tree: [makeRawGoalNode()],
      summary: {
        total_goals: 3,
        phase_counts: { executing: 1, blocked: 1, completed: 1 },
      },
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardGoalsTree()

    expect(result.summary.phase_counts).toEqual({ executing: 1, blocked: 1, completed: 1 })
  })

  it('retains keeper trust summary and latest event on goal detail payloads', async () => {
    const rawResponse = {
      approval_queue_state: { state: 'ready' },
      goal: makeRawGoalNode(),
      linked_tasks: [],
      linked_keepers: [
        {
          name: 'keeper-sangsu',
          agent_name: 'sangsu',
          current_task_id: 'task-1',
          sandbox_profile: 'docker',
          network_mode: 'none',
          runtime_id: 'keeper_unified',
          runtime_outcome: 'passed_to_next_model',
          latest_execution_outcome: 'completed',
          latest_execution_at: '2026-04-23T00:10:00Z',
          latest_receipt: { outcome: 'completed' },
          runtime_trust: {
            disposition: 'Blocked',
            disposition_reason: 'approval_waiting',
            needs_attention: true,
            attention_reason: 'approval_pending',
            next_human_action: 'resolve_approval',
            approval: {
              state: 'pending',
              summary: '1 approval request is waiting for an operator.',
              pending_count: 1,
              pending_first: {
                id: 'approval-1',
                tool_name: 'Execute',
                task_id: 'task-1',
                blocker_class: 'blocked_before_worktree',
              },
              latest_event_at: '2026-04-23T00:09:30Z',
            },
            execution: {
              tools_used: ['keeper_task_claim'],
              provider_attempt_count: 2,
              provider_fallback_applied: true,
              provider_selected_model: 'runtime-lane',
              runtime_outcome: 'fallback_exhausted',
              sandbox_summary: 'docker / none',
              sandbox_root: '/tmp/keeper-sandbox',
              completion_observation_summary: 'not_observed',
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
              trace_id: 'trace-approval-42',
            },
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
      ],
      approvals: [],
      execution_receipts: [],
      timeline: [],
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardGoalDetail('goal-1')

    expect(result.linked_keepers[0]).toMatchObject({
      runtime_trust: {
        disposition: 'Blocked',
        disposition_reason: 'approval_waiting',
        needs_attention: true,
        attention_reason: 'approval_pending',
        next_human_action: 'resolve_approval',
        approval_state: {
          state: 'pending',
          summary: '1 approval request is waiting for an operator.',
          pending_count: 1,
          pending_first: {
            id: 'approval-1',
            tool_name: 'Execute',
            task_id: 'task-1',
            blocker_class: 'blocked_before_worktree',
          },
          latest_event_at: '2026-04-23T00:09:30Z',
        },
        execution_summary: {
          provider_attempt_count: 2,
          provider_fallback_applied: true,
          provider_selected_model: 'runtime-lane',
          runtime_outcome: 'fallback_exhausted',
          sandbox_summary: 'docker / none',
          sandbox_root: '/tmp/keeper-sandbox',
          completion_observation_summary: 'not_observed',
          latest_receipt_at: '2026-04-23T00:10:00Z',
        },
        latest_causal_event: {
          kind: 'approval_pending',
          keeper_turn_id: 42,
          title: 'Approval pending',
          trace_id: 'trace-approval-42',
        },
      },
      latest_causal_event: {
        kind: 'approval_pending',
        summary: 'Waiting for operator approval before resuming.',
        next_human_action: 'resolve_approval',
      },
    })
  })

  it('accepts raw runtime_trust approval/execution keys on goal detail payloads', async () => {
    const rawResponse = {
      approval_queue_state: { state: 'ready' },
      goal: makeRawGoalNode(),
      linked_tasks: [],
      linked_keepers: [
        {
          name: 'keeper-sangsu',
          agent_name: 'sangsu',
          current_task_id: null,
          sandbox_profile: 'docker',
          network_mode: 'none',
          runtime_id: 'keeper_unified',
          runtime_outcome: null,
          latest_execution_outcome: null,
          latest_execution_at: null,
          latest_receipt: null,
          runtime_trust: {
            disposition: 'Pass',
            approval: {
              state: 'always_allowed',
              summary: 'Exact Always rule allowed the request.',
              pending_count: 0,
            },
            execution: {
              sandbox_summary: 'docker / none',
              completion_observation_summary: 'tool_execution_observed',
              latest_receipt_at: '2026-04-23T00:10:00Z',
            },
          },
          latest_causal_event: null,
        },
      ],
      approvals: [],
      execution_receipts: [],
      timeline: [],
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardGoalDetail('goal-1')

    expect(result.linked_keepers[0]?.runtime_trust).toMatchObject({
      disposition: 'Pass',
      approval_state: {
        state: 'always_allowed',
        summary: 'Exact Always rule allowed the request.',
        pending_count: 0,
      },
      execution_summary: {
        sandbox_summary: 'docker / none',
        completion_observation_summary: 'tool_execution_observed',
        latest_receipt_at: '2026-04-23T00:10:00Z',
      },
    })
  })
})

describe('fetchKeeperConfig', () => {
  const manifestRevision = { state: 'sha256', value: 'a'.repeat(64) } as const
  const configRevision = {
    manifest: manifestRevision,
    runtime_assignment: { state: 'runtime_config_missing' as const },
  } as const

  it('normalizes singleton and boolean string fields with a canonical context override', async () => {
    const rawResponse = {
      name: 'keeper-sangsu',
      config_revision: configRevision,
      autoboot_enabled: 'false',
      max_context_override: 64_000,
      sandbox_profile: 'docker',
      network_mode: 'none',
      keeper_last_error: 'sandbox docker exec failed',
      sandbox_roots: '/tmp/workspace',
      prompt: {
        instructions: 'Prefer direct remediation',
        system_prompt_blocks: {
          constitution: { key: 'keeper.constitution', source: 'file', text: 'constitution text' },
          world: { key: 'keeper.world', source: 'override', text: 'world text' },
          capabilities: { key: 'keeper.capabilities', source: 'file', text: 'capabilities text' },
        },
        effective_system_prompt: 'full prompt',
        assembled_system_prompt: 'assembled prompt',
        unified_user_message_preview: 'world state',
      },
      execution: {
        models: 'llama:test-balanced',
        active_model: 'llama:test-balanced',
        verify: 'true',
        selected_runtime_id: 'keeper_unified',
        selected_runtime_canonical: 'keeper_unified',
        runtime_options: ['keeper_unified', 'runpod_mtp.qwen36-35b-a3b-mtp'],
      },
      proactive: {
        enabled: 'true',
      },
      skills: {
        names: ['ocaml-coding', 'proof-harness'],
      },
      hooks: {
        scope: 'keeper_runtime_composite',
        slots: {
          pre_tool_use: {
            active: 'true',
            source: 'keeper_hooks_agentCore',
            features: 'tool_start_timing',
          },
        },
      },
      runtime: {
        paused: 'false',
        registered: 'true',
        keepalive_running: 'true',
        registry_state: 'running',
        fiber_health: 'healthy',
        runtime_blocker_class: 'stale_termination_storm',
        runtime_blocker_summary: 'Fleet batch paused after stale termination storm.',
      },
      runtime_trust: {
        disposition: 'Pass',
        disposition_reason: 'healthy',
        needs_attention: false,
      },
      workspace: {
        mention_targets: 'sangsu',
        bound_workspace_ids: 'default',
      },
      sources: {
        live_meta_path: '/tmp/.masc/keepers/keeper-sangsu/live.json',
        default_manifest_path: null,
        default_source_kind: 'toml',
        precedence: 'live_meta',
        has_live_override: 'true',
        override_fields: 'goal',
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

    expect(result.sandbox_roots).toEqual(['/tmp/workspace'])
    expect(result.autoboot_enabled).toBe(false)
    expect(result.max_context_override).toBe(64000)
    expect(result.sandbox_profile).toBe('docker')
    expect(result.network_mode).toBe('none')
    expect(result.keeper_last_error).toBe('sandbox docker exec failed')
    expect(result.execution.models).toEqual(['llama:test-balanced'])
    expect(result.execution.verify).toBe(true)
    expect(result.execution.selected_runtime_id).toBe('keeper_unified')
    expect(result.execution.selected_runtime_canonical).toBe('keeper_unified')
    expect(result.execution.runtime_options).toEqual(['keeper_unified', 'runpod_mtp.qwen36-35b-a3b-mtp'])
    expect(result.skills.names).toEqual(['ocaml-coding', 'proof-harness'])
    expect(result.hooks?.scope).toBe('keeper_runtime_composite')
    expect(result.hooks?.slots.pre_tool_use?.features).toEqual(['tool_start_timing'])
    expect(result.sources.precedence).toEqual(['live_meta'])
    expect(result.metrics.total_cost_usd).toBe(0.12)
    expect(result.runtime.runtime_blocker_class).toBe('stale_termination_storm')
    expect(result.runtime.runtime_blocker_summary).toBe('Fleet batch paused after stale termination storm.')
    expect(result.runtime_trust?.disposition).toBe('Pass')
    expect(result.field_presence?.present_paths).toContain('prompt.system_prompt_blocks.capabilities.text')
    expect(result.field_presence?.producer).toBe('dashboard-keeper-config.normalizer')
  })

  it.each([
    ['numeric string', '"64000"'],
    ['fractional numeric string', '"3.9"'],
    ['float', '3.9'],
    ['zero', '0'],
    ['negative integer', '-1'],
    ['unsafe integer', '9007199254740992'],
    ['out-of-range number', '1e309'],
  ])('rejects a non-canonical max_context_override wire value: %s', async (_label, wireValue) => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        `{"name":"keeper-sangsu","config_revision":{"manifest":{"state":"missing"},"runtime_assignment":{"state":"runtime_config_missing"}},"max_context_override":${wireValue}}`,
        {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        },
      ),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(fetchKeeperConfig('keeper-sangsu')).rejects.toThrowError(
      'Invalid keeper config response: max_context_override must be a positive safe integer or null',
    )
  })

  it('rejects a missing max_context_override wire field', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"name":"keeper-sangsu","config_revision":{"manifest":{"state":"missing"},"runtime_assignment":{"state":"runtime_config_missing"}}}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(fetchKeeperConfig('keeper-sangsu')).rejects.toThrowError(
      'Invalid keeper config response: max_context_override must be a positive safe integer or null',
    )
  })

  it('rejects a missing or unavailable manifest revision authority', async () => {
    for (const manifestRevision of [
      undefined,
      { state: 'unavailable', detail: 'permission denied' },
    ]) {
      const fetchMock = vi.fn().mockResolvedValue(
        new Response(JSON.stringify({
          name: 'keeper-sangsu',
          ...(manifestRevision === undefined
            ? {}
            : {
                config_revision: {
                  manifest: manifestRevision,
                  runtime_assignment: { state: 'runtime_config_missing' },
                },
              }),
          max_context_override: null,
          skills: { names: null },
        }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      )
      vi.stubGlobal('fetch', fetchMock)

      await expect(fetchKeeperConfig('keeper-sangsu')).rejects.toThrowError(
        /config_revision/,
      )
      vi.unstubAllGlobals()
    }
  })

  it('rejects a response that omits the Skill selection authority', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"name":"keeper-sangsu","config_revision":{"manifest":{"state":"missing"},"runtime_assignment":{"state":"runtime_config_missing"}},"max_context_override":null}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(fetchKeeperConfig('keeper-sangsu')).rejects.toThrowError(
      'Invalid keeper config response: skills.names is required',
    )
  })

  it('tracks raw keeper config field presence before defaults are normalized', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          name: 'keeper-sangsu',
          config_revision: configRevision,
          max_context_override: null,
          skills: { names: null },
          prompt: {
            instructions: 'raw instructions only',
          },
          metrics: {},
        }),
        {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        },
      ),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperConfig('keeper-sangsu')

    expect(result.prompt.instructions).toBe('raw instructions only')
    expect(result.metrics.last_model_used).toBe('')
    expect(result.field_presence?.present_paths).toContain('prompt.instructions')
    expect(result.field_presence?.present_paths).toContain('metrics')
    expect(result.field_presence?.present_paths).not.toContain('metrics.last_model_used')
  })

  it('preserves backend keeper config field-presence proof when supplied', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          name: 'keeper-sangsu',
          config_revision: configRevision,
          max_context_override: null,
          skills: { names: null },
          field_presence: {
            schema: 'keeper.config.field_presence.v1',
            producer: 'dashboard_http_keeper_snapshot',
            present_paths: ['name', 'prompt', 'prompt.instructions'],
          },
          prompt: {
            instructions: 'present but intentionally absent from proof',
          },
        }),
        {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        },
      ),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperConfig('keeper-sangsu')

    expect(result.field_presence).toEqual({
      schema: 'keeper.config.field_presence.v1',
      producer: 'dashboard_http_keeper_snapshot',
      present_paths: ['name', 'prompt', 'prompt.instructions'],
    })
  })

  it('preserves missing keeper config latency as null instead of zero', async () => {
    const cases: Array<[string, Record<string, unknown>]> = [
      ['null', { last_latency_ms: null }],
      ['missing', {}],
      ['zero number', { last_latency_ms: 0 }],
      ['zero string', { last_latency_ms: '0' }],
    ]

    for (const [label, metrics] of cases) {
      const fetchMock = vi.fn().mockResolvedValue(
        new Response(
          JSON.stringify({
            name: 'keeper-sangsu',
            config_revision: configRevision,
            max_context_override: null,
            skills: { names: null },
            metrics,
          }),
          {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          },
        ),
      )
      vi.stubGlobal('fetch', fetchMock)

      const result = await fetchKeeperConfig('keeper-sangsu')

      expect(result.metrics.last_latency_ms, label).toBeNull()
      vi.unstubAllGlobals()
    }
  })

  it('preserves terminal runtime blocker classes through config fetch and display labeling', async () => {
    const cases = [
      ['runtime_exhausted', '런타임 후보 소진'],
      ['provider_runtime_error', '런타임 호출 오류'],
      ['fiber_unresolved', 'Fiber 미해결'],
      ['fiber_unresolved', 'Fiber 미해결'],
      ['agent_core_context_window_exceeded', 'Agent Core 컨텍스트 윈도 초과'],
      ['agent_core_unrecognized_stop_reason', 'Agent Core 미식별 정지 사유'],
      ['agent_core_guardrail_violation', 'Agent Core 가드레일 위반'],
      ['agent_core_tripwire_violation', 'Agent Core Tripwire 위반'],
    ] as const

    for (const [blockerClass, label] of cases) {
      const fetchMock = vi.fn().mockResolvedValue(
        new Response(
          JSON.stringify({
            name: 'keeper-sangsu',
            config_revision: configRevision,
            max_context_override: null,
            skills: { names: null },
            runtime: {
              runtime_blocker_class: blockerClass,
              runtime_blocker_summary: blockerClass,
            },
          }),
          {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          },
        ),
      )
      vi.stubGlobal('fetch', fetchMock)

      const result = await fetchKeeperConfig('keeper-sangsu')

      expect(result.runtime.runtime_blocker_class).toBe(blockerClass)
      expect(keeperRuntimeBlockerLabel(result.runtime.runtime_blocker_class)).toBe(label)
    }
  })
})

describe('keeper config mutation API', () => {
  const manifestRevision = { state: 'sha256', value: 'b'.repeat(64) } as const
  const configRevision = {
    manifest: manifestRevision,
    runtime_assignment: { state: 'runtime_config_missing' as const },
  } as const

  it('ensures dashboard auth before posting runtime_id changes', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        name: 'keeper-sangsu',
        config_revision: configRevision,
        max_context_override: null,
        skills: { names: null },
        execution: {
          selected_runtime_id: 'b.two',
          selected_runtime_canonical: 'b.two',
          runtime_options: ['a.one', 'b.two'],
        },
        sources: {
          default_source_kind: 'toml',
          default_manifest_path: '/tmp/.masc/config/keepers/sangsu.toml',
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await patchKeeperConfig(
      'keeper-sangsu',
      { runtime_id: 'b.two' },
      configRevision,
    )

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    expect(devTokenMock.ensureDevToken.mock.invocationCallOrder[0]).toBeLessThan(
      fetchMock.mock.invocationCallOrder[0] ?? Number.POSITIVE_INFINITY,
    )
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/keepers/keeper-sangsu/config')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      runtime_id: 'b.two',
      expected_config_revision: configRevision,
    })
    expect(result.execution.selected_runtime_id).toBe('b.two')
  })

  it('posts an exact Skill name selection without changing its shape', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        name: 'keeper-sangsu',
        config_revision: configRevision,
        max_context_override: null,
        skills: { names: ['ocaml-coding'] },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await patchKeeperConfig('keeper-sangsu', {
      skills: { names: ['ocaml-coding'] },
    }, configRevision)

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({
      skills: { names: ['ocaml-coding'] },
      expected_config_revision: configRevision,
    })
    expect(result.skills.names).toEqual(['ocaml-coding'])
  })
})

describe('dashboard runtime probe API', () => {
  function runtimeProbeWire() {
    return {
      generated_at: '2026-06-10T12:00:00Z',
      refreshed_at_unix: 1781092800,
      cache_ttl_sec: 30,
      cache_age_sec: 0.5,
      cache_hit: true,
      refresh_state: 'fresh',
      probe: {
        source: 'runtime.toml',
        status: 'reachable',
        probe_ok: true,
        checked_at: '2026-06-10T12:00:00Z',
        summary: {
          runtimes: 1,
          probed: 1,
          reachable: 1,
          failed: 0,
          skipped: 0,
          default_runtime_id: 'runpod.qwen',
        },
        providers: [
          {
            runtime_id: 'runpod.qwen',
            provider_id: 'runpod',
            provider_display_name: 'RunPod',
            model_id: 'qwen',
            model_api_name: 'Qwen/Qwen3-32B',
            protocol: 'openai-compatible-http',
            runtime_kind: 'http',
            transport: 'http',
            auth_kind: 'env:RUNPOD_API_KEY',
            credential_required: true,
            auth_present: true,
            status: 'reachable',
            reachable: true,
            http_status: 200,
            latency_ms: 42.5,
            model_count: 1,
            content_type: 'application/json',
            downloaded_bytes: 128,
            endpoint_url: 'https://example.invalid/v1',
            probe_url: 'https://example.invalid/v1/models',
            error: null,
            checked_at: '2026-06-10T12:00:00Z',
          },
        ],
        errors: [],
        observations: ['runtime.toml provider reachability: 1 reachable, 0 failed, 0 skipped'],
        limitations: ['Probe checks provider metadata endpoints only; it does not send a completion request.'],
      },
    }
  }

  it('ensures dashboard auth before fetching runtime probe status', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(runtimeProbeWire()), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardRuntimeProbe(true)

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    expect(devTokenMock.ensureDevToken.mock.invocationCallOrder[0]).toBeLessThan(
      fetchMock.mock.invocationCallOrder[0] ?? Number.POSITIVE_INFINITY,
    )
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/runtime-probe?force=1')
    expect(result.probe?.probe_ok).toBe(true)
  })

  it('rejects legacy KV-cache fields at the API boundary', async () => {
    const legacy = runtimeProbeWire()
    Object.assign(legacy.probe, { kv_cache_assessment: { signal: 'likely_reused' } })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify(legacy), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    await expect(fetchDashboardRuntimeProbe()).rejects.toThrow(
      'runtime_probe schema drift',
    )
  })

  it('rejects unknown provider status values at the API boundary', async () => {
    const unknownStatus = runtimeProbeWire()
    const provider = unknownStatus.probe.providers[0]
    if (provider) provider.status = 'healthy'
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify(unknownStatus), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    await expect(fetchDashboardRuntimeProbe()).rejects.toThrow(
      'runtime_probe schema drift',
    )
  })
})

describe('runtime.toml raw config API', () => {
  const providerProtocols = [
    {
      protocol: 'openai-compatible-http',
      transport: 'endpoint',
      semantics: 'http_provider',
      credential_policy: 'optional',
      requires_non_interactive: false,
      provider_fields: [],
      required_provider_fields: [],
    },
    {
      protocol: 'codex-app-server',
      transport: 'command',
      semantics: 'official_client',
      credential_policy: 'forbidden',
      requires_non_interactive: true,
      provider_fields: [],
      required_provider_fields: [],
    },
  ]

  function isUnknownRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === 'object' && value !== null && !Array.isArray(value)
  }

  function applicationRecord(payload: Record<string, unknown>): Record<string, unknown> {
    if (!isUnknownRecord(payload.application)) {
      throw new Error('committed fixture application is not an object')
    }
    return payload.application
  }

  function committedPayload(payload: Record<string, unknown>): Record<string, unknown> {
    const application = isUnknownRecord(payload.application) ? payload.application : {}
    const sourceRevision = 'a'.repeat(64)
    return {
      ...payload,
      source_revision: sourceRevision,
      state: 'committed',
      commit: {
        source_revision: sourceRevision,
        order: '7',
        durability: 'durable',
        warnings: [],
      },
      application: {
        operation: 'test_write',
        routing: { status: 'applied', requires_restart: false, applied_at: null },
        keeper_overlay: {
          status: 'not_configured',
          requires_restart: false,
          applied_at: null,
          configured_count: 0,
          pending_keys: [],
          applied_keys: [],
          preempted_keys: [],
        },
        ...application,
        skills: {
          state: 'published',
          input_source_revision: sourceRevision,
          snapshot_revision: 'skill-snapshot-revision',
          catalog_revision: 'skill-catalog-revision',
          config_state: 'configured',
        },
      },
    }
  }

  it('fetches and normalizes the raw runtime.toml source', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        path: '/tmp/.masc/config/runtime.toml',
        file_name: 'runtime.toml',
        source_text: '[runtime]\ndefault = "runpod_mtp.qwen"\n',
        source_revision: 'a'.repeat(64),
        application: {
          operation: 'read',
          routing: { status: 'active', requires_restart: false, applied_at: null },
          keeper_overlay: {
            status: 'not_configured',
            requires_restart: false,
            applied_at: null,
            configured_count: 0,
            pending_keys: [],
            applied_keys: [],
            preempted_keys: [],
          },
        },
        keeper_settings: [{
          key: 'memory_os.librarian_enabled',
          env: 'MASC_KEEPER_MEMORY_OS_LIBRARIAN',
          configured_value: 'invalid',
          source: 'env',
          effective_value: null,
          effective_error: 'expected a boolean',
          applied_at: null,
          reload_class: 'restart',
          requires_restart: false,
          application_status: 'invalid',
          consumers: ['Keeper_memory_os'],
        }],
        provider_protocols: providerProtocols,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchRuntimeTomlConfig()

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    expect(devTokenMock.ensureDevToken.mock.invocationCallOrder[0]).toBeLessThan(
      fetchMock.mock.invocationCallOrder[0] ?? Number.POSITIVE_INFINITY,
    )
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/runtime/config/raw')
    expect(result.path).toBe('/tmp/.masc/config/runtime.toml')
    expect(result.file_name).toBe('runtime.toml')
    expect(result.source_text).toContain('[runtime]')
    expect(result.application?.routing.status).toBe('active')
    expect(result.application?.keeper_overlay.requires_restart).toBe(false)
    expect(result.keeper_settings?.[0]).toMatchObject({
      effective_value: null,
      effective_error: 'expected a boolean',
    })
    expect(result.provider_protocols).toEqual(providerProtocols)
  })

  it.each([
    ['missing inventory', undefined],
    ['empty inventory', []],
    ['duplicate protocol', [providerProtocols[0], providerProtocols[0]]],
    ['inconsistent official-client contract', [{
      ...providerProtocols[1],
      transport: 'endpoint',
    }]],
    ['unknown entry field', [{
      ...providerProtocols[0],
      client_owned: true,
    }]],
  ])('rejects %s from the backend protocol inventory', async (_label, inventory) => {
    const payload: Record<string, unknown> = {
      ok: true,
      path: '/tmp/.masc/config/runtime.toml',
      file_name: 'runtime.toml',
      source_text: '[runtime]\n',
      source_revision: 'a'.repeat(64),
      reloaded: false,
    }
    if (inventory !== undefined) payload.provider_protocols = inventory
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify(payload), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })))

    await expect(fetchRuntimeTomlConfig()).rejects.toThrow(/runtime provider protocol/)
  })

  it('posts the full raw TOML source through source_text', async () => {
    const sourceText = '[runtime]\ndefault = "openai.gpt"\n'
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(committedPayload({
        ok: true,
        path: '/tmp/.masc/config/runtime.toml',
        file_name: 'runtime.toml',
        source_text: sourceText,
        application: {
          operation: 'raw_save',
          routing: { status: 'applied', requires_restart: false, applied_at: '2026-08-11T00:00:00Z' },
          keeper_overlay: {
            status: 'pending_restart',
            requires_restart: true,
            applied_at: null,
            configured_count: 1,
            pending_keys: ['turn.temperature'],
            applied_keys: [],
            preempted_keys: [],
          },
        },
        provider_protocols: providerProtocols,
      })), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await saveRuntimeTomlConfig(sourceText)

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    expect(devTokenMock.ensureDevToken.mock.invocationCallOrder[0]).toBeLessThan(
      fetchMock.mock.invocationCallOrder[0] ?? Number.POSITIVE_INFINITY,
    )
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/runtime/config/raw')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({ source_text: sourceText })
    expect(result.application?.routing.status).toBe('applied')
    expect(result.application?.keeper_overlay.status).toBe('pending_restart')
    expect(result.state).toBe('committed')
    expect(result.commit).toEqual({
      source_revision: 'a'.repeat(64),
      order: '7',
      durability: 'durable',
      warnings: [],
    })
    expect(result.application.skills).toMatchObject({
      state: 'published',
      snapshot_revision: 'skill-snapshot-revision',
      catalog_revision: 'skill-catalog-revision',
    })
    expect(result.source_text).toBe(sourceText)
  })

  it('rejects a write response that drops the Skill application receipt', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({
      ok: true,
      state: 'committed',
      path: '/tmp/.masc/config/runtime.toml',
      source_text: '[runtime]\n',
      source_revision: 'a'.repeat(64),
      provider_protocols: providerProtocols,
      commit: {
        source_revision: 'runtime-source-revision',
        order: '8',
        durability: 'durable',
        warnings: [],
      },
      application: {
        operation: 'raw_save',
        routing: { status: 'applied', requires_restart: false, applied_at: null },
        keeper_overlay: {
          status: 'not_configured',
          requires_restart: false,
          applied_at: null,
          configured_count: 0,
          pending_keys: [],
          applied_keys: [],
          preempted_keys: [],
        },
      },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })))

    await expect(saveRuntimeTomlConfig('[runtime]\n')).rejects.toThrow(/적용 영수증/)
  })

  it.each(['routing', 'keeper_overlay'] as const)(
    'rejects a committed write response without %s application evidence',
    async (missingField) => {
      const payload = committedPayload({
        ok: true,
        path: '/tmp/.masc/config/runtime.toml',
        file_name: 'runtime.toml',
        source_text: '[runtime]\n',
        provider_protocols: providerProtocols,
      })
      const application = applicationRecord(payload)
      delete application[missingField]
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify(payload), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })))

      await expect(saveRuntimeTomlConfig('[runtime]\n')).rejects.toThrow(/적용 영수증/)
    },
  )

  it.each([
    {
      label: 'published source revision',
      skills: {
        state: 'published',
        input_source_revision: 'different-source-revision',
        snapshot_revision: 'skill-snapshot-revision',
        catalog_revision: 'skill-catalog-revision',
        config_state: 'configured',
      },
    },
    {
      label: 'superseded commit order',
      skills: { state: 'superseded', commit_order: '6', applied_order: '9' },
    },
    {
      label: 'retired source revision',
      skills: { state: 'workspace_retired', input_source_revision: null },
    },
    {
      label: 'open config state',
      skills: {
        state: 'published',
        input_source_revision: 'runtime-source-revision',
        snapshot_revision: 'skill-snapshot-revision',
        catalog_revision: 'skill-catalog-revision',
        config_state: 'future',
      },
    },
  ])('rejects a causally or structurally inconsistent $label receipt', async ({ skills }) => {
    const payload = committedPayload({
      ok: true,
      path: '/tmp/.masc/config/runtime.toml',
      file_name: 'runtime.toml',
      source_text: '[runtime]\n',
      provider_protocols: providerProtocols,
    })
    const application = applicationRecord(payload)
    application.skills = skills
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify(payload), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })))

    await expect(saveRuntimeTomlConfig('[runtime]\n')).rejects.toThrow(/적용 영수증/)
  })

  it('previews Keeper setting validation before raw save', async () => {
    const sourceText = '[keeper_settings]\nschema_version = 1\n[turn]\ntemperatur = 0.4\n'
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        can_save: false,
        validation: {
          valid: false,
          schema_version: 1,
          current_schema_version: 1,
          forward_schema: false,
          issues: [{
            key: 'turn.temperatur',
            kind: 'unknown_key',
            severity: 'error',
            detail: 'unknown Keeper runtime setting',
          }],
        },
        keeper_setting_schema: { authority: 'Keeper_runtime_setting_registry' },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const preview = await previewRuntimeTomlConfig(sourceText)

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/runtime/config/raw/preview')
    expect(preview.can_save).toBe(false)
    expect(preview.validation.issues[0]?.kind).toBe('unknown_key')
  })

  it('posts runtime routing patches without client-side TOML text', async () => {
    const sourceText = '[runtime]\ndefault = "openai.gpt"\n'
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(committedPayload({
        ok: true,
        path: '/tmp/.masc/config/runtime.toml',
        file_name: 'runtime.toml',
        source_text: sourceText,
        reloaded: true,
        provider_protocols: providerProtocols,
      })), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await patchRuntimeRouting('default', 'openai.gpt')

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/runtime/config/routing')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      lane: 'default',
      runtime_id: 'openai.gpt',
    })
    expect(result.source_text).toBe(sourceText)
  })

  it('posts ordered media failover routing patches', async () => {
    const sourceText = '[runtime]\nmedia_failover = ["rt-a", "rt-b"]\n'
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(committedPayload({
        ok: true,
        path: '/tmp/.masc/config/runtime.toml',
        file_name: 'runtime.toml',
        source_text: sourceText,
        reloaded: true,
        provider_protocols: providerProtocols,
      })), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await patchRuntimeMediaFailover(['rt-a', 'rt-b'])

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/runtime/config/routing')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      lane: 'media_failover',
      runtime_ids: ['rt-a', 'rt-b'],
    })
    expect(result.source_text).toBe(sourceText)
  })

  it('posts runtime assignment patches without client-side TOML text', async () => {
    const sourceText = '[runtime.assignments]\nsangsu = "openai.gpt"\n'
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(committedPayload({
        ok: true,
        path: '/tmp/.masc/config/runtime.toml',
        file_name: 'runtime.toml',
        source_text: sourceText,
        reloaded: true,
        provider_protocols: providerProtocols,
      })), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const expectedAssignmentRevision = {
      state: 'runtime_config_present' as const,
      source_revision: 'a'.repeat(64),
      assignment: { state: 'assigned' as const, runtime_id: 'openai.gpt' },
    }
    const result = await patchRuntimeAssignment(
      'sangsu',
      null,
      expectedAssignmentRevision,
    )

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/runtime/config/assignment')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      keeper_name: 'sangsu',
      runtime_id: null,
      expected_assignment_revision: expectedAssignmentRevision,
    })
    expect('source_text' in result ? result.source_text : null).toBe(sourceText)
  })
})

describe('fetchRuntimeProviders', () => {
  it('preserves stable provider lane IDs emitted by the API', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        updated_at: '2026-05-13T13:00:00Z',
        summary: {
          providers: 1,
          runtimes: 1,
          local_models: 0,
          cloud_models: 1,
          cli_models: 0,
          default_runtime_id: 'runpod_mtp.qwen',
        },
        providers: [
          {
            provider: 'runpod_mtp.qwen',
            runtime_id: 'runpod_mtp.qwen',
            provider_id: 'runpod_mtp',
            model_id: 'qwen',
            model_api_name: 'Qwen/Qwen3-32B',
            kind: 'cloud',
            runtime_kind: 'http',
            status: 'configured',
            available: true,
            model_count: 1,
            models: ['Qwen/Qwen3-32B'],
            temperature: 0.65,
            top_p: 0.91,
            top_k: 42,
            min_p: 0.07,
            max_output_tokens: 65536,
            supports_tool_choice: true,
            supports_required_tool_choice: true,
            supports_named_tool_choice: true,
            supports_parallel_tool_calls: true,
            supports_extended_thinking: true,
            supports_response_format_json: true,
            supports_structured_output: true,
            supports_system_prompt: true,
            supports_caching: true,
            supports_prompt_caching: true,
            prompt_cache_alignment: 1024,
            supports_top_k: true,
            supports_min_p: true,
            supports_seed: true,
            supports_seed_with_images: true,
            emits_usage_tokens: true,
            supports_computer_use: false,
            supports_code_execution: true,
            supports_audio_input: true,
            supports_video_input: false,
            parameter_policy: {
              reasoning_toggle_wire: 'chat_template_kwargs',
              reasoning_replay_policy: 'preserve_always',
              requires_reasoning_replay_on_tool_call: false,
              ignored_sampling_params: ['temperature', 'top_p'],
              always_ignored_sampling_params: ['temperature'],
            },
            request_config: {
              source: 'agent-core-provider-config',
              provider_kind: 'openai_compat',
              request_path: '/chat/completions',
              request_path_targets_responses_api: false,
              max_tokens: 65536,
              max_context: 131072,
              temperature: null,
              top_p: null,
              top_k: null,
              min_p: null,
              has_system_prompt: false,
              enable_thinking: true,
              preserve_thinking: null,
              thinking_budget: 32768,
              clear_thinking: false,
              resolved_reasoning_effort: 'high',
              glm_clear_thinking: false,
              glm_replay_reasoning: true,
              tool_stream: true,
              tool_choice: {
                kind: 'required',
              },
              disable_parallel_tool_use: false,
              response_format: {
                kind: 'json_schema',
                has_schema: true,
              },
              has_output_schema: true,
              cache_system_prompt: true,
              supports_tool_choice_override: true,
              supports_structured_output_override: null,
              has_model_capabilities_override: true,
              keep_alive: '30m',
              internal_model_rotation_count: null,
              num_ctx: 131072,
              seed: 42,
              has_previous_response_id: false,
              connect_timeout_s: 120,
            },
            effective_capabilities: {
              source: 'agent-core-provider-config-model',
              max_context_tokens: 131072,
              max_output_tokens: 65536,
              supports_tools: true,
              supports_tool_choice: true,
              supports_required_tool_choice: true,
              supports_named_tool_choice: false,
              supports_parallel_tool_calls: true,
              supports_runtime_mcp_tools: false,
              supports_runtime_tool_events: false,
              assistant_tool_content_format: 'null',
              supports_reasoning: true,
              supports_extended_thinking: true,
              supports_reasoning_budget: true,
              accepted_reasoning_efforts: ['low', 'medium', 'high'],
              thinking_control_format: 'chat-template-kwargs',
              preserve_thinking_control_format: 'chat-template-kwargs-preserve-thinking',
              reasoning_output_format: 'split-reasoning-fields',
              reasoning_streaming_format: {
                kind: 'delta-reasoning-field',
                field: 'reasoning_content',
              },
              reasoning_replay_override: 'preserve-always',
              supports_response_format_json: true,
              supports_structured_output: true,
              supports_multimodal_inputs: true,
              supports_image_input: true,
              supports_audio_input: false,
              supports_video_input: false,
              modality_priority: 'visual-first',
              task: null,
              supports_native_streaming: true,
              supports_system_prompt: true,
              supports_caching: true,
              supports_prompt_caching: true,
              prompt_cache_alignment: 1024,
              supports_top_k: true,
              supports_min_p: true,
              supports_seed: true,
              supports_seed_with_images: false,
              ignored_sampling_parameters: ['temperature', 'top_p', 'presence_penalty', 'frequency_penalty'],
              supports_computer_use: false,
              supports_code_execution: false,
              emits_usage_tokens: true,
              supported_models: null,
            },
            declared_spec: {
              source: 'runtime.toml',
              provider: {
                id: 'runpod_mtp',
                display_name: 'RunPod',
                protocol: 'openai-compatible-http',
                api_format: 'chat-completions',
                transport: 'http',
                auth_kind: 'env:RUNPOD_API_KEY',
                is_non_interactive: false,
                has_capabilities: true,
                behavior_capabilities: {
                  supports_inline_tools: true,
                  argv_prompt_preflight: false,
                  uses_anthropic_caching: false,
                },
                custom_header_count: 2,
                connect_timeout_s: 120,
              },
              model: {
                id: 'qwen',
                api_name: 'Qwen/Qwen3-32B',
                tools_support: true,
                max_context: 128000,
                thinking_support: true,
                preserve_thinking: true,
                max_thinking_budget: 32768,
                streaming: true,
                temperature: 0.65,
                top_p: 0.91,
                top_k: 42,
                min_p: 0.07,
                capabilities: {
                  source: 'runtime.toml',
                  max_output_tokens: 65536,
                  supports_tool_choice: true,
                  supports_required_tool_choice: true,
                  supports_named_tool_choice: true,
                  supports_parallel_tool_calls: true,
                  supports_extended_thinking: true,
                  supports_reasoning_budget: true,
                  thinking_control_format: 'chat-template-kwargs',
                  supports_image_input: true,
                  supports_audio_input: false,
                  supports_video_input: false,
                  supports_multimodal_inputs: true,
                  supports_response_format_json: true,
                  supports_structured_output: true,
                  supports_system_prompt: true,
                  supports_caching: true,
                  supports_prompt_caching: true,
                  prompt_cache_alignment: 1024,
                  supports_top_k: true,
                  supports_min_p: true,
                  supports_seed: true,
                  supports_seed_with_images: true,
                  emits_usage_tokens: true,
                  supports_computer_use: false,
                  supports_code_execution: true,
                },
              },
              binding: {
                provider_id: 'runpod_mtp',
                model_id: 'qwen',
                is_default: true,
                max_concurrent: 4,
                price_input: 0.1,
                price_output: 0.2,
                keep_alive: '30m',
                num_ctx: 131072,
              },
            },
            source: 'runtime.toml',
          },
          {
            provider: 'openai.gpt',
            runtime_id: 'openai.gpt',
            temperature: null,
          },
        ],
        assignment_status: {
          schema: 'masc.runtime_assignment_status.v1',
          source: 'runtime.toml',
          status: 'degraded',
          degraded: true,
          operator_action_required: true,
          blast_radius: 'single_runtime_assignment_pin',
          assignment_count: 2,
          assigned_runtime_count: 1,
          default_assignment_count: 0,
          default_runtime_id: 'runpod_mtp.qwen',
          warnings: ['explicit_assignments_present', 'single_runtime_assignment_pin'],
          assigned_runtimes: ['openai.gpt'],
          assignments: [
            { keeper: 'budgettest', runtime_id: 'openai.gpt', matches_default: false },
            { keeper: 'routingtest', runtime_id: 'openai.gpt', matches_default: false },
          ],
        },
        startup_degradation: {
          schema: 'masc.runtime_startup_degradation.v1',
          status: 'degraded',
          degraded: true,
          operator_action_required: true,
          terminal_reason: 'missing_agent_core_catalog_models',
          message: 'runtime catalog degraded boot',
          config_path: '/tmp/masc-test/runtime.toml',
          configured_default_runtime_id: 'runpod_mtp.qwen',
          effective_default_runtime_id: 'runpod_mtp.qwen',
          missing_catalog_model_count: 1,
          missing_catalog_models: [
            {
              runtime_id: 'mimo.mimo-v2.5-pro',
              provider_id: 'mimo',
              provider_label: 'openai_compat',
              model_id: 'mimo-v2.5-pro',
            },
          ],
          disabled_runtime_ids: ['mimo.mimo-v2.5-pro'],
          dropped_assignments: [
            { keeper_name: 'budgettest', runtime_id: 'mimo.mimo-v2.5-pro' },
          ],
          dropped_routes: [
            { route_name: 'runtime.default', runtime_id: 'mimo.mimo-v2.5-pro' },
          ],
          dropped_media_failover: ['mimo.mimo-v2.5-pro'],
          dropped_lane_candidates: [
            { lane_id: 'coding', runtime_ids: ['mimo.mimo-v2.5-pro'] },
          ],
          dropped_lanes: [
            { lane_id: 'mimo-only', runtime_ids: ['mimo.mimo-v2.5-pro'] },
          ],
          next_action: 'Add deployment rows to agent-core-models-overlay.toml (or upstream Agent Core).',
        },
        config_path: '/tmp/masc-test/runtime.toml',
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchRuntimeProviders()

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/providers')
    expect(result.config_path).toBe('/tmp/masc-test/runtime.toml')
    expect(result.summary?.default_runtime_id).toBe('runpod_mtp.qwen')
    expect(result.providers[0]?.provider).toBe('runpod_mtp.qwen')
    expect(result.providers[0]?.provider_id).toBe('runpod_mtp')
    expect(result.providers[0]?.model_api_name).toBe('Qwen/Qwen3-32B')
    expect(result.providers[0]?.kind).toBe('cloud')
    expect(result.providers[0]?.runtime_kind).toBe('http')
    expect(result.providers[0]?.temperature).toBe(0.65)
    expect(result.providers[0]?.top_p).toBe(0.91)
    expect(result.providers[0]?.top_k).toBe(42)
    expect(result.providers[0]?.min_p).toBe(0.07)
    expect(result.providers[0]?.max_output_tokens).toBe(65536)
    expect(result.providers[0]?.supports_tool_choice).toBe(true)
    expect(result.providers[0]?.supports_required_tool_choice).toBe(true)
    expect(result.providers[0]?.supports_named_tool_choice).toBe(true)
    expect(result.providers[0]?.supports_parallel_tool_calls).toBe(true)
    expect(result.providers[0]?.supports_extended_thinking).toBe(true)
    expect(result.providers[0]?.supports_response_format_json).toBe(true)
    expect(result.providers[0]?.supports_structured_output).toBe(true)
    expect(result.providers[0]?.effective_capabilities?.supports_native_streaming).toBe(true)
    expect(result.providers[0]?.supports_system_prompt).toBe(true)
    expect(result.providers[0]?.supports_prompt_caching).toBe(true)
    expect(result.providers[0]?.prompt_cache_alignment).toBe(1024)
    expect(result.providers[0]?.supports_top_k).toBe(true)
    expect(result.providers[0]?.supports_min_p).toBe(true)
    expect(result.providers[0]?.supports_seed).toBe(true)
    expect(result.providers[0]?.supports_seed_with_images).toBe(true)
    expect(result.providers[0]?.emits_usage_tokens).toBe(true)
    expect(result.providers[0]?.supports_code_execution).toBe(true)
    expect(result.providers[0]?.supports_audio_input).toBe(true)
    expect(result.providers[0]?.supports_video_input).toBe(false)
    expect(result.providers[0]?.parameter_policy?.reasoning_toggle_wire).toBe('chat_template_kwargs')
    expect(result.providers[0]?.parameter_policy?.reasoning_replay_policy).toBe('preserve_always')
    expect(result.providers[0]?.parameter_policy?.ignored_sampling_params).toEqual(['temperature', 'top_p'])
    expect(result.providers[0]?.parameter_policy?.always_ignored_sampling_params).toEqual(['temperature'])
    expect(result.providers[0]?.request_config?.provider_kind).toBe('openai_compat')
    expect(result.providers[0]?.request_config?.request_path).toBe('/chat/completions')
    expect(result.providers[0]?.request_config?.max_tokens).toBe(65536)
    expect(result.providers[0]?.request_config?.thinking_budget).toBe(32768)
    expect(result.providers[0]?.request_config?.resolved_reasoning_effort).toBe('high')
    expect(result.providers[0]?.request_config?.tool_choice?.kind).toBe('required')
    expect(result.providers[0]?.request_config?.response_format?.kind).toBe('json_schema')
    expect(result.providers[0]?.request_config?.num_ctx).toBe(131072)
    expect(result.providers[0]?.effective_capabilities?.max_output_tokens).toBe(65536)
    expect(result.providers[0]?.effective_capabilities?.supports_parallel_tool_calls).toBe(true)
    expect(result.providers[0]?.effective_capabilities?.accepted_reasoning_efforts).toEqual(['low', 'medium', 'high'])
    expect(result.providers[0]?.effective_capabilities?.reasoning_streaming_format?.field).toBe('reasoning_content')
    expect(result.providers[0]?.effective_capabilities?.modality_priority).toBe('visual-first')
    expect(result.providers[0]?.effective_capabilities?.supports_top_k).toBe(true)
    expect(result.providers[0]?.effective_capabilities?.ignored_sampling_parameters).toEqual([
      'temperature',
      'top_p',
      'presence_penalty',
      'frequency_penalty',
    ])
    expect(result.providers[0]?.declared_spec?.source).toBe('runtime.toml')
    expect(result.providers[0]?.declared_spec?.provider?.api_format).toBe('chat-completions')
    expect(
      result.providers[0]?.declared_spec?.provider?.behavior_capabilities
        ?.supports_inline_tools,
    ).toBe(true)
    expect(result.providers[0]?.declared_spec?.model?.capabilities?.supports_structured_output).toBe(true)
    expect(result.providers[0]?.declared_spec?.model?.capabilities?.supports_parallel_tool_calls).toBe(true)
    expect(result.providers[0]?.declared_spec?.model?.capabilities?.supports_system_prompt).toBe(true)
    expect(result.providers[0]?.declared_spec?.model?.capabilities?.supports_seed_with_images).toBe(true)
    expect(result.providers[0]?.declared_spec?.model?.capabilities?.supports_code_execution).toBe(true)
    expect(result.providers[0]?.declared_spec?.model?.top_p).toBe(0.91)
    expect(result.providers[0]?.declared_spec?.model?.top_k).toBe(42)
    expect(result.providers[0]?.declared_spec?.model?.min_p).toBe(0.07)
    expect(result.providers[0]?.declared_spec?.binding?.max_concurrent).toBe(4)
    expect(result.providers[1]?.temperature).toBeNull()
    expect(result.assignment_status?.status).toBe('degraded')
    expect(result.assignment_status?.assignment_count).toBe(2)
    expect(result.assignment_status?.assigned_runtimes).toEqual(['openai.gpt'])
    expect(result.assignment_status?.assignments[0]?.keeper).toBe('budgettest')
    expect(result.startup_degradation?.status).toBe('degraded')
    expect(result.startup_degradation?.terminal_reason).toBe('missing_agent_core_catalog_models')
    expect(result.startup_degradation?.effective_default_runtime_id).toBe('runpod_mtp.qwen')
    expect(result.startup_degradation?.missing_catalog_models[0]?.provider_label).toBe('openai_compat')
    expect(result.startup_degradation?.disabled_runtime_ids).toEqual(['mimo.mimo-v2.5-pro'])
    expect(result.startup_degradation?.dropped_assignments[0]?.keeper_name).toBe('budgettest')
    expect(result.startup_degradation?.dropped_routes[0]?.route_name).toBe('runtime.default')
    expect(result.startup_degradation?.dropped_lane_candidates[0]?.lane_id).toBe('coding')
  })

  it('preserves thinking-control wires without duplicating the server enum', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        providers: [
          {
            provider: 'ollama.deepseek',
            runtime_id: 'ollama.deepseek',
            models: ['deepseek'],
            effective_capabilities: {
              thinking_control_format: 'ollama-think',
            },
          },
          {
            provider: 'future.model',
            runtime_id: 'future.model',
            models: ['model'],
            effective_capabilities: {
              thinking_control_format: 'future-undocumented-wire',
            },
          },
        ],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchRuntimeProviders()

    expect(result.providers[0]?.effective_capabilities?.thinking_control_format).toBe('ollama-think')
    expect(result.providers[1]?.effective_capabilities?.thinking_control_format).toBe('future-undocumented-wire')
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
          model_id: 'runtime_lane_a1b2c3d4e5f6',
          entry_count: 1,
          success_count: 1,
          usage_sample_count: 0,
          telemetry_sample_count: 0,
          usage_missing_count: 1,
          telemetry_missing_count: 1,
          coverage_status: 'none',
          primary_coverage_stage: 'agentCore',
          primary_coverage_reason: 'missing_usage_and_inference',
          coverage_reason_counts: [
            { reason: 'missing_usage_and_inference', count: 1 },
          ],
          avg_latency_ms: null,
          total_input_tokens: null,
          total_cost_usd: null,
          recent_entries: [
            {
              ts_unix: 1,
              outcome: 'success',
              stop_reason: 'completed',
              turn_lane: 'text_only',
              input_tokens: null,
              output_tokens: null,
              cache_read_tokens: null,
              cache_creation_tokens: null,
              latency_ms: null,
              cost_usd: null,
              tools_count: 0,
              usage_reported: false,
              telemetry_reported: false,
              coverage_reason: 'missing_usage_and_inference',
              coverage_stage: 'agentCore',
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

    expect(metric.model_id).toBe('runtime_lane_a1b2c3d4e5f6')
    expect(metric.provider).toBeNull()
    expect(metric.usage_sample_count).toBe(0)
    expect(metric.telemetry_sample_count).toBe(0)
    expect(metric.usage_missing_count).toBe(1)
    expect(metric.telemetry_missing_count).toBe(1)
    expect(metric.coverage_status).toBe('none')
    expect(metric.primary_coverage_stage).toBe('agentCore')
    expect(metric.primary_coverage_reason).toBe('missing_usage_and_inference')
    expect(metric.coverage_reason_counts).toEqual([
      { reason: 'missing_usage_and_inference', count: 1 },
    ])
    expect(metric.total_input_tokens).toBeNull()
    expect(metric.total_cost_usd).toBeNull()
    expect(metric.recent_entries?.[0]?.outcome).toBe('success')
    expect(metric.recent_entries?.[0]?.stop_reason).toBe('completed')
    expect(metric.recent_entries?.[0]?.turn_lane).toBe('text_only')
    expect(metric.recent_entries?.[0]?.input_tokens).toBeNull()
    expect(metric.recent_entries?.[0]?.cache_read_tokens).toBeNull()
    expect(metric.recent_entries?.[0]?.cache_creation_tokens).toBeNull()
    expect(metric.recent_entries?.[0]?.latency_ms).toBeNull()
    expect(metric.recent_entries?.[0]?.usage_reported).toBe(false)
    expect(metric.recent_entries?.[0]?.telemetry_reported).toBe(false)
    expect(metric.recent_entries?.[0]?.coverage_reason).toBe('missing_usage_and_inference')
    expect(metric.recent_entries?.[0]?.coverage_stage).toBe('agentCore')
    expect(metric.buckets?.[0]?.p95_latency_ms).toBeNull()
    expect(metric.buckets?.[0]?.cache_hit_ratio).toBeNull()
  })
})

describe('fetchKeeperCostMetrics', () => {
  it('redacts legacy model breakdown labels while preserving cost totals', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        window_minutes: 60,
        keepers: [
          {
            keeper_name: 'keeper-alpha',
            total_cost_usd: 0.5,
            total_input_tokens: 10,
            total_output_tokens: 5,
            total_tokens: 15,
            p50_latency_ms: 100,
            p95_latency_ms: 100,
            sample_count: 2,
            model_breakdown: [
              { model: 'private-provider:claude', cost_usd: 0.2 },
              { model: 'private-provider:model-b', cost_usd: 0.3 },
            ],
          },
        ],
        generated_at: 1,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperCostMetrics(60)

    expect(result.keepers[0]?.model_breakdown).toEqual([
      { model: 'runtime', cost_usd: 0.5 },
    ])
  })

  it('marks missing model breakdown labels as unknown instead of fabricating runtime', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        keepers: [
          {
            keeper_name: 'keeper-alpha',
            total_cost_usd: 0.5,
            sample_count: 2,
            model_breakdown: [
              { cost_usd: 0.2 },
              { model: ' ', cost_usd: 0.3 },
            ],
          },
        ],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperCostMetrics(60)

    expect(result.keepers[0]?.model_breakdown).toEqual([
      { model: 'unknown_model', cost_usd: 0.5 },
    ])
  })
})

describe('fetchKeeperDecisions', () => {
  it('decodes current decision rows without a model identity field', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        events: [
          {
            ts_unix: 1,
            keeper_name: 'keeper-alpha',
            event_type: 'turn',
            outcome: 'success',
            choice: 'use_shell',
            reason: 'verify touched test target',
            context: {
              file_path: 'runtime.ts',
              line: 19,
              goal_id: 'goal-decision',
              task_id: 'task-decision',
              board_post_id: 'post-decision',
              comment_id: 'comment-decision',
              pr_id: '15035',
              git_ref: 'refs/heads/decision-route',
              log_id: 'decision-turn-19',
              session_id: 'sess-decision',
              operation_id: 'op-decision',
              worker_run_id: 'worker-decision',
            },
          },
        ],
        limit: 1,
        generated_at: 1,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperDecisions(1)

    expect(result.events[0]?.choice).toBe('use_shell')
    expect(result.events[0]?.reason).toBe('verify touched test target')
    expect(result.events[0]?.context).toEqual({
      file_path: 'runtime.ts',
      line: 19,
      goal_id: 'goal-decision',
      task_id: 'task-decision',
      board_post_id: 'post-decision',
      comment_id: 'comment-decision',
      pr_id: '15035',
      git_ref: 'refs/heads/decision-route',
      log_id: 'decision-turn-19',
      session_id: 'sess-decision',
      operation_id: 'op-decision',
      worker_run_id: 'worker-decision',
    })
  })

  it('decodes terminal_reason_code (and defaults to null when absent)', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        events: [
          { ts_unix: 1, keeper_name: 'k', event_type: 'turn', outcome: 'error', terminal_reason_code: 'runtime_exhausted' },
          { ts_unix: 2, keeper_name: 'k', event_type: 'turn', outcome: 'success' },
        ],
        limit: 2,
        generated_at: 1,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperDecisions(2)
    expect(result.events[0]?.terminal_reason_code).toBe('runtime_exhausted')
    expect(result.events[1]?.terminal_reason_code).toBeNull()
  })
})

describe('fetchCostLatency', () => {
  it('preserves missing latency percentiles as null instead of zero', async () => {
    const rawResponse = {
      perAgent: [
        {
          agent: 'runtime_lane_7',
          in_tok: 100,
          out_tok: 50,
          cost: 0.01,
          p50_ms: null,
          p95_ms: null,
        },
      ],
      matrix: {
        providers: ['local'],
        models: ['runtime_lane_7'],
        grid: [[0.01]],
      },
      latencyBuckets: [],
      p50: null,
      p95: null,
      total_cost_usd: 0.01,
      window_minutes: 60,
      generated_at: 1,
    }

    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchCostLatency(60)

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/cost-latency?window=60')
    expect(result.p50).toBeNull()
    expect(result.p95).toBeNull()
    expect(result.perAgent[0]?.agent).toBe('runtime_lane_7')
    expect(result.perAgent[0]?.p50_ms).toBeNull()
    expect(result.perAgent[0]?.p95_ms).toBeNull()
    expect(result.matrix.providers).toEqual(['runtime'])
    expect(result.matrix.models).toEqual(['runtime_lane_7'])
  })

  it('marks unlabeled cost-matrix lanes as unknown instead of synthetic runtime lanes', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        perAgent: [],
        matrix: {
          providers: [],
          models: [],
          grid: [[0.01, 0.02]],
        },
        latencyBuckets: [],
        total_cost_usd: 0.03,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchCostLatency(60)

    expect(result.matrix.providers).toEqual(['unknown_provider'])
    expect(result.matrix.models).toEqual(['unknown_model_1', 'unknown_model_2'])
    expect(result.matrix.grid).toEqual([[0.01, 0.02]])
  })
})

describe('fetchRuntimeDefaults', () => {
  it('reads the resolved runtime-defaults surface and parses it', async () => {
    const rawResponse = {
      generated_at_iso: '2026-06-21T00:00:00Z',
      dashboard_surface: '/api/v1/dashboard/runtime-defaults',
      source: 'runtime_config',
      config_path: '/cfg/runtime.toml',
      default_runtime_id: 'openai.gpt-4o',
      default_model: 'gpt-4o',
      default_max_context: 128000,
      runtimes: [
        { id: 'openai.gpt-4o', provider: 'OpenAI', model: 'gpt-4o', max_context: 128000, is_default: true },
      ],
      model_routing: {
        media_failover: [],
      },
    }
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchRuntimeDefaults()

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/runtime-defaults')
    expect(result.default_runtime_id).toBe('openai.gpt-4o')
    expect(result.default_model).toBe('gpt-4o')
    expect(result.runtimes[0]?.is_default).toBe(true)
  })
})

describe('official-client session API', () => {
  const recoveryPayload = {
    schema: 'masc.dashboard.official-client-session.v1',
    ok: true,
    keeper_name: 'sangsu',
    session: {
      client_kind: 'codex',
      runtime_id: 'codex.codex',
      phase: {
        kind: 'recovery_required',
        recovery_id: '018f3a4a-27f4-7c9a-8fd8-330c2a3845aa',
        failure: 'protocol_failed',
        detail: 'malformed app-server event',
        required_at: 1_786_230_000,
        owner_epoch: '018f3a4a-27f4-7c9a-8fd8-330c2a3845ab',
        observed_session_id: 'thread-1',
        observed_turn_id: null,
        previous_settlement: null,
      },
      turn_count: 1,
      tool_surface_sha256: 'a'.repeat(64),
      last_recovery_resolution: null,
      last_transient_release: null,
      updated_at: 1_786_230_000,
    },
  }

  it('reads exact measured recovery evidence for one Keeper', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(recoveryPayload), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchOfficialClientSession('sangsu')

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/runtime/sessions/official-client?keeper_name=sangsu')
    const phase = result.session?.phase
    expect(phase?.kind).toBe('recovery_required')
    if (phase?.kind !== 'recovery_required') throw new Error('expected recovery-required phase')
    expect(phase.failure).toBe('protocol_failed')
    expect(phase.observed_session_id).toBe('thread-1')
  })

  it.each([
    {
      kind: 'start',
      phase: {
        kind: 'start',
        owner_epoch: recoveryPayload.session.phase.owner_epoch,
        previous_settlement: null,
      },
    },
    {
      kind: 'active',
      phase: {
        kind: 'active',
        owner_epoch: recoveryPayload.session.phase.owner_epoch,
        session_id: 'thread-active',
        previous_settlement: null,
      },
    },
    {
      kind: 'turn_inflight',
      phase: {
        kind: 'turn_inflight',
        owner_epoch: recoveryPayload.session.phase.owner_epoch,
        session_id: 'thread-active',
        turn_id: null,
        previous_settlement: null,
      },
    },
    {
      kind: 'settled',
      phase: {
        kind: 'settled',
        session_id: 'thread-settled',
        turn_id: 'turn-settled',
      },
    },
  ])('accepts exact $kind phase', async ({ phase }) => {
    const payload = {
      ...recoveryPayload,
      session: { ...recoveryPayload.session, phase },
    }
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(payload), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchOfficialClientSession('sangsu')

    expect(result.session?.phase.kind).toBe(phase.kind)
  })

  it('rejects phase, record, identity, and nullable-field drift', async () => {
    const malformedPayloads: Array<{ name: string; payload: unknown }> = [
      {
        name: 'unknown response field',
        payload: { ...recoveryPayload, extra: true },
      },
      {
        name: 'unknown session field',
        payload: {
          ...recoveryPayload,
          session: { ...recoveryPayload.session, extra: true },
        },
      },
      {
        name: 'unknown phase field',
        payload: {
          ...recoveryPayload,
          session: {
            ...recoveryPayload.session,
            phase: { ...recoveryPayload.session.phase, extra: true },
          },
        },
      },
      {
        name: 'missing required nullable phase field',
        payload: {
          ...recoveryPayload,
          session: {
            ...recoveryPayload.session,
            phase: Object.fromEntries(
              Object.entries(recoveryPayload.session.phase)
                .filter(([key]) => key !== 'observed_turn_id'),
            ),
          },
        },
      },
      {
        name: 'invalid recovery UUID',
        payload: {
          ...recoveryPayload,
          session: {
            ...recoveryPayload.session,
            phase: { ...recoveryPayload.session.phase, recovery_id: 'not-a-uuid' },
          },
        },
      },
      {
        name: 'observed turn without observed session',
        payload: {
          ...recoveryPayload,
          session: {
            ...recoveryPayload.session,
            phase: {
              ...recoveryPayload.session.phase,
              observed_session_id: null,
              observed_turn_id: 'turn-without-session',
            },
          },
        },
      },
      {
        name: 'invalid lowercase SHA-256',
        payload: {
          ...recoveryPayload,
          session: { ...recoveryPayload.session, tool_surface_sha256: 'A'.repeat(64) },
        },
      },
      {
        name: 'zero completed turns outside ready',
        payload: {
          ...recoveryPayload,
          session: { ...recoveryPayload.session, turn_count: 0 },
        },
      },
      {
        name: 'ready phase carrying another phase field',
        payload: {
          ...recoveryPayload,
          session: {
            ...recoveryPayload.session,
            phase: { kind: 'ready', owner_epoch: recoveryPayload.session.phase.owner_epoch },
          },
        },
      },
      {
        name: 'settlement with an unknown field',
        payload: {
          ...recoveryPayload,
          session: {
            ...recoveryPayload.session,
            phase: {
              ...recoveryPayload.session.phase,
              previous_settlement: {
                session_id: 'thread-previous',
                turn_id: 'turn-previous',
                extra: true,
              },
            },
          },
        },
      },
    ]

    for (const { name, payload } of malformedPayloads) {
      const fetchMock = vi.fn().mockResolvedValue(
        new Response(JSON.stringify(payload), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      )
      vi.stubGlobal('fetch', fetchMock)

      await expect(fetchOfficialClientSession('sangsu'), name)
        .rejects.toThrow('유효하지 않은 official-client session payload')
    }
  })

  it('posts the exact recovery fence and selected resolution', async () => {
    const resolvedPayload = {
      ...recoveryPayload,
      resolution_application: 'applied',
      audit: { recorded: true },
      session: {
        ...recoveryPayload.session,
        phase: { kind: 'ready' },
        // restart_fresh abandons the conversation, so the server resets the
        // completed-turn count with it. Spreading recoveryPayload's turn_count: 1
        // would mock a response the server cannot emit.
        turn_count: 0,
        last_recovery_resolution: {
          recovery_id: recoveryPayload.session.phase.recovery_id,
          failure: 'protocol_failed',
          resolution: { kind: 'restart_fresh' },
          resolved_by: 'dashboard',
          resolved_at: 1_786_230_010,
        },
      },
    }
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(resolvedPayload), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await resolveOfficialClientSession(
      'sangsu',
      recoveryPayload.session.phase.recovery_id,
      { resolution: 'restart_fresh' },
    )

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/runtime/sessions/official-client/resolve')
    expect(JSON.parse(init.body as string)).toEqual({
      keeper_name: 'sangsu',
      recovery_id: recoveryPayload.session.phase.recovery_id,
      resolution: 'restart_fresh',
    })
    expect(result.session?.phase.kind).toBe('ready')
    expect(result.session?.last_recovery_resolution?.resolved_by).toBe('dashboard')
    expect(result.resolution_application).toBe('applied')
    expect(result.audit).toEqual({ recorded: true })
  })

  it.each([
    {
      name: 'missing application',
      payload: {
        ...recoveryPayload,
        audit: { recorded: true },
      },
    },
    {
      name: 'unknown application',
      payload: {
        ...recoveryPayload,
        resolution_application: 'guessed',
        audit: { recorded: true },
      },
    },
    {
      name: 'malformed audit receipt',
      payload: {
        ...recoveryPayload,
        resolution_application: 'replayed',
        audit: { recorded: false },
      },
    },
  ])('rejects recovery operation drift: $name', async ({ payload }) => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(payload), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(resolveOfficialClientSession(
      'sangsu',
      recoveryPayload.session.phase.recovery_id,
      { resolution: 'restart_fresh' },
    )).rejects.toThrow('유효하지 않은 official-client recovery payload')
  })
})

describe('official-client login probe API', () => {
  const readyPayload = {
    schema: 'masc.dashboard.official-client-probe.v1',
    ok: true,
    runtime_id: 'codex.codex',
    client_kind: 'codex',
    configured_model: 'gpt-5.3-codex-spark',
    measured_at: 1_786_230_100,
    login: {
      status: 'ready',
      authenticated: true,
      evidence_source: 'configured_executable_self_report',
      identity_verified: false,
      auth_method: 'chatgpt',
      subscription_type: 'pro',
      api_provider: null,
    },
    client: { user_agent: 'codex_cli_rs/0.147.0' },
    execution: {
      status: 'not_measured',
      reason: 'login_probe_does_not_submit_model_turn',
    },
  }

  it('posts the exact runtime id and preserves the login/execution boundary', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(readyPayload), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await probeOfficialClientLogin('codex.codex')

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/runtime/official-client/probe')
    expect(JSON.parse(init.body as string)).toEqual({ runtime_id: 'codex.codex' })
    expect(result.login).toMatchObject({
      status: 'ready',
      authenticated: true,
      evidence_source: 'configured_executable_self_report',
      identity_verified: false,
    })
    expect(result.execution.status).toBe('not_measured')
  })

  it('rejects a payload that claims execution was measured', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ...readyPayload,
        execution: { status: 'ready', reason: 'login_ok' },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(probeOfficialClientLogin('codex.codex')).rejects.toThrow(
      '유효하지 않은 official-client probe payload',
    )
  })

  it('accepts a measured login failure without inventing login metadata', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ...readyPayload,
        login: {
          status: 'login_required',
          authenticated: false,
          evidence_source: 'configured_executable_self_report',
          identity_verified: false,
          detail: 'the official CLI has no active account',
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await probeOfficialClientLogin('codex.codex')

    expect(result.login).toEqual({
      status: 'login_required',
      authenticated: false,
      evidence_source: 'configured_executable_self_report',
      identity_verified: false,
      auth_method: null,
      subscription_type: null,
      api_provider: null,
      detail: 'the official CLI has no active account',
    })
    expect(result.execution.status).toBe('not_measured')
  })

  it('rejects fields outside the current probe contract', async () => {
    for (const payload of [
      { ...readyPayload, unexpected_status: 'ready' },
      { ...readyPayload, login: { ...readyPayload.login, detail: 'extra field' } },
      { ...readyPayload, login: { ...readyPayload.login, identity_verified: true } },
      { ...readyPayload, login: { ...readyPayload.login, evidence_source: 'official_client' } },
      { ...readyPayload, client: { ...readyPayload.client, version: 'extra field' } },
    ]) {
      const fetchMock = vi.fn().mockResolvedValue(
        new Response(JSON.stringify(payload), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      )
      vi.stubGlobal('fetch', fetchMock)

      await expect(probeOfficialClientLogin('codex.codex')).rejects.toThrow(
        '유효하지 않은 official-client probe payload',
      )
    }
  })
})
