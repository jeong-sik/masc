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
  fetchLogs,
  fetchDashboardExecutionTrust,
  fetchDashboardGovernance,
  fetchDashboardGoalDetail,
  fetchDashboardGoalsTree,
  fetchDashboardBriefing,
  fetchDashboardTools,
  fetchKeeperToolCalls,
  fetchKeeperToolStats,
  fetchKeeperCompactionSnapshots,
  fetchKeeperTurnRecords,
  parseMemoryOsFactCategory,
  parseMemoryOsClaimKind,
  fetchKeeperTurnTranscript,
  fetchDashboardMemory,
  fetchDashboardMission,
  fetchDashboardMissionBriefing,
  fetchDashboardRuntimeProbe,
  fetchCostLatency,
  fetchKeeperConfig,
  fetchKeeperCostMetrics,
  fetchKeeperDecisions,
  fetchMemorySubsystems,
  fetchRuntimeProviders,
  fetchRuntimeTomlConfig,
  fetchRuntimeDefaults,
  fetchRuntimeModelMetrics,
  patchRuntimeAssignment,
  patchRuntimeMediaFailover,
  patchRuntimeRouting,
  patchKeeperConfig,
  saveRuntimeTomlConfig,
  fetchDashboardCacheStats,
  fetchTelemetry,
  fetchTelemetrySummary,
  fetchTlcResults,
  fetchToolQuality,
  resolveScheduleApproval,
} from './dashboard'
import { fetchDashboardShell as fetchDashboardShellHot } from './dashboard-hot'
import { keeperRuntimeBlockerLabel } from '../lib/keeper-runtime-display'

const GOAL_FIXTURE_OK_COLOR = '#4ade80'

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
    health: 'on_track',
    health_color: GOAL_FIXTURE_OK_COLOR,
    badges: [],
    status_reason: 'working',
    priority: 1,
    metric: null,
    target_value: null,
    due_date: null,
    parent_goal_id: null,
    convergence: 0.5,
    convergence_pct: 50,
    tasks: [],
    task_count: 0,
    task_done_count: 0,
    pending_verification_count: 0,
    timeline_events: [],
    children: [],
    child_count: 0,
    last_activity_at: '2026-04-23T00:00:00Z',
    stagnation_seconds: 0,
    linked_keeper_names: [],
    pending_approval_count: 0,
    infra_risk_count: 0,
    linkage_source: 'none',
    linkage_warning_count: 0,
    blocking_source: 'none',
    blocking_reason: '',
    latest_keeper_ref: null,
    latest_turn_ref: null,
    stalled_since: null,
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

describe('resolveScheduleApproval', () => {
  it('posts dashboard schedule decisions to the dashboard-only resolve route', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true, schedule_id: 'sched-1', decision: 'approve' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await resolveScheduleApproval('sched-1', 'approve')

    expect(result).toEqual({ ok: true, schedule_id: 'sched-1', decision: 'approve' })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/schedule/resolve')
    const init = fetchMock.mock.calls[0]?.[1] as RequestInit
    expect(init.method).toBe('POST')
    expect(JSON.parse(String(init.body))).toEqual({
      schedule_id: 'sched-1',
      decision: 'approve',
    })
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
        migration: {
          body_shape: 'root_fields_preserved',
          rule: 'additive envelope first',
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
      migration: { body_shape: 'root_fields_preserved' },
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
      operator_targets: { keepers: [], pending_confirms: [], available_actions: [] },
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
      operator_targets: { keepers: [], pending_confirms: [], available_actions: [] },
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
            producer: 'keeper_hooks_oas.post_tool_use',
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
      producer: 'keeper_hooks_oas.post_tool_use',
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

  it('decodes semantic_outcome / semantic_success / goal_ids on an entry', async () => {
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
            output: 'blocked by policy',
            success: true,
            duration_ms: 5,
            semantic_outcome: 'blocked',
            semantic_success: false,
            goal_ids: ['g-1', 'g-2'],
          },
        ],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperToolCalls('keeper-alpha')
    const entry = result.entries[0]
    // transport success=true but the parsed output was blocked.
    expect(entry?.success).toBe(true)
    expect(entry?.semantic_success).toBe(false)
    expect(entry?.semantic_outcome).toBe('blocked')
    expect(entry?.goal_ids).toEqual(['g-1', 'g-2'])
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
            tool: 'keeper_board_post_get',
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

  it('grounds turn-record model / finish_reason, leaving absent fields undefined', async () => {
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(
      new Response(JSON.stringify({
        keeper: 'keeper-alpha',
        count: 2,
        source: 'turn_record',
        entries: [
          {
            record: {
              keeper: 'keeper-alpha',
              trace_id: 'trace-grounded',
              absolute_turn: 7,
              ts: 10,
              runtime_profile: 'local',
              model: 'deepseek-v4-flash',
              finish_reason: 'completed',
              blocks: [],
              execution_ids: [],
            },
            diff_vs_prev: null,
          },
          {
            // RFC-0233 §2.3: error turn omits model/finish_reason — must
            // decode to undefined, never a fabricated "stop"/placeholder.
            record: {
              keeper: 'keeper-alpha',
              trace_id: 'trace-grounded',
              absolute_turn: 8,
              ts: 11,
              runtime_profile: 'local',
              blocks: [],
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
    expect(result.entries[0]?.record.model).toBe('deepseek-v4-flash')
    expect(result.entries[0]?.record.finish_reason).toBe('completed')
    expect(result.entries[1]?.record.model).toBeUndefined()
    expect(result.entries[1]?.record.finish_reason).toBeUndefined()
  })

  it('decodes durable compaction snapshots with nullable token fields', async () => {
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(
      new Response(JSON.stringify({
        schema: 'keeper.compaction_snapshots.v1',
        keeper: 'keeper-alpha',
        source: 'runtime_manifest|keeper_meta',
        producer: 'keeper_runtime_manifest|keeper_meta_store',
        limit: 2,
        count: 2,
        read_error_count: 1,
        read_errors: [{ scope: 'runtime_manifest_row:/tmp/bad.jsonl:1', error: 'bad row' }],
        scan_truncated: false,
        items: [
          {
            id: 'manifest:trace-a:event_bus_correlated:2026-06-26T03:03:00Z',
            keeper: 'keeper-alpha',
            ts_iso: '2026-06-26T03:03:00Z',
            ts_unix: 1_782_444_580,
            trace_id: 'trace-a',
            keeper_turn_id: 12,
            source: 'runtime_manifest',
            trigger: 'proactive(85%)',
            runtime_id: 'oas-seoul-1',
            display_runtime: 'oas-seoul-1',
            before_tokens: 210000,
            after_tokens: 120000,
            saved_tokens: 90000,
            compaction_id: 'cmp-42',
            compaction_source: 'event_bus',
            status: 'observed',
            links: { receipt_path: null, checkpoint_path: null, tool_call_log_path: null },
          },
          {
            id: 'manifest:trace-b:context_compacted:2026-06-26T04:03:00Z',
            keeper: 'keeper-alpha',
            ts_iso: '2026-06-26T04:03:00Z',
            ts_unix: null,
            trace_id: 'trace-b',
            keeper_turn_id: null,
            source: 'runtime_manifest',
            trigger: 'pre_dispatch_hygiene',
            runtime_id: null,
            display_runtime: 'pre_dispatch_hygiene',
            before_tokens: null,
            after_tokens: null,
            saved_tokens: null,
            compaction_id: null,
            compaction_source: 'pre_dispatch_hygiene',
            status: 'compacted',
            links: {},
          },
        ],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperCompactionSnapshots('keeper-alpha', 2)

    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/keepers/keeper-alpha/compaction-snapshots?limit=2')
    expect(result.items[0]?.before_tokens).toBe(210000)
    expect(result.items[0]?.saved_tokens).toBe(90000)
    expect(result.items[0]?.display_runtime).toBe('oas-seoul-1')
    expect(result.read_error_count).toBe(1)
    expect(result.read_errors).toEqual([
      { scope: 'runtime_manifest_row:/tmp/bad.jsonl:1', error: 'bad row' },
    ])
    expect(result.scan_truncated).toBe(false)
    expect(result.items[0]?.links.receipt_path).toBeNull()
    expect(result.items[1]?.before_tokens).toBeNull()
    expect(result.items[1]?.runtime_id).toBeNull()
    expect(result.items[1]?.links.checkpoint_path).toBeNull()
  })
})

describe('parseMemoryOsFactCategory (SSOT mirror of category_of_string)', () => {
  it('maps every known token to its tag and absorbs the rest as a typed Unknown', () => {
    const known = [
      'code_change',
      'fact',
      'preference',
      'blocker',
      'goal',
      'constraint',
      'ephemeral',
      'validated_approach',
      'lesson',
    ] as const
    for (const token of known) {
      expect(parseMemoryOsFactCategory(token)).toEqual({ tag: token })
    }
    // trim + lowercase, like the backend's String.lowercase_ascii (String.trim s)
    expect(parseMemoryOsFactCategory('  FACT ')).toEqual({ tag: 'fact' })
    // out-of-vocabulary preserves the raw label so a rising-Unknown rate is visible
    expect(parseMemoryOsFactCategory('Speculation')).toEqual({ tag: 'unknown', raw: 'Speculation' })
    expect(parseMemoryOsFactCategory('')).toEqual({ tag: 'unknown', raw: '' })
  })
})

describe('parseMemoryOsClaimKind (SSOT mirror of claim_kind_of_string)', () => {
  it('maps the known kinds and yields undefined for anything else', () => {
    expect(parseMemoryOsClaimKind('self_observation')).toBe('self_observation')
    expect(parseMemoryOsClaimKind('external_state')).toBe('external_state')
    expect(parseMemoryOsClaimKind('durable_knowledge')).toBe('durable_knowledge')
    expect(parseMemoryOsClaimKind('diagnostic')).toBe('diagnostic')
    expect(parseMemoryOsClaimKind(' DURABLE_KNOWLEDGE ')).toBe('durable_knowledge')
    expect(parseMemoryOsClaimKind('nonsense')).toBeUndefined()
  })
})

describe('decodeMemoryOsFact via fetchKeeperTurnRecords (RFC-keeper-memory-panel-real-data §4a)', () => {
  it('decodes fact rows with typed category / provenance / TTL, absorbs Unknown, drops malformed and the deleted score model', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(
      new Response(JSON.stringify({
        keeper: 'keeper-alpha',
        count: 0,
        source: 'turn_record',
        entries: [],
        memory_os: {
          schema: 'keeper.memory_os.recall_observability.v1',
          keeper: 'keeper-alpha',
          source: 'memory_os_files',
          producer: 'keeper_librarian|keeper_memory_os_recall',
          facts_store: '.masc/config/keepers/keeper-alpha.facts.jsonl',
          episodes_store: '.masc/config/keepers/keeper-alpha/episodes',
          recall_enabled: true,
          now: 1_790_000_000,
          now_iso: '2026-09-21T00:00:00Z',
          read_errors: [],
          episodes: { tail_limit: 12, shown: 0, current: 0, expired: 0, terminal_markers: 0, items: [] },
          facts: {
            tail_limit: 256,
            shown: 3,
            current: 2,
            expired: 1,
            items: [
              {
                claim: 'retention D0 = signup day',
                category: 'constraint',
                source: { trace_id: 't-1', turn: 4, tool_call_id: 'call_9' },
                first_seen: 1_789_000_000,
                first_seen_iso: '2026-09-09T...Z',
                reference_time: 1_789_500_000,
                valid_until: null,
                valid_until_iso: null,
                last_verified_at: 1_789_500_000,
                current: true,
                prompt_recallable: true,
                claim_kind: 'durable_knowledge',
                external_ref: { kind: 'pr', id: '22198' },
                // RFC-0247-deleted score fields: present on the wire here as a
                // poison payload; the decoder must never copy them through.
                // external_ref is also ignored: current backend projections no
                // longer surface forced external-state references.
                salience: 0.92,
                uses: 14,
                confidence: 0.8,
              },
              {
                claim: 'librarian emitted a category outside the taxonomy',
                category: 'Speculation', // out-of-vocabulary → Unknown drift absorber
                source: { trace_id: 't-2', turn: 5 }, // tool_call_id omitted → null
                first_seen: 1_789_100_000,
                first_seen_iso: '2026-09-09T...Z',
                reference_time: 1_789_100_000,
                valid_until: 1_789_900_000,
                valid_until_iso: '2026-09-10T...Z',
                last_verified_at: null,
                current: false,
                prompt_recallable: true,
                // claim_kind omitted entirely → null
              },
              {
                // malformed: missing required `claim` → dropped, never fabricated
                category: 'fact',
                source: { trace_id: 't-3', turn: 6 },
                first_seen: 1,
                reference_time: 1,
                current: true,
                prompt_recallable: true,
              },
            ],
          },
        },
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperTurnRecords('keeper-alpha')
    const items = result.memory_os?.facts.items ?? []

    // 3 rows in, malformed row dropped, 2 decoded
    expect(items).toHaveLength(2)

    const [first, second] = items
    expect(first?.claim).toBe('retention D0 = signup day')
    expect(first?.category).toEqual({ tag: 'constraint' })
    expect(first?.source).toEqual({ trace_id: 't-1', turn: 4, tool_call_id: 'call_9' })
    expect(first?.current).toBe(true)
    expect(first?.valid_until).toBeNull()
    expect(first?.reference_time).toBe(1_789_500_000)
    expect(first?.claim_kind).toBe('durable_knowledge')
    expect(first).not.toHaveProperty('external_ref')
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('Ignoring legacy memory_os.external_ref payload'))

    // out-of-vocabulary category → typed Unknown arm carrying the raw label
    expect(second?.category).toEqual({ tag: 'unknown', raw: 'Speculation' })
    // omitted optionals are null, not fabricated
    expect(second?.source.tool_call_id).toBeNull()
    expect(second?.claim_kind).toBeNull()
    expect(second).not.toHaveProperty('external_ref')
    expect(second?.current).toBe(false)

    // RFC-0247 drift guard: the deleted composite-score fields never reappear,
    // even when the wire payload carries them.
    const deletedScoreKeys = [
      'salience',
      'uses',
      'lastUsed',
      'confidence',
      'access_count',
      'last_accessed',
      'stale_factor',
      'expected_lifetime_cycles',
    ]
    for (const key of deletedScoreKeys) {
      expect(first as Record<string, unknown>).not.toHaveProperty(key)
    }

    warnSpy.mockRestore()
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

describe('fetchMemorySubsystems', () => {
  it('adds the sensitive memory entries query only when requested', async () => {
    const rawResponse = {
      generated_at: '2026-05-06T00:00:00Z',
      hebbian: { synapses: [], last_consolidation: 0 },
      episodes: { total: 0, filtered: 0, shown: 0, limit: 100, items: [] },
      filters: { keepers: [], outcomes: [] },
    }
    const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))
    vi.stubGlobal('fetch', fetchMock)

    await fetchMemorySubsystems({ limit: 100 })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    let requestUrl = new URL(fetchMock.mock.calls[0]?.[0] as string, 'http://dashboard.local')
    expect(requestUrl.searchParams.has('include_memory_entries')).toBe(false)

    fetchMock.mockClear()

    await fetchMemorySubsystems({ limit: 100, includeMemoryEntries: true })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    requestUrl = new URL(fetchMock.mock.calls[0]?.[0] as string, 'http://dashboard.local')
    expect(requestUrl.pathname).toBe('/api/v1/dashboard/memory-subsystems')
    expect(requestUrl.searchParams.get('limit')).toBe('100')
    expect(requestUrl.searchParams.get('include_memory_entries')).toBe('true')
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
      tool_usage: { total_calls: 0, distinct_tools_called: 0, top_20: [], never_called_count: 0, dispatch_v2_enabled: false, registered_count: 2 },
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

  it('preserves tool usage coverage gap rows', async () => {
    const rawResponse = {
      tool_inventory: { tools: [] },
      tool_usage: {
        total_calls: 0,
        distinct_tools_called: 0,
        top_20: [],
        never_called_count: 0,
        dispatch_v2_enabled: false,
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
  it('requests vote-blind dashboard board rows for the current actor', async () => {
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
    expect(url).toContain('blind_votes=true')
  })
})

describe('fetchDashboardGovernance', () => {
  it('requests a forced governance snapshot when asked', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ approval_queue: [], recent_resolved: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await fetchDashboardGovernance({ force: true })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/governance?force=1')
  })

  it('normalizes resolved approval history separately from pending queue items', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        approval_queue: [],
        recent_resolved: [
          {
            id: 'appr-done',
            keeper_name: 'keeper-a',
            tool_name: 'fs_write',
            risk_level: 'medium',
            decision: 'reject:operator denied',
            decision_kind: 'reject',
            decision_reason: 'operator denied',
            resolved_at_iso: '2026-06-27T01:02:03Z',
          },
          {
            id: 'appr-legacy',
            keeper_name: 'keeper-a',
            tool_name: 'shell_exec',
            risk_level: 'high',
            decision: 'reject:legacy reason',
            resolved_at_iso: '2026-06-27T01:03:03Z',
          },
        ],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchDashboardGovernance()

    expect(result.recent_resolved).toEqual([
      expect.objectContaining({
        id: 'appr-done',
        keeper_name: 'keeper-a',
        tool_name: 'fs_write',
        risk_level: 'medium',
        decision: 'reject',
        decision_raw: 'reject:operator denied',
        decision_reason: 'operator denied',
        resolved_at: '2026-06-27T01:02:03Z',
      }),
      expect.objectContaining({
        id: 'appr-legacy',
        keeper_name: 'keeper-a',
        tool_name: 'shell_exec',
        risk_level: 'high',
        decision: 'unknown',
        decision_raw: 'reject:legacy reason',
        decision_reason: null,
        resolved_at: '2026-06-27T01:03:03Z',
      }),
    ])
    expect(result.recent_resolved?.[0]).not.toHaveProperty('requested_at')
  })

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

describe('dashboard goals decoding', () => {
  it('fills a missing verification_summary on goal tree payloads', async () => {
    const rawResponse = {
      tree: [makeRawGoalNode()],
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

    expect(result.tree[0]?.verification_summary).toEqual({
      effective_policy: null,
      open_request: null,
      latest_request: null,
      approve_count: 0,
      reject_count: 0,
      remaining_possible: 0,
    })
  })

  it('fills a missing verification_summary on goal detail payloads', async () => {
    const rawResponse = {
      goal: makeRawGoalNode(),
      linked_tasks: [],
      linked_keepers: [],
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

    expect(result.goal.verification_summary).toEqual({
      effective_policy: null,
      open_request: null,
      latest_request: null,
      approve_count: 0,
      reject_count: 0,
      remaining_possible: 0,
    })
  })

  it('decodes resolved goal verification evidence on tree payloads', async () => {
    const rawResponse = {
      tree: [
        makeRawGoalNode({
          verification_summary: {
            effective_policy: null,
            open_request: null,
            latest_request: {
              id: 'gvr-1',
              goal_id: 'goal-1',
              target_phase: 'completed',
              requested_by: { id: 'planner' },
              policy_snapshot: {
                principals: [{ id: 'keeper-alpha' }],
                eligible_principals: [{ id: 'keeper-alpha' }],
                required_verdicts: 1,
              },
              votes: [
                {
                  principal: { id: 'keeper-alpha', display_name: 'keeper-alpha' },
                  decision: 'approve',
                  note: 'checked receipt and tests',
                  evidence_refs: ['receipt:keeper-alpha:turn-7', 'test:test_goal_tools'],
                  submitted_at: '2026-04-23T01:00:00Z',
                },
              ],
              status: 'approved',
              created_at: '2026-04-23T00:55:00Z',
              resolved_at: '2026-04-23T01:00:00Z',
            },
            approve_count: 1,
            reject_count: 0,
            remaining_possible: 0,
          },
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

    expect(result.tree[0]?.verification_summary.latest_request).toMatchObject({
      id: 'gvr-1',
      status: 'approved',
      votes: [
        {
          decision: 'approve',
          note: 'checked receipt and tests',
          evidence_refs: ['receipt:keeper-alpha:turn-7', 'test:test_goal_tools'],
        },
      ],
    })
  })

  it('retains goal blocker metadata on tree payloads', async () => {
    const rawResponse = {
      tree: [
        makeRawGoalNode({
          blocking_source: 'keeper_runtime',
          blocking_reason: 'Pause until the keeper approval queue is resolved.',
          latest_keeper_ref: 'keeper-sangsu',
          latest_turn_ref: 42,
          stalled_since: '2026-04-22T22:00:00Z',
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
      blocking_source: 'keeper_runtime',
      blocking_reason: 'Pause until the keeper approval queue is resolved.',
      latest_keeper_ref: 'keeper-sangsu',
      latest_turn_ref: 42,
      stalled_since: '2026-04-22T22:00:00Z',
    })
  })

  it('does not default missing goal health to on_track', async () => {
    const rawResponse = {
      tree: [
        makeRawGoalNode({
          health: undefined,
          blocking_source: 'goal_linkage',
          linkage_warning_count: 1,
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
      health: 'at_risk',
      blocking_source: 'goal_linkage',
      linkage_warning_count: 1,
    })
  })

  it('decodes on_track_goals separately from active_goals', async () => {
    const rawResponse = {
      tree: [makeRawGoalNode()],
      summary: {
        total_goals: 3,
        active_goals: 2,
        on_track_goals: 1,
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

    expect(result.summary.active_goals).toBe(2)
    expect(result.summary.on_track_goals).toBe(1)
  })

  it('decodes goal attainment projections on tree payloads', async () => {
    const rawResponse = {
      tree: [
        makeRawGoalNode({
          metric: 'completion_pct',
          target_value: '75%',
          attainment: {
            state: 'attained',
            basis: 'metric_target_percent',
            metric: 'completion_pct',
            target_value: '75%',
            target_parse_status: 'parseable',
            unit: 'percent',
            observed_value: 75,
            target_numeric: 75,
            attainment_pct: 100,
            task_done_count: 3,
            task_count: 4,
            note: 'Derived from linked task completion against a percent target.',
          },
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

    expect(result.tree[0]?.attainment).toMatchObject({
      state: 'attained',
      basis: 'metric_target_percent',
      metric: 'completion_pct',
      target_value: '75%',
      target_parse_status: 'parseable',
      unit: 'percent',
      observed_value: 75,
      target_numeric: 75,
      attainment_pct: 100,
      task_done_count: 3,
      task_count: 4,
    })
  })

  it('falls back to unmeasured goal attainment when payloads are old', async () => {
    const rawResponse = {
      tree: [
        makeRawGoalNode({
          metric: 'latency',
          target_value: 'fast enough',
          task_done_count: 1,
          task_count: 2,
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

    expect(result.tree[0]?.attainment).toMatchObject({
      state: 'unmeasured',
      basis: 'unmeasured',
      metric: 'latency',
      target_value: 'fast enough',
      target_parse_status: 'unparseable',
      task_done_count: 1,
      task_count: 2,
    })
  })

  it('retains keeper trust summary and latest event on goal detail payloads', async () => {
    const rawResponse = {
      goal: makeRawGoalNode(),
      linked_tasks: [],
      linked_keepers: [
        {
          name: 'keeper-sangsu',
          agent_name: 'sangsu',
          current_task_id: 'task-1',
          active_goal_ids: ['goal-1'],
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
          mutation_guard_summary: 'mutation_contract_not_observed',
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
      goal: makeRawGoalNode(),
      linked_tasks: [],
      linked_keepers: [
        {
          name: 'keeper-sangsu',
          agent_name: 'sangsu',
          current_task_id: null,
          active_goal_ids: ['goal-1'],
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
              state: 'matched_by_always_rule',
              summary: 'Matched by stored allow rule.',
              pending_count: 0,
            },
            execution: {
              sandbox_summary: 'docker / none',
              mutation_guard_summary: 'allowed_in_sandbox',
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
        state: 'matched_by_always_rule',
        summary: 'Matched by stored allow rule.',
        pending_count: 0,
      },
      execution_summary: {
        sandbox_summary: 'docker / none',
        mutation_guard_summary: 'allowed_in_sandbox',
        latest_receipt_at: '2026-04-23T00:10:00Z',
      },
    })
  })
})

describe('fetchKeeperConfig', () => {
  it('normalizes singleton string, numeric string, and boolean string fields', async () => {
    const rawResponse = {
      name: 'keeper-sangsu',
      active_goal_ids: ['goal-runtime'],
      autoboot_enabled: 'false',
      max_context_override: '64000',
      limits: {
        min_context_override_tokens: '64000',
        max_context_override_tokens: '1000000',
      },
      sandbox_profile: 'docker',
      network_mode: 'none',
      sandbox_last_error: 'sandbox docker exec failed',
      allowed_paths: '/tmp/workspace',
      effective_allowed_paths: ['/tmp/workspace'],
      prompt: {
        goal: 'Ship stable keeper ops',
        instructions: 'Prefer direct remediation',
        system_prompt_blocks: {
          constitution: { key: 'keeper.constitution', source: 'file', text: 'constitution text' },
          world: { key: 'keeper.world', source: 'override', text: 'world text' },
          capabilities: { key: 'keeper.capabilities', source: 'file', text: 'capabilities text' },
        },
        effective_system_prompt: 'full prompt',
        unified_system_prompt: 'unified prompt',
        unified_user_message_preview: 'world state',
      },
      execution: {
        models: 'llama:test-balanced',
        active_model: 'llama:test-balanced',
        per_provider_timeout_sec: 12.5,
        per_provider_timeout_mode: 'override',
        verify: 'true',
        selected_runtime_id: 'keeper_unified',
        selected_runtime_canonical: 'keeper_unified',
        runtime_options: ['keeper_unified', 'runpod_mtp.qwen36-35b-a3b-mtp'],
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
        deny_list: 'Execute',
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
        runtime_blocker_class: 'stale_fleet_batch',
        runtime_blocker_summary: 'Fleet batch paused after stale termination storm.',
        runtime_blocker_continue_gate: 'false',
      },
      runtime_trust: {
        disposition: 'Pass',
        disposition_reason: 'healthy',
        needs_attention: false,
      },
      workspace: {
        mention_targets: 'sangsu',
        bound_workspace_ids: 'default',
        active_goal_ids: ['goal-runtime'],
        active_goals: [
          { id: 'goal-runtime', title: 'Ship runtime clarity' },
        ],
        active_goal_count: '1',
        missing_active_goal_ids: [],
      },
      tools: {
        tool_access: ['tool_read_file'],
        resolved_allowlist: 'tool_read_file',
        tool_denylist: 'Execute',
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
    expect(result.autoboot_enabled).toBe(false)
    expect(result.max_context_override).toBe(64000)
    expect(result.limits).toEqual({
      min_context_override_tokens: 64000,
      max_context_override_tokens: 1000000,
    })
    expect(result.sandbox_profile).toBe('docker')
    expect(result.network_mode).toBe('none')
    expect(result.sandbox_last_error).toBe('sandbox docker exec failed')
    expect(result.execution.models).toEqual(['llama:test-balanced'])
    expect(result.execution.verify).toBe(true)
    expect(result.execution.selected_runtime_id).toBe('keeper_unified')
    expect(result.execution.selected_runtime_canonical).toBe('keeper_unified')
    expect(result.execution.runtime_options).toEqual(['keeper_unified', 'runpod_mtp.qwen36-35b-a3b-mtp'])
    expect(result.execution.per_provider_timeout_sec).toBe(12.5)
    expect(result.execution.per_provider_timeout_mode).toBe('override')
    expect(result.hooks?.destructive_check_tools).toEqual(['dynamic_boundary (Tool_dispatch.is_destructive)'])
    expect(result.hooks?.slots.pre_tool_use?.gates).toEqual(['keeper_deny_list'])
    // deny_list count is derived from the array (deny_list_count field dropped).
    expect(result.hooks?.deny_list).toEqual(['Execute'])
    // tool_access is a string list (was mistyped as unknown/{}); needed so the
    // denylist editor can echo it back to set_policy unchanged.
    expect(result.tools.tool_access).toEqual(['tool_read_file'])
    expect(result.sources.precedence).toEqual(['live_meta'])
    expect(result.metrics.total_cost_usd).toBe(0.12)
    expect(result.runtime.runtime_blocker_class).toBe('stale_fleet_batch')
    expect(result.runtime.runtime_blocker_summary).toBe('Fleet batch paused after stale termination storm.')
    expect(result.active_goal_ids).toEqual(['goal-runtime'])
    expect(result.workspace.active_goal_ids).toEqual(['goal-runtime'])
    expect(result.workspace.active_goals[0]?.title).toBe('Ship runtime clarity')
    expect(result.runtime_trust?.disposition).toBe('Pass')
  })

  it('normalizes default per-provider timeout mode without legacy label', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          name: 'keeper-sangsu',
          execution: {
            per_provider_timeout_sec: null,
            per_provider_timeout_mode: 'legacy-value',
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

    expect(result.execution.per_provider_timeout_sec).toBeNull()
    expect(result.execution.per_provider_timeout_mode).toBe('turn_budget_default')
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
      ['tool_route_recoverable_failure', '도구 라우팅 복구 가능 실패'],
      ['fiber_unresolved', 'Fiber 미해결'],
      ['stale_turn_timeout', '오래된 턴 만료'],
      ['awaiting_operator', '운영자 조치 대기'],
      ['awaiting_sandbox_egress', '샌드박스 egress 대기'],
      ['supervisor_paused', 'Supervisor 일시정지'],
      ['synthetic_stall', '합성 상태 정체'],
      ['self_imposed_idle', '자체 대기'],
      ['sdk_max_turns_exceeded', 'SDK 최대 턴 초과'],
      ['sdk_token_budget_exceeded', 'SDK 토큰 예산 초과'],
      ['sdk_cost_budget_exceeded', 'SDK 비용 예산 초과'],
      ['sdk_unrecognized_stop_reason', 'SDK 미식별 정지 사유'],
      ['sdk_idle_detected', 'SDK Idle 감지'],
      ['sdk_guardrail_violation', 'SDK 가드레일 위반'],
      ['sdk_tripwire_violation', 'SDK Tripwire 위반'],
      ['sdk_exit_condition_met', 'SDK 종료 조건 충족'],
    ] as const

    for (const [blockerClass, label] of cases) {
      const fetchMock = vi.fn().mockResolvedValue(
        new Response(
          JSON.stringify({
            name: 'keeper-sangsu',
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
  it('ensures dashboard auth before posting runtime_id changes', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        name: 'keeper-sangsu',
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

    const result = await patchKeeperConfig('keeper-sangsu', { runtime_id: 'b.two' })

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    expect(devTokenMock.ensureDevToken.mock.invocationCallOrder[0]).toBeLessThan(
      fetchMock.mock.invocationCallOrder[0] ?? Number.POSITIVE_INFINITY,
    )
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/keepers/keeper-sangsu/config')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({ runtime_id: 'b.two' })
    expect(result.execution.selected_runtime_id).toBe('b.two')
  })
})

describe('dashboard runtime probe API', () => {
  it('ensures dashboard auth before fetching runtime probe status', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        generated_at: '2026-06-10T12:00:00Z',
        probe: {
          status: 'ok',
          probe_ok: true,
          summary: { runtimes: 1, reachable: 1, failed: 0 },
          providers: [],
        },
      }), {
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
})

describe('runtime.toml raw config API', () => {
  it('fetches and normalizes the raw runtime.toml source', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        path: '/tmp/.masc/config/runtime.toml',
        file_name: 'runtime.toml',
        source_text: '[runtime]\ndefault = "runpod_mtp.qwen"\n',
        reloaded: false,
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
    expect(result.reloaded).toBe(false)
  })

  it('posts the full raw TOML source through source_text', async () => {
    const sourceText = '[runtime]\ndefault = "openai.gpt"\n'
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        path: '/tmp/.masc/config/runtime.toml',
        file_name: 'runtime.toml',
        source_text: sourceText,
        reloaded: true,
      }), {
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
    expect(result.reloaded).toBe(true)
    expect(result.source_text).toBe(sourceText)
  })

  it('posts runtime routing patches without client-side TOML text', async () => {
    const sourceText = '[runtime]\ndefault = "openai.gpt"\nstructured_judge = "openai.gpt"\n'
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        path: '/tmp/.masc/config/runtime.toml',
        file_name: 'runtime.toml',
        source_text: sourceText,
        reloaded: true,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await patchRuntimeRouting('structured_judge', 'openai.gpt')

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/runtime/config/routing')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      lane: 'structured_judge',
      runtime_id: 'openai.gpt',
    })
    expect(result.source_text).toBe(sourceText)
  })

  it('posts ordered media failover routing patches', async () => {
    const sourceText = '[runtime]\nmedia_failover = ["rt-a", "rt-b"]\n'
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        path: '/tmp/.masc/config/runtime.toml',
        file_name: 'runtime.toml',
        source_text: sourceText,
        reloaded: true,
      }), {
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
      new Response(JSON.stringify({
        ok: true,
        path: '/tmp/.masc/config/runtime.toml',
        file_name: 'runtime.toml',
        source_text: sourceText,
        reloaded: true,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await patchRuntimeAssignment('sangsu', null)

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/runtime/config/assignment')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      keeper_name: 'sangsu',
      runtime_id: null,
    })
    expect(result.source_text).toBe(sourceText)
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
            max_output_tokens: 65536,
            supports_tool_choice: true,
            supports_required_tool_choice: true,
            supports_named_tool_choice: true,
            supports_parallel_tool_calls: true,
            supports_extended_thinking: true,
            supports_response_format_json: true,
            supports_structured_output: true,
            supports_native_streaming: true,
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
              source: 'oas-provider-config',
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
              source: 'oas-provider-config-model',
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
                  requires_per_keeper_bridging_for_bound_actor_tools: false,
                  identity_runtime_mcp_header_keys: ['x-masc-keeper'],
                  argv_prompt_preflight: false,
                  uses_anthropic_caching: false,
                  max_turns_per_attempt: 3,
                  tolerates_bound_actor_fallback: true,
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
                  supports_native_streaming: true,
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
                match_prefixes: ['Qwen/'],
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
            discovery: {
              healthy: true,
              discovered_model: 'Qwen/Qwen3-32B',
              ctx_size: 200000,
            },
          },
          {
            provider: 'openai.gpt',
            runtime_id: 'openai.gpt',
            temperature: null,
          },
        ],
        assignment_governance: {
          schema: 'masc.runtime_assignment_governance.v1',
          source: 'runtime.toml',
          status: 'degraded',
          degraded: true,
          operator_action_required: true,
          blast_radius: 'single_runtime_assignment_pin',
          assignment_count: 2,
          assigned_runtime_count: 1,
          default_assignment_count: 0,
          default_runtime_id: 'runpod_mtp.qwen',
          librarian_runtime_id: 'ollama_cloud.minimax-m3',
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
          terminal_reason: 'missing_oas_catalog_models',
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
            { route_name: 'runtime.librarian', runtime_id: 'mimo.mimo-v2.5-pro' },
          ],
          dropped_media_failover: ['mimo.mimo-v2.5-pro'],
          dropped_lane_candidates: [
            { lane_id: 'coding', runtime_ids: ['mimo.mimo-v2.5-pro'] },
          ],
          dropped_lanes: [
            { lane_id: 'mimo-only', runtime_ids: ['mimo.mimo-v2.5-pro'] },
          ],
          next_action: 'Add the listed provider/model rows to oas-models.toml.',
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
    expect(result.providers[0]?.max_output_tokens).toBe(65536)
    expect(result.providers[0]?.supports_tool_choice).toBe(true)
    expect(result.providers[0]?.supports_required_tool_choice).toBe(true)
    expect(result.providers[0]?.supports_named_tool_choice).toBe(true)
    expect(result.providers[0]?.supports_parallel_tool_calls).toBe(true)
    expect(result.providers[0]?.supports_extended_thinking).toBe(true)
    expect(result.providers[0]?.supports_response_format_json).toBe(true)
    expect(result.providers[0]?.supports_structured_output).toBe(true)
    expect(result.providers[0]?.supports_native_streaming).toBe(true)
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
        ?.identity_runtime_mcp_header_keys,
    ).toEqual(['x-masc-keeper'])
    expect(result.providers[0]?.declared_spec?.model?.capabilities?.supports_structured_output).toBe(true)
    expect(result.providers[0]?.declared_spec?.model?.capabilities?.supports_parallel_tool_calls).toBe(true)
    expect(result.providers[0]?.declared_spec?.model?.capabilities?.supports_system_prompt).toBe(true)
    expect(result.providers[0]?.declared_spec?.model?.capabilities?.supports_seed_with_images).toBe(true)
    expect(result.providers[0]?.declared_spec?.model?.capabilities?.supports_code_execution).toBe(true)
    expect(result.providers[0]?.declared_spec?.binding?.max_concurrent).toBe(4)
    expect(result.providers[1]?.temperature).toBeNull()
    expect(result.providers[0]?.discovery?.discovered_model).toBe('Qwen/Qwen3-32B')
    expect(result.providers[0]?.discovery?.ctx_size).toBe(200000)
    expect(result.assignment_governance?.status).toBe('degraded')
    expect(result.assignment_governance?.assignment_count).toBe(2)
    expect(result.assignment_governance?.assigned_runtimes).toEqual(['openai.gpt'])
    expect(result.assignment_governance?.assignments[0]?.keeper).toBe('budgettest')
    expect(result.startup_degradation?.status).toBe('degraded')
    expect(result.startup_degradation?.terminal_reason).toBe('missing_oas_catalog_models')
    expect(result.startup_degradation?.effective_default_runtime_id).toBe('runpod_mtp.qwen')
    expect(result.startup_degradation?.missing_catalog_models[0]?.provider_label).toBe('openai_compat')
    expect(result.startup_degradation?.disabled_runtime_ids).toEqual(['mimo.mimo-v2.5-pro'])
    expect(result.startup_degradation?.dropped_assignments[0]?.keeper_name).toBe('budgettest')
    expect(result.startup_degradation?.dropped_routes[0]?.route_name).toBe('runtime.librarian')
    expect(result.startup_degradation?.dropped_lane_candidates[0]?.lane_id).toBe('coding')
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
          primary_coverage_stage: 'oas',
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
              stop_reason: 'turn_budget_exhausted(3/3)',
              turn_lane: 'text_only',
              input_tokens: null,
              output_tokens: null,
              latency_ms: null,
              cost_usd: null,
              tools_count: 0,
              usage_reported: false,
              telemetry_reported: false,
              coverage_reason: 'missing_usage_and_inference',
              coverage_stage: 'oas',
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
    expect(metric.primary_coverage_stage).toBe('oas')
    expect(metric.primary_coverage_reason).toBe('missing_usage_and_inference')
    expect(metric.coverage_reason_counts).toEqual([
      { reason: 'missing_usage_and_inference', count: 1 },
    ])
    expect(metric.total_input_tokens).toBeNull()
    expect(metric.total_cost_usd).toBeNull()
    expect(metric.recent_entries?.[0]?.outcome).toBe('success')
    expect(metric.recent_entries?.[0]?.stop_reason).toBe('turn_budget_exhausted(3/3)')
    expect(metric.recent_entries?.[0]?.turn_lane).toBe('text_only')
    expect(metric.recent_entries?.[0]?.input_tokens).toBeNull()
    expect(metric.recent_entries?.[0]?.latency_ms).toBeNull()
    expect(metric.recent_entries?.[0]?.usage_reported).toBe(false)
    expect(metric.recent_entries?.[0]?.telemetry_reported).toBe(false)
    expect(metric.recent_entries?.[0]?.coverage_reason).toBe('missing_usage_and_inference')
    expect(metric.recent_entries?.[0]?.coverage_stage).toBe('oas')
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
})

describe('fetchKeeperDecisions', () => {
  it('redacts legacy model_used labels from decision rows', async () => {
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
            model_used: 'private-provider:claude',
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

    expect(result.events[0]?.model_used).toBeNull()
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
})

describe('fetchLogs', () => {
  function stubLogsFetch() {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ total: 0, entries: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)
    return fetchMock
  }

  function requestedUrl(fetchMock: ReturnType<typeof vi.fn>): string {
    return String(fetchMock.mock.calls[0]?.[0])
  }

  it('sets before_seq for backward "load older" paging', async () => {
    const fetchMock = stubLogsFetch()

    await fetchLogs({ limit: 200, level: 'INFO', before_seq: 4096 })

    const params = new URLSearchParams(requestedUrl(fetchMock).split('?')[1] ?? '')
    expect(params.get('before_seq')).toBe('4096')
    expect(params.get('limit')).toBe('200')
    expect(params.get('level')).toBe('INFO')
  })

  it('omits before_seq when negative (no cursor)', async () => {
    const fetchMock = stubLogsFetch()

    await fetchLogs({ before_seq: -1 })

    const params = new URLSearchParams(requestedUrl(fetchMock).split('?')[1] ?? '')
    expect(params.has('before_seq')).toBe(false)
  })

  it('combines before_seq and since_seq into a bounded window', async () => {
    const fetchMock = stubLogsFetch()

    await fetchLogs({ since_seq: 10, before_seq: 20 })

    const params = new URLSearchParams(requestedUrl(fetchMock).split('?')[1] ?? '')
    expect(params.get('since_seq')).toBe('10')
    expect(params.get('before_seq')).toBe('20')
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
        keeper_assignments: [{ keeper: 'analyst', runtime_id: 'openai.gpt-4o' }],
        librarian_runtime_id: null,
        structured_judge_runtime_id: null,
        cross_verifier_runtime_id: null,
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
    expect(result.model_routing.keeper_assignments[0]?.keeper).toBe('analyst')
  })
})
