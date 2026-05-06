import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  fetchDashboardShell,
  fetchDashboardGovernance,
  fetchDashboardGoalDetail,
  fetchDashboardGoalsTree,
  fetchDashboardTools,
  fetchKeeperConfig,
  fetchRuntimeModelMetrics,
  fetchTlcResults,
  fetchToolQuality,
} from './dashboard'
import { keeperRuntimeBlockerLabel } from '../lib/keeper-runtime-display'

afterEach(() => {
  vi.unstubAllGlobals()
})

function makeRawGoalNode(overrides: Record<string, unknown> = {}) {
  return {
    id: 'goal-1',
    title: 'Goal 1',
    horizon: 'quarterly',
    status: 'active',
    status_color: '#fff',
    phase: 'executing',
    phase_color: '#0ea5e9',
    health: 'on_track',
    health_color: '#4ade80',
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
  it('uses the light shell query when requested', async () => {
    const rawResponse = {
      status: { project: 'default' },
      counts: { agents: 1, tasks: 2, keepers: 3 },
    }
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await fetchDashboardShell({ light: true })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/shell?light=true')
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
              requested_by: { kind: 'operator', id: 'planner' },
              policy_snapshot: {
                principals: [{ kind: 'keeper', id: 'keeper-alpha' }],
                eligible_principals: [{ kind: 'keeper', id: 'keeper-alpha' }],
                required_verdicts: 1,
              },
              votes: [
                {
                  principal: { kind: 'keeper', id: 'keeper-alpha', display_name: 'keeper-alpha' },
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
          cascade_name: 'keeper_unified',
          approval_profile: 'strict',
          cascade_outcome: 'passed_to_next_model',
          latest_execution_outcome: 'completed',
          latest_execution_at: '2026-04-23T00:10:00Z',
          latest_receipt: { outcome: 'completed' },
          runtime_trust: {
            disposition: 'Pause',
            disposition_reason: 'approval_waiting',
            needs_attention: true,
            attention_reason: 'approval_pending',
            next_human_action: 'resolve_approval',
            approval: {
              state: 'pending',
              summary: '1 approval request is waiting for an operator.',
              pending_count: 1,
            },
            execution: {
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
        disposition: 'Pause',
        disposition_reason: 'approval_waiting',
        needs_attention: true,
        attention_reason: 'approval_pending',
        next_human_action: 'resolve_approval',
        approval_state: {
          state: 'pending',
          summary: '1 approval request is waiting for an operator.',
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
          keeper_turn_id: 42,
          title: 'Approval pending',
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
          cascade_name: 'keeper_unified',
          approval_profile: null,
          cascade_outcome: null,
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
              tool_contract_result: 'allowed_in_sandbox',
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
        tool_contract_result: 'allowed_in_sandbox',
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
      sandbox_profile: 'docker',
      network_mode: 'none',
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
        per_provider_timeout_sec: 12.5,
        per_provider_timeout_mode: 'override',
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
      runtime_trust: {
        disposition: 'Pass',
        disposition_reason: 'healthy',
        needs_attention: false,
      },
      coordination: {
        mention_targets: 'sangsu',
        joined_room_ids: 'default',
        active_goal_ids: ['goal-runtime'],
        active_goals: [
          { id: 'goal-runtime', title: 'Ship runtime clarity', horizon: 'mid' },
        ],
        active_goal_count: '1',
        missing_active_goal_ids: [],
      },
      tools: {
        tool_access: { kind: 'preset', preset: 'coding' },
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
    expect(result.execution.per_provider_timeout_sec).toBe(12.5)
    expect(result.execution.per_provider_timeout_mode).toBe('override')
    expect(result.hooks?.destructive_check_tools).toEqual(['dynamic_boundary (Tool_dispatch.is_destructive)'])
    expect(result.hooks?.slots.pre_tool_use?.gates).toEqual(['keeper_deny_list'])
    expect(result.sources.precedence).toEqual(['live_meta'])
    expect(result.sources.cascade_catalog_source_kind).toBe('toml')
    expect(result.sources.cascade_catalog_source_path).toBe('/tmp/config/cascade.toml')
    expect(result.sources.cascade_runtime_json_path).toBe('/tmp/config/cascade.json')
    expect(result.sources.cascade_runtime_json_editable).toBe(false)
    expect(result.metrics.total_cost_usd).toBe(0.12)
    expect(result.runtime.presence_keepalive_sec).toBe(30)
    expect(result.active_goal_ids).toEqual(['goal-runtime'])
    expect(result.coordination.active_goal_ids).toEqual(['goal-runtime'])
    expect(result.coordination.active_goals[0]?.title).toBe('Ship runtime clarity')
    expect(result.runtime_trust?.disposition).toBe('Pass')
  })

  it('preserves terminal runtime blocker classes through config fetch and display labeling', async () => {
    const cases = [
      ['no_tool_capable_provider', '도구 실행 Provider 없음'],
      ['provider_runtime_error', 'Provider 런타임 오류'],
      ['tool_required_unsatisfied', '필수 도구 미충족'],
      ['fiber_unresolved', 'Fiber 미해결'],
      ['stale_turn_timeout', '오래된 턴 만료'],
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
