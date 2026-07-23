import { describe, it, expect } from 'vitest'
import { normalizeNamespaceTruth } from './namespace-truth-normalizers'

// ================================================================
// normalizeNamespaceTruth
// ================================================================

describe('normalizeNamespaceTruth', () => {
  it('returns safe defaults for null input', () => {
    const result = normalizeNamespaceTruth(null)
    expect(result.generated_at).toBeUndefined()
    expect(result.dashboard_surface).toBeUndefined()
    expect(result.dashboard_aliases).toEqual([])
    expect(result.retention).toBeUndefined()
    expect(result.root.status).toBeNull()
    expect(result.root.configured_keepers).toBeUndefined()
    expect(result.execution?.summary).toBeNull()
    expect(result.command?.active_operations).toBeUndefined()
    expect(result.operator?.pending_confirm_summary).toBeNull()
    expect(result.focus).toBeNull()
  })

  it('returns safe defaults for undefined input', () => {
    const result = normalizeNamespaceTruth(undefined)
    expect(result.root.status).toBeNull()
  })

  it('returns safe defaults for string input', () => {
    const result = normalizeNamespaceTruth('not an object')
    expect(result.root.status).toBeNull()
  })

  it('returns safe defaults for array input', () => {
    const result = normalizeNamespaceTruth([1, 2, 3])
    expect(result.root.status).toBeNull()
  })

  it('extracts generated_at from root level', () => {
    const result = normalizeNamespaceTruth({ generated_at: '2026-04-17T10:00:00Z' })
    expect(result.generated_at).toBe('2026-04-17T10:00:00Z')
  })

  it('preserves top-level provenance for canonical and alias routes', () => {
    const result = normalizeNamespaceTruth({
      generated_at_iso: '2026-04-17T10:00:00Z',
      dashboard_surface: '/api/v1/dashboard/namespace-truth',
      dashboard_aliases: [
        '/api/v1/dashboard/project-snapshot',
        '/api/v1/dashboard/workspace-truth',
      ],
      source: 'namespace_truth_read_model',
      retention: {
        scope: 'dashboard_namespace_truth',
        workspace_root: '/Users/dancer/me',
        workspace_path: '/Users/dancer/me',
        shell_input: '/api/v1/dashboard/shell',
        execution_input: '/api/v1/dashboard/execution',
        command_input: 'command_summary_json',
        cache_policy: 'proactive_execution_cache_last_good_shell_fallback',
      },
    })

    expect(result.generated_at_iso).toBe('2026-04-17T10:00:00Z')
    expect(result.dashboard_surface).toBe('/api/v1/dashboard/namespace-truth')
    expect(result.dashboard_aliases).toContain('/api/v1/dashboard/workspace-truth')
    expect(result.source).toBe('namespace_truth_read_model')
    expect(result.retention?.scope).toBe('dashboard_namespace_truth')
    expect(result.retention?.execution_input).toBe('/api/v1/dashboard/execution')
  })

  // ── root block ──

  it('extracts root.status with all fields', () => {
    const result = normalizeNamespaceTruth({
      root: {
        status: {
          workspace_root: '/path/to/root',
          workspace_path: '/path/to/ws',
          workspace_differs: true,
          cluster: 'local',
          project: 'masc',
          paused: false,
          version: '1.0.0',
          generated_at: '2026-04-17T10:00:00Z',
          build: { commit: 'abc123', dirty: false, timestamp: '2026-04-17' },
        },
      },
    })
    const status = result.root.status
    expect(status).not.toBeNull()
    expect(status!.workspace_root).toBe('/path/to/root')
    expect(status!.workspace_differs).toBe(true)
    expect(status!.paused).toBe(false)
    expect(status!.version).toBe('1.0.0')
  })

  it('reuses the shared server-status normalizer for shell-derived truth fields', () => {
    const result = normalizeNamespaceTruth({
      root: {
        status: {
          workspace_root: '/path/to/root',
          workspace_path: '/path/to/ws',
          version: '1.0.0',
          generated_at: '2026-04-17T10:00:00Z',
          build: {
            release_version: '1.0.0',
            commit: '2897da06',
            started_at: '2026-04-17T09:50:00Z',
            uptime_seconds: 600,
          },
          tempo: 'steady',
          tool_call_health: {
            window_hours: 6,
            tool_calls: 42,
            failures: 3,
            failure_rate: 0.071,
            since_epoch: 1775000000,
            distinct_tools: 8,
          },
          alert_thresholds: {
            proactive_fallback_warn: 0.15,
            proactive_fallback_bad: 0.3,
            proactive_similarity_warn: 0.25,
            proactive_similarity_bad: 0.5,
            toast_cooldown_sec: 120,
          },
          monitoring: {
            board: {
              stale_posts: 2,
            },
          },
          data_quality: {
            board_contract_ok: true,
            gate_feed_ok: false,
            last_sync_at: '2026-04-17T09:55:00Z',
          },
        },
      },
    })

    expect(result.root.status).toMatchObject({
      tempo: 'steady',
      tool_call_health: {
        tool_calls: 42,
        distinct_tools: 8,
      },
      alert_thresholds: {
        toast_cooldown_sec: 120,
      },
      monitoring: {
        board: {
          stale_posts: 2,
        },
      },
      data_quality: {
        board_contract_ok: true,
        gate_feed_ok: false,
        last_sync_at: '2026-04-17T09:55:00Z',
      },
    })
  })

  it('extracts root.counts', () => {
    const result = normalizeNamespaceTruth({
      root: {
        counts: { agents: 5, tasks: 12, keepers: 3, total_runtimes: 8 },
      },
    })
    expect(result.root.counts).toEqual({
      agents: 5,
      tasks: 12,
      keepers: 3,
      total_runtimes: 8,
    })
  })

  it('sets root.counts to undefined when not a record', () => {
    const result = normalizeNamespaceTruth({
      root: { counts: 'invalid' },
    })
    expect(result.root.counts).toBeUndefined()
  })

  it('extracts configured_keepers and provenance', () => {
    const result = normalizeNamespaceTruth({
      root: {
        configured_keepers: 7,
        provenance: 'filesystem',
      },
    })
    expect(result.root.configured_keepers).toBe(7)
    expect(result.root.provenance).toBe('filesystem')
  })

  it('preserves runtime count authority metadata', () => {
    const result = normalizeNamespaceTruth({
      root: {
        runtime_count_authority: {
          source: 'namespace_truth_read_model',
          authority: 'root.counts',
          configured_authority: 'root.configured_keepers',
          fallback_policy: 'shell_last_good_only_when_namespace_unavailable',
          shell_arbitration_allowed: false,
          live_total_runtimes: 3,
          live_keepers: 2,
          configured_keepers: 4,
          configured_minus_live_keepers: 2,
          count_roles: {
            'root.counts': 'authoritative_live_snapshot',
            'root.configured_keepers': 'authoritative_inventory',
            shell: 'read_model_input',
            execution: 'diagnostic_summary_only',
          },
        },
      },
    })

    expect(result.root.runtime_count_authority).toEqual({
      source: 'namespace_truth_read_model',
      authority: 'root.counts',
      configured_authority: 'root.configured_keepers',
      fallback_policy: 'shell_last_good_only_when_namespace_unavailable',
      shell_arbitration_allowed: false,
      live_total_runtimes: 3,
      live_keepers: 2,
      configured_keepers: 4,
      configured_minus_live_keepers: 2,
      count_roles: {
        'root.counts': 'authoritative_live_snapshot',
        'root.configured_keepers': 'authoritative_inventory',
        shell: 'read_model_input',
        execution: 'diagnostic_summary_only',
      },
    })
  })

  it('defaults root.provenance to null', () => {
    const result = normalizeNamespaceTruth({ root: {} })
    expect(result.root.provenance).toBeNull()
  })

  // ── execution block ──

  it('extracts execution block with provenance', () => {
    const result = normalizeNamespaceTruth({
      execution: { provenance: 'runtime' },
    })
    expect(result.execution?.provenance).toBe('runtime')
    expect(result.execution?.summary).toBeNull()
    expect(result.execution?.top_queue).toBeNull()
  })

  // ── command block ──

  it('extracts command block numeric fields', () => {
    const result = normalizeNamespaceTruth({
      command: {
        active_operations: 3,
        active_detachments: 1,
        pending_approvals: 5,
        bad_alerts: 2,
        warn_alerts: 7,
        provenance: 'alert-system',
      },
    })
    expect(result.command?.active_operations).toBe(3)
    expect(result.command?.active_detachments).toBe(1)
    expect(result.command?.pending_approvals).toBe(5)
    expect(result.command?.bad_alerts).toBe(2)
    expect(result.command?.warn_alerts).toBe(7)
    expect(result.command?.provenance).toBe('alert-system')
  })

  it('defaults command fields to undefined', () => {
    const result = normalizeNamespaceTruth({})
    expect(result.command?.active_operations).toBeUndefined()
    expect(result.command?.provenance).toBeNull()
  })

  // ── operator block ──

  it('extracts operator provenance', () => {
    const result = normalizeNamespaceTruth({
      operator: {
        provenance: 'operator-daemon',
      },
    })
    expect(result.operator?.provenance).toBe('operator-daemon')
  })

  // ── pending_confirm_summary ──

  it('extracts pending_confirm_summary with confirm_required_actions', () => {
    const result = normalizeNamespaceTruth({
      operator: {
        pending_confirm_summary: {
          actor_filter: 'agent-1',
          filter_active: true,
          visible_count: 3,
          total_count: 10,
          hidden_count: 7,
          hidden_actors: ['agent-2', 'agent-3'],
          confirm_required_actions: [
            { action_type: 'shutdown', target_type: 'keeper', description: 'Shutdown keeper', confirm_required: true },
          ],
        },
      },
    })
    const pcs = result.operator?.pending_confirm_summary
    expect(pcs).not.toBeNull()
    expect(pcs!.actor_filter).toBe('agent-1')
    expect(pcs!.filter_active).toBe(true)
    expect(pcs!.visible_count).toBe(3)
    expect(pcs!.hidden_actors).toEqual(['agent-2', 'agent-3'])
    expect(pcs!.confirm_required_actions).toHaveLength(1)
    expect(pcs!.confirm_required_actions[0]!.action_type).toBe('shutdown')
  })

  it('filters out confirm_required_actions with missing required fields', () => {
    const result = normalizeNamespaceTruth({
      operator: {
        pending_confirm_summary: {
          confirm_required_actions: [
            { action_type: 'shutdown' }, // missing target_type
            { target_type: 'keeper' }, // missing action_type
            { action_type: 'restart', target_type: 'agent' }, // valid
          ],
        },
      },
    })
    const pcs = result.operator?.pending_confirm_summary
    expect(pcs!.confirm_required_actions).toHaveLength(1)
    expect(pcs!.confirm_required_actions[0]!.action_type).toBe('restart')
  })

  it('defaults pending_confirm_summary numeric fields', () => {
    const result = normalizeNamespaceTruth({
      operator: {
        pending_confirm_summary: {},
      },
    })
    const pcs = result.operator?.pending_confirm_summary
    expect(pcs!.visible_count).toBe(0)
    expect(pcs!.total_count).toBe(0)
    expect(pcs!.hidden_count).toBe(0)
    expect(pcs!.filter_active).toBe(false)
    expect(pcs!.actor_filter).toBeNull()
    expect(pcs!.hidden_actors).toEqual([])
  })

  it('extracts readiness summary and attention events', () => {
    const result = normalizeNamespaceTruth({
      readiness: {
        status: 'warn',
        score: 0.61,
        decision_required_count: 2,
        blocking_count: 3,
        pillars: [
          {
            key: 'execution_safety',
            label: 'Execution Safety',
            status: 'ok',
            score: 1,
            summary: 'Sandbox posture is visible.',
            blocking_reasons: [],
            metrics: { keeper_count: 4 },
          },
          {
            key: 'goal_coherence',
            label: 'Goal Coherence',
            status: 'warn',
            score: 0.25,
            summary: 'One keeper is unscoped.',
            blocking_reasons: ['1 keeper has no active goal link.'],
            metrics: { unscoped_keepers: 1 },
          },
        ],
      },
      attention_events: [
        {
          severity: 'warn',
          kind: 'hitl_pending',
          summary: 'keeper-alpha needs a decision.',
          requires_decision: true,
          keeper_name: 'keeper-alpha',
          recommended_action: 'Review the pending Gate request.',
          provenance: 'runtime',
        },
      ],
    })

    expect(result.readiness).not.toBeNull()
    expect(result.readiness!.status).toBe('warn')
    expect(result.readiness!.score).toBe(0.61)
    expect(result.readiness!.decision_required_count).toBe(2)
    expect(result.readiness!.pillars).toHaveLength(2)
    expect(result.readiness!.pillars[1]!.blocking_reasons).toEqual(['1 keeper has no active goal link.'])
    expect(result.attention_events).toHaveLength(1)
    expect(result.attention_events![0]!.kind).toBe('hitl_pending')
    expect(result.attention_events![0]!.requires_decision).toBe(true)
  })

  // ── focus ──

  it('returns null focus when required fields missing', () => {
    const result = normalizeNamespaceTruth({
      focus: { label: 'test' }, // missing reason, source, provenance
    })
    expect(result.focus).toBeNull()
  })

  it('extracts focus with all required fields', () => {
    const result = normalizeNamespaceTruth({
      focus: {
        label: 'High CPU',
        reason: 'Keeper using 90% CPU',
        source: 'monitor',
        provenance: 'alert-system',
        target_kind: 'keeper',
        target_id: 'janitor',
        suggested_tab: 'keepers',
        suggested_surface: 'detail',
      },
    })
    expect(result.focus).not.toBeNull()
    expect(result.focus!.label).toBe('High CPU')
    expect(result.focus!.reason).toBe('Keeper using 90% CPU')
    expect(result.focus!.source).toBe('monitor')
    expect(result.focus!.provenance).toBe('alert-system')
    expect(result.focus!.target_kind).toBe('keeper')
    expect(result.focus!.target_id).toBe('janitor')
  })

  it('defaults optional focus fields to null', () => {
    const result = normalizeNamespaceTruth({
      focus: {
        label: 'Alert',
        reason: 'Something wrong',
        source: 'monitor',
        provenance: 'system',
      },
    })
    expect(result.focus!.target_kind).toBeNull()
    expect(result.focus!.target_id).toBeNull()
    expect(result.focus!.suggested_tab).toBeNull()
  })

  it('extracts focus suggested_params as string map', () => {
    const result = normalizeNamespaceTruth({
      focus: {
        label: 'Alert',
        reason: 'reason',
        source: 'monitor',
        provenance: 'system',
        suggested_params: { keeper: 'janitor', tab: 'detail', empty: '' },
      },
    })
    // empty string is filtered out by asString (returns undefined for empty)
    expect(result.focus!.suggested_params).toEqual({ keeper: 'janitor', tab: 'detail' })
  })

  it('defaults suggested_params to empty object when not a record', () => {
    const result = normalizeNamespaceTruth({
      focus: {
        label: 'Alert',
        reason: 'reason',
        source: 'monitor',
        provenance: 'system',
        suggested_params: 'not-a-record',
      },
    })
    expect(result.focus!.suggested_params).toEqual({})
  })

  // ── full integration ──

  it('parses a full project snapshot response', () => {
    const result = normalizeNamespaceTruth({
      generated_at: '2026-04-17T12:00:00Z',
      root: {
        status: { workspace_root: '/root', workspace_path: '/ws' },
        counts: { agents: 3, tasks: 5, keepers: 2, total_runtimes: 3 },
        configured_keepers: 4,
        provenance: 'fs',
      },
      execution: {
        provenance: 'runtime',
      },
      command: {
        active_operations: 1,
        bad_alerts: 0,
      },
      operator: {
        provenance: 'operator',
      },
      focus: null,
    })
    expect(result.generated_at).toBe('2026-04-17T12:00:00Z')
    expect(result.root.counts?.agents).toBe(3)
    expect(result.root.configured_keepers).toBe(4)
    expect(result.execution?.provenance).toBe('runtime')
    expect(result.command?.active_operations).toBe(1)
    expect(result.operator?.provenance).toBe('operator')
    expect(result.focus).toBeNull()
  })
})
