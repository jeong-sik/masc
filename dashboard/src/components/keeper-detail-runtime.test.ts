import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

import type { DashboardMissionKeeperBrief, Keeper, KeeperConfig } from '../types'
import type { KeeperCompositeSnapshot, KeeperRuntimeTraceResponse } from '../api/keeper'
import {
  AllowlistPreview,
  BudgetSourceBadge,
  RuntimeLensSection,
  RuntimeSignals,
  KeeperSecretProjectionPanel,
  budgetSourceLabel,
  budgetSourceTone,
  filterSignalGroups,
  deriveKeeperLiveTruth,
  resolveAllowlistPreview,
  resolveKeeperCurrentTaskLabel,
} from './keeper-detail-runtime'
import {
  resolveKeeperObservedToolAudit,
  resolveKeeperToolPolicy,
} from './keeper-detail-source'

afterEach(() => {
  cleanup()
})

describe('resolveKeeperToolPolicy', () => {
  it('uses keeper config as the authoritative policy source', () => {
    const keeperConfig = {
      tools: {
        tool_access: [],
        resolved_allowlist: ['mcp__masc__masc_board_post'],
        tool_denylist: ['mcp__masc__masc_board_delete'],
        active_masc_tool_count: 1,
        active_keeper_tool_count: 0,
        total_active: 1,
      },
    } satisfies Pick<KeeperConfig, 'tools'>

    expect(resolveKeeperToolPolicy(keeperConfig, 'loaded')).toEqual({
      source: 'keeper_config',
      resolvedAllowlist: ['mcp__masc__masc_board_post'],
    })
  })

  it('reports loading instead of inventing defaults before config arrives', () => {
    expect(resolveKeeperToolPolicy(null, 'loading')).toEqual({
      source: 'loading',
      resolvedAllowlist: [],
    })
  })

  it('reports none after config load when no policy payload is available', () => {
    expect(resolveKeeperToolPolicy(null, 'loaded')).toEqual({
      source: 'none',
      resolvedAllowlist: [],
    })
  })

  it('preserves an explicit config error state', () => {
    expect(resolveKeeperToolPolicy(null, 'error')).toEqual({
      source: 'error',
      resolvedAllowlist: [],
    })
  })
})

describe('resolveKeeperObservedToolAudit', () => {
  it('prefers mission brief audit over dashboard summary fallback', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
      latest_tool_names: ['dashboard_summary_tool'],
      latest_tool_call_count: 1,
      tool_audit_source: 'keeper_metrics',
      tool_audit_at: '2026-04-01T12:00:00Z',
    }

    const missionBrief: DashboardMissionKeeperBrief = {
      name: 'sangsu',
      agent_name: 'sangsu',
      status: 'active',
      latest_tool_names: ['mission_brief_tool'],
      latest_tool_call_count: 3,
      tool_audit_source: 'heartbeat_result',
      tool_audit_at: '2026-04-02T09:30:00Z',
    }

    expect(resolveKeeperObservedToolAudit(keeper, missionBrief)).toEqual({
      source: 'mission_brief',
      latestToolNames: ['mission_brief_tool'],
      latestToolCallCount: 3,
      toolAuditSource: 'heartbeat_result',
      toolAuditAt: '2026-04-02T09:30:00Z',
    })
  })

  it('falls back to dashboard summary audit when mission has no audit payload', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
      latest_tool_names: ['dashboard_summary_tool'],
      latest_tool_call_count: 1,
      tool_audit_source: 'keeper_metrics',
      tool_audit_at: '2026-04-01T12:00:00Z',
    }

    const missionBrief: DashboardMissionKeeperBrief = {
      name: 'sangsu',
      agent_name: 'sangsu',
      status: 'active',
    }

    expect(resolveKeeperObservedToolAudit(keeper, missionBrief)).toEqual({
      source: 'dashboard_summary',
      latestToolNames: ['dashboard_summary_tool'],
      latestToolCallCount: 1,
      toolAuditSource: 'keeper_metrics',
      toolAuditAt: '2026-04-01T12:00:00Z',
    })
  })

  it('does not treat mission compatibility allowlists as observed audit freshness', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
      latest_tool_names: ['dashboard_summary_tool'],
      latest_tool_call_count: 1,
      tool_audit_source: 'keeper_metrics',
      tool_audit_at: '2026-04-01T12:00:00Z',
    }

    const missionBrief = {
      name: 'sangsu',
    } as DashboardMissionKeeperBrief

    expect(resolveKeeperObservedToolAudit(keeper, missionBrief)).toEqual({
      source: 'dashboard_summary',
      latestToolNames: ['dashboard_summary_tool'],
      latestToolCallCount: 1,
      toolAuditSource: 'keeper_metrics',
      toolAuditAt: '2026-04-01T12:00:00Z',
    })
  })

  it('reports none when neither projection carries observed audit data', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
    }

    expect(resolveKeeperObservedToolAudit(keeper, null)).toEqual({
      source: 'none',
      latestToolNames: [],
      latestToolCallCount: null,
      toolAuditSource: null,
      toolAuditAt: null,
    })
  })
})

describe('resolveKeeperCurrentTaskLabel', () => {
  it('shows the active task when one is bound', () => {
    const keeper: Keeper = {
      name: 'config-provenance',
      status: 'busy',
      agent: {
        name: 'keeper-config-provenance-agent',
        current_task: 'task-046',
      },
    }

    expect(resolveKeeperCurrentTaskLabel(keeper)).toBe('task-046')
  })

  it('shows unassigned when the runtime reported no bound task', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
      agent: {
        name: 'keeper-sangsu-agent',
        current_task: null,
      },
    }

    expect(resolveKeeperCurrentTaskLabel(keeper)).toBe('unassigned')
  })

  it('treats an empty current task string as unassigned', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
      agent: {
        name: 'keeper-sangsu-agent',
        current_task: '   ',
      },
    }

    expect(resolveKeeperCurrentTaskLabel(keeper)).toBe('unassigned')
  })

  it('returns unlinked when no keeper payload is available', () => {
    expect(resolveKeeperCurrentTaskLabel(null)).toBe('unlinked')
  })

  it('keeps not_collected for online keepers without linked agent payload', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
    }

    expect(resolveKeeperCurrentTaskLabel(keeper)).toBe('not_collected')
  })
})

describe('resolveAllowlistPreview', () => {
  it('keeps only the requested prefix and reports the remainder', () => {
    expect(resolveAllowlistPreview(['a', 'b', 'c', 'd'], 2)).toEqual({
      visibleTools: ['a', 'b'],
      hiddenCount: 2,
    })
  })

  it('clamps zero and negative limits to an empty preview', () => {
    expect(resolveAllowlistPreview(['a', 'b'], 0)).toEqual({
      visibleTools: [],
      hiddenCount: 2,
    })
    expect(resolveAllowlistPreview(['a', 'b'], -3)).toEqual({
      visibleTools: [],
      hiddenCount: 2,
    })
  })
})

describe('budget source badges', () => {
  it.each([
    ['env', 'neutral', 'env'],
    ['override', 'warn', 'override'],
    ['override_invalid', 'bad', 'invalid'],
  ] as const)('maps %s to StatusChip tone %s', (source, tone, label) => {
    expect(budgetSourceTone(source)).toBe(tone)
    expect(budgetSourceLabel(source)).toBe(label)
  })

  it('renders through the shared StatusChip primitive', () => {
    render(h(BudgetSourceBadge, { source: 'override_invalid' }))

    const chip = screen.getByText('invalid').closest('[data-status-chip]')
    expect(chip).toHaveAttribute('data-status-chip-tone', 'bad')
    expect(chip).toHaveAttribute('data-status-chip-uppercase', 'true')
  })
})

describe('AllowlistPreview', () => {
  it('renders the empty fallback when there are no tools', () => {
    render(h(AllowlistPreview, {
      tools: [],
      emptyLabel: 'none',
      previewLimit: 12,
    }))

    expect(screen.getByText('none')).toBeInTheDocument()
    expect(screen.queryByRole('button')).not.toBeInTheDocument()
  })

  it('does not show a toggle when the tool count is exactly at the preview limit', () => {
    const tools = Array.from({ length: 12 }, (_, index) => `tool-${index + 1}`)
    render(h(AllowlistPreview, {
      tools,
      emptyLabel: 'none',
      previewLimit: 12,
    }))

    expect(screen.getByText('tool-12')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /허용된 도구/ })).not.toBeInTheDocument()
  })

  it('collapses long allowlists until explicitly expanded', () => {
    const tools = Array.from({ length: 15 }, (_, index) => `tool-${index + 1}`)
    render(h(AllowlistPreview, {
      tools,
      emptyLabel: 'none',
      previewLimit: 12,
    }))

    expect(screen.getByText('tool-1')).toBeInTheDocument()
    expect(screen.getByText('tool-12')).toBeInTheDocument()
    expect(screen.queryByText('tool-13')).not.toBeInTheDocument()
    const toggle = screen.getByRole('button', { name: '허용된 도구 나머지 3개 보기' })
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(screen.getByText('나머지 3개 보기')).toBeInTheDocument()

    fireEvent.click(toggle)

    expect(screen.getByText('tool-13')).toBeInTheDocument()
    expect(screen.getByText('tool-15')).toBeInTheDocument()
    expect(screen.getByText('접기')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: '허용된 도구 접기' })).toHaveAttribute('aria-expanded', 'true')
  })
})

describe('RuntimeSignals', () => {
  it('renders metrics_window top lists as visual distributions', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
      metrics_window: {
        fallback_rate: 0.15,
        top_tools: [
          { tool: 'masc_board_post', count: 7 },
          { tool: 'masc_status', count: 4 },
        ],
        top_models: [
          { model: 'gpt-5', count: 5 },
        ],
        top_work_kinds: [
          { kind: 'planning', count: 3 },
        ],
      },
    }

    render(h(RuntimeSignals, { keeper }))

    expect(screen.getByText('주요 도구')).toBeInTheDocument()
    expect(screen.queryByText('주요 모델')).not.toBeInTheDocument()
    expect(screen.getByText('주요 작업 종류')).toBeInTheDocument()
    expect(screen.getByText('masc_board_post')).toBeInTheDocument()
    expect(screen.queryByText('gpt-5')).not.toBeInTheDocument()
    expect(screen.getByText('planning')).toBeInTheDocument()
  })

  it('filters runtime signal rows by label via the search input', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
      metrics_window: {
        fallback_rate: 0.12,
        model_fallback_rate: 0.05,
        memory_pass_rate: 0.88,
        memory_avg_score: 0.73,
      },
    }

    render(h(RuntimeSignals, { keeper }))

    // Before filtering: labels from multiple groups are visible.
    expect(screen.getByText('전체 폴백')).toBeInTheDocument()
    expect(screen.getByText('메모리 통과율')).toBeInTheDocument()

    const input = screen.getByPlaceholderText('신호 지표 필터 (예: 폴백, 메모리, 컴팩션)') as HTMLInputElement
    fireEvent.input(input, { target: { value: '메모리' } })

    // Non-matching labels are gone, matching ones remain.
    expect(screen.queryByText('전체 폴백')).not.toBeInTheDocument()
    expect(screen.getByText('메모리 통과율')).toBeInTheDocument()
    expect(screen.getByText('메모리 평균 점수')).toBeInTheDocument()
  })

  it('shows the filter-specific empty state when no rows match', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
      metrics_window: {
        fallback_rate: 0.12,
      },
    }

    render(h(RuntimeSignals, { keeper }))

    const input = screen.getByPlaceholderText('신호 지표 필터 (예: 폴백, 메모리, 컴팩션)') as HTMLInputElement
    fireEvent.input(input, { target: { value: 'nonexistent-zzz' } })

    expect(screen.getByText(/필터 결과 없음/)).toBeInTheDocument()
  })
})

describe('RuntimeLensSection', () => {
  const lane = (
    key: string,
    label: string,
    eventCount: number,
    terminalStatus: string,
    gapCodes: string[] = [],
  ) => ({
    lane: key,
    label,
    event_count: eventCount,
    terminal_status: terminalStatus,
    completeness: eventCount > 0 ? 'complete' : 'incomplete',
    gap_codes: gapCodes,
    gap_badge: gapCodes[0] ?? null,
    events: eventCount > 0 ? [{ event: `${key}_event`, count: eventCount }] : [],
  })

  function runtimeTraceFixture(): KeeperRuntimeTraceResponse {
    return {
      keeper: 'sangsu',
      trace_id: 'trace-lens',
      turn_id: 7,
      manifest_path: '/tmp/runtime-manifest.jsonl',
      manifest_path_present: true,
      manifest_total_rows: 6,
      manifest_returned_rows: 6,
      receipt_returned_rows: 1,
      turn_identity: {
        requested_keeper_turn_id: 7,
        manifest_keeper_turn_ids: [7],
        receipt_turn_counts: [7],
        max_oas_turn_count: 3,
        provider_lane_resolved_count: 1,
        provider_attempt_started_count: 1,
        provider_attempt_finished_count: 1,
        checkpoint_saved_count: 1,
        event_bus_correlated_count: 1,
        memory_injected_count: 1,
        memory_flushed_count: 1,
        receipt_appended_count: 1,
        turn_finished_count: 1,
      },
      provider_attempts: {
        started_count: 1,
        finished_count: 1,
        terminal_status: 'timeout',
        terminal_error: 'Timeout after 120s',
        terminal_exception_kind: 'outer_oas_timeout',
        attempts: [],
      },
      event_bus: {
        event_bus_correlated_count: 1,
        correlation_ids: ['corr-1'],
        run_ids: ['run-1'],
        context_compact_started_count: 1,
        context_compacted_count: 1,
        last_compaction: null,
      },
      memory: {
        memory_injected_count: 1,
        memory_injected_present_count: 1,
        memory_flushed_count: 1,
        memory_flush_success_count: 1,
        memory_flush_error_count: 0,
        episodes_flushed: 2,
        procedures_flushed: 1,
      },
      runtime_lens: {
        turn_clock: {
          trace_id: 'trace-lens',
          keeper_turn_id: 7,
          max_oas_turn_count: 3,
          terminal_event_present: true,
          terminal_event: 'turn_finished',
          manifest_total_rows: 6,
        },
        axes: {
          lifecycle: {
            turn_started_count: 1,
            phase_gate_decided_count: 1,
            pre_dispatch_blocked_count: 0,
            receipt_appended_count: 1,
            turn_finished_count: 1,
            terminal_status: 'finished',
          },
          provider_lane: {
            resolved: true,
            status: 'error',
            resolved_lane: 'inline',
          },
          provider_attempt: {
            started_count: 1,
            finished_count: 1,
            terminal_status: 'timeout',
          },
          payload_role: {
            counts: {},
          },
          source_clock: {
            counts: {},
          },
          claim_scope: {
            present: false,
            source: 'tool_call_log',
            status: 'not_observed',
            result: null,
            mode: null,
            scoped: null,
            active_goal_ids: [],
            effective_goal_ids: [],
            fallback_reason: null,
            matched_goal_id: null,
            excluded_count: null,
            claimed_task_id: null,
            claimed_goal_id: null,
          },
          config_drift: {
            present: false,
            status: 'ok',
            error: null,
            has_live_override: false,
            runtime_override: false,
            override_fields: [],
            default_runtime_id: null,
            live_runtime_id: null,
            active_config_root: null,
            active_config_root_source: null,
            default_manifest_path: null,
          },
          context: {
            context_injected_count: 1,
            context_compacted_event_count: 1,
            event_bus_correlated_count: 1,
            context_compact_started_count: 1,
            context_compacted_count: 1,
            checkpoint_loaded_count: 1,
            checkpoint_saved_count: 1,
            state_snapshot_sidecar_saved_count: 1,
            active_open_loop_count: 2,
            last_compaction: null,
          },
          memory: {
            memory_injected_count: 1,
            memory_injected_present_count: 1,
            memory_flushed_count: 1,
            memory_flush_success_count: 1,
            memory_flush_error_count: 0,
            episodes_flushed: 2,
            procedures_flushed: 1,
          },
        },
        swimlanes: {
          keeper: lane('keeper', 'Keeper', 2, 'finished'),
          masc_policy_runtime: lane('masc_policy_runtime', 'MASC Runtime', 1, 'error'),
          oas_agent: lane('oas_agent', 'OAS', 2, 'checkpoint_saved'),
          provider: lane('provider', 'Provider', 2, 'timeout'),
          tool_runtime: lane('tool_runtime', 'Tool Runtime', 0, 'not_observed'),
          memory_context: lane('memory_context', 'Memory/Context', 3, 'flushed'),
        },
        clock_edges: [
          {
            edge_id: 'edge-provider-start',
            lane: 'provider',
            event: 'provider_attempt_started',
            status: 'started',
            observed_at: '2026-05-13T00:00:03Z',
            source_clock: 'wall',
            started_at: '2026-05-13T00:00:03Z',
            finished_at: null,
            trace_id: 'trace-lens',
            keeper_turn_id: 7,
            oas_turn_count: 2,
            provider_attempt_id: 'trace-lens:keeper-7:provider-attempt-1',
            tool_batch_id: null,
            checkpoint_id: null,
            compaction_id: null,
            event_bus_correlation_id: 'corr-1',
            event_bus_run_id: 'run-1',
            event_bus_event_count: 2,
            event_bus_payload_kinds: ['tool_called', 'tool_completed'],
            parent_event_id: null,
            caused_by: null,
            links: {
              receipt_path: null,
              checkpoint_path: null,
              tool_call_log_path: '/tmp/tool-calls.jsonl',
            },
          },
        ],
        clock_groups: [
          {
            group_type: 'event_bus_correlation',
            group_id: 'corr-1',
            edge_count: 1,
            edge_ids: ['edge-provider-start'],
            lanes: ['provider'],
            events: ['provider_attempt_started'],
            statuses: ['started'],
            first_observed_at: '2026-05-13T00:00:03Z',
            last_observed_at: '2026-05-13T00:00:03Z',
            closed: true,
            terminal_events: ['event_bus_correlated'],
            parent_event_ids: [],
            caused_by: [],
            event_bus_event_count: 2,
            event_bus_payload_kinds: ['tool_called', 'tool_completed'],
          },
        ],
        gaps: [],
      },
      health: 'partial',
      linked_artifacts: {
        receipts: [
          {
            kind: 'execution_receipt',
            path: '/tmp/receipt.jsonl',
            present: true,
            file_stat: { size: 120 },
          },
        ],
        checkpoints: [
          {
            kind: 'oas_checkpoint',
            path: '/tmp/checkpoint.json',
            present: false,
            file_stat: null,
          },
        ],
        tool_call_logs: [
          {
            kind: 'tool_call_log',
            path: '/tmp/tool-calls.jsonl',
            present: true,
            file_stat: { size: 80 },
          },
        ],
      },
      manifest_rows: [{ event: 'Turn_started', trace_id: 'trace-lens' }],
      receipts: [{ terminal_reason_code: 'completed' }],
      stale_reason: null,
    }
  }

  function compositeFixture(overrides: Partial<KeeperCompositeSnapshot> = {}): KeeperCompositeSnapshot {
    const base: KeeperCompositeSnapshot = {
      keeper: 'sangsu',
      correlation_id: 'keeper:sangsu:1',
      run_id: 'run-1',
      ts: 1_778_688_700,
      phase: 'running',
      turn_phase: 'idle',
      decision: { stage: 'undecided' },
      runtime: { state: 'idle' },
      compaction: { stage: 'accumulating' },
      circuit_breaker: { state: 'clean' },
      measurement: { captured: false },
      invariants: {
        phase_turn_alignment: true,
        no_runtime_before_measurement: true,
        compaction_atomicity: true,
        event_priority_monotone: true,
        phase_derivation_agreement: true,
      },
      phase_diagnosis: {
        current_phase: 'running',
        derived_phase: 'running',
        can_execute_turn: true,
        conditions: {
          launch_pending: false,
          fiber_alive: true,
          heartbeat_healthy: true,
          turn_healthy: true,
          context_within_budget: true,
          context_handoff_needed: false,
          compaction_active: false,
          handoff_active: false,
          operator_paused: false,
          stop_requested: false,
          restart_budget_remaining: true,
          backoff_elapsed: false,
          guardrail_triggered: false,
          drain_complete: false,
          context_overflow: false,
          compact_retry_exhausted: false,
          terminal_failure_latched: false,
        },
        determining_condition: 'running_fiber_alive',
        rows: [],
      },
      is_live: false,
      idle_seconds: 117,
      last_turn_ts: 1_778_688_606,
      last_outcome: null,
      execution: {
        latest_receipt_present: true,
        recorded_at: '2026-05-13T16:10:14Z',
        outcome: 'receipt_done',
        terminal_reason_code: 'completed',
        operator_disposition: 'pass',
        operator_disposition_reason: 'healthy',
        model_used: null,
        stop_reason: 'completed',
        duration_ms: 16000,
        error: null,
        runtime: null,
      },
      runtime_attention: {
        state: 'blocked',
        needs_attention: true,
        blocked: true,
        fiber_stop_requested: false,
        reason: 'healthy',
        raw_phase: 'running',
        is_live: false,
        source: 'execution_receipt',
      },
      recommended_actions: [],
      fsm_guard_violations: 0,
      fsm_guard_violation_breakdown: [],
    }
    return { ...base, ...overrides }
  }

  it('renders axis summary, swimlanes, and gap badges', () => {
    render(h(RuntimeLensSection, { trace: runtimeTraceFixture() }))

    expect(screen.getByTestId('runtime-lens')).toBeInTheDocument()
    expect(screen.getByText('keeper / agent turn')).toBeInTheDocument()
    expect(screen.getByText('7 / 3')).toBeInTheDocument()
    expect(screen.getByText('trace id')).toBeInTheDocument()
    expect(screen.getByText('trace-lens')).toBeInTheDocument()
    expect(screen.getByText('manifest rows')).toBeInTheDocument()
    expect(screen.getByText('6/6')).toBeInTheDocument()
    expect(screen.getByText('receipt rows')).toBeInTheDocument()
    expect(screen.getByText('manifest file')).toBeInTheDocument()
    expect(screen.getByText('manifest raw rows')).toBeInTheDocument()
    expect(screen.getByText('receipt raw rows')).toBeInTheDocument()
    expect(screen.getByText('receipt artifacts')).toBeInTheDocument()
    expect(screen.getByText('checkpoint artifacts')).toBeInTheDocument()
    expect(screen.getByText('tool log artifacts')).toBeInTheDocument()
    expect(screen.getAllByText('1/1').length).toBeGreaterThan(1)
    expect(screen.getByText('0/1')).toBeInTheDocument()
    expect(screen.getByText('working loops')).toBeInTheDocument()
    expect(screen.getAllByText('2').length).toBeGreaterThan(0)
    expect(screen.getByText('provider attempts')).toBeInTheDocument()
    expect(screen.getAllByText('1/1').length).toBeGreaterThan(0)
    expect(screen.getByText('provider terminal')).toBeInTheDocument()
    expect(screen.getByText('timeout / outer_oas_timeout')).toBeInTheDocument()
    expect(screen.getByText('clock edges')).toBeInTheDocument()
    expect(screen.getByText('clock groups')).toBeInTheDocument()
    expect(screen.getByTestId('runtime-lens-clock-groups')).toBeInTheDocument()
    expect(screen.getByText('event_bus_correlation')).toBeInTheDocument()
    expect(screen.getByText('tool_called · tool_completed')).toBeInTheDocument()
    expect(screen.getByTestId('runtime-lens-clock-edges')).toBeInTheDocument()
    expect(screen.getByText('provider_attempt_started')).toBeInTheDocument()
    expect(screen.getByText('edge-provider-start')).toBeInTheDocument()
    expect(screen.getByText('event ids')).toBeInTheDocument()
    expect(screen.getByText('corr corr-1 · run run-1')).toBeInTheDocument()
    expect(screen.getByText('memory evidence')).toBeInTheDocument()
    expect(screen.getByText('inj 1/1 · flush success 1 · error 0 · ep/proc ep 2 · proc 1')).toBeInTheDocument()
    expect(screen.getByText('Provider')).toBeInTheDocument()
    expect(screen.getByText('Tool Runtime')).toBeInTheDocument()
  })

  it('renders an empty state while runtime trace is unavailable', () => {
    render(h(RuntimeLensSection, { trace: null }))

    expect(screen.getByText('runtime_trace_unavailable')).toBeInTheDocument()
  })

  it('derives visible live-truth rows from composite and runtime trace evidence', () => {
    const summary = deriveKeeperLiveTruth({
      keeper: {
        name: 'sangsu',
        status: 'active',
        keepalive_running: true,
      },
      compositeSnapshot: compositeFixture(),
      runtimeTrace: runtimeTraceFixture(),
      runtimeResolution: null,
    })

    expect(summary.headline).toBe('조치 필요')
    expect(summary.rows.find(row => row.label === '동기화')?.detail).toContain('KSM running')
    expect(summary.rows.find(row => row.label === '런타임')?.value).toBe('fiber alive')
    expect(summary.rows.find(row => row.label === '현재 턴')?.value).toBe('no live turn')
    expect(summary.rows.find(row => row.label === '최신 증거')?.value).toBe('turn #7 finished')
    // RFC-0046 §4.3 partial closure: the FSM lane is now rendered exclusively
    // by FsmHub mode='detail' under this panel. Asserting the absence here
    // prevents regressing back to dual-rendering of KSM/KTC.
    expect(summary.rows.find(row => row.label === 'FSM')).toBeUndefined()
  })

  it('keeps previous receipt blockers out of the current live-turn summary', () => {
    const trace = runtimeTraceFixture()
    trace.runtime_lens.gaps = []
    const summary = deriveKeeperLiveTruth({
      keeper: {
        name: 'sangsu',
        status: 'active',
        keepalive_running: true,
        runtime_blocker_class: 'runtime_exhausted',
        runtime_blocker_summary: 'previous turn exhausted runtime',
      },
      compositeSnapshot: compositeFixture({
        is_live: true,
        turn_phase: 'executing',
        live_turn: {
          turn_id: 8,
          started_at: 1_778_688_690,
          last_progress_at: 1_778_688_699,
          last_progress_kind: 'provider_attempt_started',
        },
        runtime_attention: {
          state: 'ok',
          needs_attention: false,
          blocked: false,
          fiber_stop_requested: false,
          reason: null,
          raw_phase: 'running',
          is_live: true,
          source: 'live_turn',
          execution_current: false,
          stale_execution_receipt: true,
          live_turn_started_at: 1_778_688_690,
          live_turn_last_progress_at: 1_778_688_699,
        },
      }),
      runtimeTrace: trace,
      runtimeResolution: null,
    })

    expect(summary.headline).toBe('턴 진행 중')
    expect(summary.tone).toBe('ok')
    expect(summary.rows.find(row => row.label === '차단')?.value).toBe('none')
  })

  it('does not display omitted live-turn tool count as zero', () => {
    const summary = deriveKeeperLiveTruth({
      keeper: {
        name: 'sangsu',
        status: 'active',
        keepalive_running: true,
      },
      compositeSnapshot: compositeFixture({
        is_live: true,
        turn_phase: 'executing',
        live_turn: {
          turn_id: 8,
          started_at: 1_778_688_690,
          last_progress_at: 1_778_688_699,
          last_progress_kind: 'provider_attempt_started',
        },
        runtime_attention: {
          state: 'ok',
          needs_attention: false,
          blocked: false,
          fiber_stop_requested: false,
          reason: null,
          raw_phase: 'running',
          is_live: true,
          source: 'live_turn',
        },
      }),
      runtimeTrace: runtimeTraceFixture(),
      runtimeResolution: null,
    })

    const detail = summary.rows.find(row => row.label === '현재 턴')?.detail
    expect(detail).toContain('model — · tools —')
    expect(detail).not.toContain('tools 0')
  })

  it('surfaces runtime resolution warnings in the live-truth summary', () => {
    const summary = deriveKeeperLiveTruth({
      keeper: {
        name: 'sangsu',
        status: 'active',
        keepalive_running: true,
      },
      compositeSnapshot: compositeFixture({
        runtime_attention: {
          state: 'healthy',
          needs_attention: false,
          blocked: false,
          reason: null,
          raw_phase: 'running',
          is_live: false,
          source: 'execution_receipt',
        },
      }),
      runtimeTrace: runtimeTraceFixture(),
      runtimeResolution: {
        status: 'warn',
        warnings: ['Runtime build commit differs from server repo HEAD.'],
        source_mismatch: true,
        server_repo_git_commit: '386514c1f9',
        workspace_git_commit: 'd0add960d7',
        server_repo_path: { path: '/repo/.worktrees/stale-server' },
      },
    })

    expect(summary.tone).toBe('warn')
    expect(summary.runtimeWarnings).toEqual(['Runtime build commit differs from server repo HEAD.'])
    expect(summary.runtimeBuildLabel).toBe('386514c1f9 vs workspace d0add960d7')
    expect(summary.runtimeRepoLabel).toBe('.worktrees/stale-server')
  })

  it('renders secret projection status without secret values', () => {
    render(h(KeeperSecretProjectionPanel, {
      projection: {
        status: 'ready',
        configured: true,
        root: '/Users/dancer/me/.masc/secrets/sangsu',
        source: 'workspace_masc_secrets',
        effective_roots: [
          {
            root: '/Users/dancer/me/.masc/secrets/base',
            source: 'workspace_masc_secrets',
            status: 'ready',
            configured: true,
            env_count: 1,
            file_count: 0,
          },
          {
            root: '/Users/dancer/me/.masc/secrets/sangsu',
            source: 'workspace_masc_secrets',
            status: 'ready',
            configured: true,
            env_count: 1,
            file_count: 1,
          },
        ],
        env_count: 1,
        file_count: 1,
        env_names: ['GH_TOKEN'],
        file_mounts: [
          {
            host_path: '/Users/dancer/me/.masc/secrets/sangsu/files/home/keeper/.ssh/id_ed25519',
            container_path: '/home/keeper/.ssh/id_ed25519',
          },
        ],
        values_validated: true,
        error: null,
        next_action: 'none',
      },
    }))

    expect(screen.getByTestId('keeper-secret-projection')).toBeInTheDocument()
    expect(screen.getByText('ready')).toBeInTheDocument()
    expect(screen.getByText('1 env · 1 files')).toBeInTheDocument()
    expect(screen.getByText('shared -> keeper')).toBeInTheDocument()
    expect(screen.getAllByText('shared').length).toBeGreaterThan(0)
    expect(screen.getAllByText('keeper').length).toBeGreaterThan(0)
    expect(screen.getByText('/Users/dancer/me/.masc/secrets/base')).toBeInTheDocument()
    expect(screen.getByText('GH_TOKEN')).toBeInTheDocument()
    expect(screen.getByText('/home/keeper/.ssh/id_ed25519')).toBeInTheDocument()
    expect(screen.queryByText(/ghs_/)).toBeNull()
  })

  it('sets secret env values without rendering the submitted value', async () => {
    const nextProjection = {
      status: 'ready',
      configured: true,
      root: '/Users/dancer/me/.masc/secrets/sangsu',
      source: 'workspace_masc_secrets',
      effective_roots: [
        {
          root: '/Users/dancer/me/.masc/secrets/base',
          source: 'workspace_masc_secrets',
          status: 'absent',
          configured: false,
          env_count: 0,
          file_count: 0,
        },
        {
          root: '/Users/dancer/me/.masc/secrets/sangsu',
          source: 'workspace_masc_secrets',
          status: 'ready',
          configured: true,
          env_count: 1,
          file_count: 0,
        },
      ],
      env_count: 1,
      file_count: 0,
      env_names: ['ANTHROPIC_API_KEY'],
      file_mounts: [],
      values_validated: true,
      error: null,
      next_action: 'none',
    }
    const setSecretEnv = vi.fn().mockResolvedValue(nextProjection)

    render(h(KeeperSecretProjectionPanel, {
      keeperName: 'sangsu',
      projection: {
        ...nextProjection,
        status: 'empty',
        env_count: 0,
        env_names: [],
        next_action: 'add entries under env/ and/or files/',
      },
      setSecretEnv,
    }))

    fireEvent.input(screen.getByTestId('keeper-secret-env-name'), {
      target: { value: 'ANTHROPIC_API_KEY' },
    })
    fireEvent.input(screen.getByTestId('keeper-secret-value'), {
      target: { value: 'ghs_new_secret' },
    })
    fireEvent.submit(screen.getByTestId('keeper-secret-projection-form'))

    await waitFor(() => {
      expect(setSecretEnv).toHaveBeenCalledWith('sangsu', {
        scope: 'keeper',
        name: 'ANTHROPIC_API_KEY',
        value: 'ghs_new_secret',
      })
    })
    await waitFor(() => {
      expect(screen.queryByDisplayValue('ghs_new_secret')).toBeNull()
    })
    expect(screen.getByText('ANTHROPIC_API_KEY saved to keeper')).toBeInTheDocument()
    expect(screen.queryByText('ghs_new_secret')).toBeNull()
  })

  it('sets secret file values without rendering the submitted value', async () => {
    const nextProjection = {
      status: 'ready',
      configured: true,
      root: '/Users/dancer/me/.masc/secrets/sangsu',
      source: 'workspace_masc_secrets',
      effective_roots: [
        {
          root: '/Users/dancer/me/.masc/secrets/base',
          source: 'workspace_masc_secrets',
          status: 'absent',
          configured: false,
          env_count: 0,
          file_count: 0,
        },
        {
          root: '/Users/dancer/me/.masc/secrets/sangsu',
          source: 'workspace_masc_secrets',
          status: 'ready',
          configured: true,
          env_count: 0,
          file_count: 1,
        },
      ],
      env_count: 0,
      file_count: 1,
      env_names: [],
      file_mounts: [
        {
          host_path: '/Users/dancer/me/.masc/secrets/sangsu/files/home/keeper/.ssh/id_ed25519',
          container_path: '/home/keeper/.ssh/id_ed25519',
        },
      ],
      values_validated: true,
      error: null,
      next_action: 'none',
    }
    const setSecretFile = vi.fn().mockResolvedValue(nextProjection)

    render(h(KeeperSecretProjectionPanel, {
      keeperName: 'sangsu',
      projection: {
        ...nextProjection,
        status: 'empty',
        file_count: 0,
        file_mounts: [],
        next_action: 'add entries under env/ and/or files/',
      },
      setSecretFile,
    }))

    fireEvent.input(screen.getByTestId('keeper-secret-file-path'), {
      target: { value: '/home/keeper/.ssh/id_ed25519' },
    })
    fireEvent.input(screen.getByLabelText('Secret file value'), {
      target: { value: 'PRIVATE\nKEY\nCONTENT' },
    })
    fireEvent.submit(screen.getByTestId('keeper-secret-file-form'))

    await waitFor(() => {
      expect(setSecretFile).toHaveBeenCalledWith('sangsu', {
        scope: 'keeper',
        path: '/home/keeper/.ssh/id_ed25519',
        value: 'PRIVATE\nKEY\nCONTENT',
      })
    })
    await waitFor(() => {
      expect(screen.queryByDisplayValue('PRIVATE\nKEY\nCONTENT')).toBeNull()
    })
    expect(screen.getByText('/home/keeper/.ssh/id_ed25519 saved to keeper')).toBeInTheDocument()
    expect(screen.queryByText('PRIVATE\nKEY\nCONTENT')).toBeNull()
  })
})

describe('filterSignalGroups', () => {
  interface SampleGroup {
    title: string
    rows: Array<{ label: string; value: string | number }>
  }
  const sampleGroups: SampleGroup[] = [
    {
      title: '폴백',
      rows: [
        { label: '전체 폴백', value: '15.0%' },
        { label: '모델 폴백', value: '5.0%' },
      ],
    },
    {
      title: 'LLM 응답 정렬',
      rows: [
        { label: '목표 일치도', value: '0.820' },
        { label: '응답 일치도', value: '0.700' },
      ],
    },
    {
      title: '메모리 & 컴팩션',
      rows: [
        { label: '메모리 통과율', value: '88.0%' },
        { label: '컴팩션 절감', value: '42.0%' },
      ],
    },
  ]

  it('returns the input reference when the query is empty', () => {
    expect(filterSignalGroups(sampleGroups, '')).toBe(sampleGroups)
  })

  it('returns the input reference when the query is whitespace only', () => {
    expect(filterSignalGroups(sampleGroups, '   \t ')).toBe(sampleGroups)
  })

  it('matches case-insensitive substrings on row labels', () => {
    const result = filterSignalGroups(sampleGroups, '폴백')
    expect(result).toHaveLength(1)
    expect(result[0]?.title).toBe('폴백')
    expect(result[0]?.rows.map(r => r.label)).toEqual(['전체 폴백', '모델 폴백'])
  })

  it('preserves only the matching rows within a group', () => {
    const result = filterSignalGroups(sampleGroups, '컴팩션')
    expect(result).toHaveLength(1)
    expect(result[0]?.title).toBe('메모리 & 컴팩션')
    expect(result[0]?.rows).toHaveLength(1)
    expect(result[0]?.rows[0]?.label).toBe('컴팩션 절감')
  })

  it('drops groups that have zero matching rows', () => {
    const result = filterSignalGroups(sampleGroups, '일치도')
    expect(result.map(g => g.title)).toEqual(['LLM 응답 정렬'])
  })

  it('trims the query before matching', () => {
    const result = filterSignalGroups(sampleGroups, '  메모리  ')
    expect(result).toHaveLength(1)
    expect(result[0]?.rows.map(r => r.label)).toEqual(['메모리 통과율'])
  })

  it('returns an empty array when nothing matches', () => {
    const result = filterSignalGroups(sampleGroups, 'zzz-no-match')
    expect(result).toEqual([])
  })

  it('does not mutate the input groups or their row arrays', () => {
    const snapshot = JSON.parse(JSON.stringify(sampleGroups))
    filterSignalGroups(sampleGroups, '폴백')
    expect(sampleGroups).toEqual(snapshot)
  })

  it('matches Latin characters case-insensitively', () => {
    const groups = [
      {
        title: 'Mixed',
        rows: [
          { label: 'CPU Saturation', value: 0.4 },
          { label: 'Disk IO', value: 0.9 },
        ],
      },
    ]
    const result = filterSignalGroups(groups, 'cpu')
    expect(result).toHaveLength(1)
    expect(result[0]?.rows.map(r => r.label)).toEqual(['CPU Saturation'])
  })
})
