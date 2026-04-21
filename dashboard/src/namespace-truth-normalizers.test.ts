import { describe, it, expect } from 'vitest'
import { normalizeNamespaceTruth } from './namespace-truth-normalizers'

// ================================================================
// normalizeNamespaceTruth
// ================================================================

describe('normalizeNamespaceTruth', () => {
  it('returns safe defaults for null input', () => {
    const result = normalizeNamespaceTruth(null)
    expect(result.generated_at).toBeUndefined()
    expect(result.root.status).toBeNull()
    expect(result.root.configured_keepers).toBeUndefined()
    expect(result.execution?.summary).toBeNull()
    expect(result.command?.active_operations).toBeUndefined()
    expect(result.meta_cognition?.summary).toBeNull()
    expect(result.operator?.health).toBeNull()
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

  // ── root block ──

  it('extracts root.status with all fields', () => {
    const result = normalizeNamespaceTruth({
      root: {
        status: {
          coordination_root: '/path/to/root',
          workspace_path: '/path/to/ws',
          workspace_differs: true,
          cluster: 'local',
          project: 'masc-mcp',
          paused: false,
          version: '1.0.0',
          generated_at: '2026-04-17T10:00:00Z',
          build: { commit: 'abc123', dirty: false, timestamp: '2026-04-17' },
        },
      },
    })
    const status = result.root.status
    expect(status).not.toBeNull()
    expect(status!.coordination_root).toBe('/path/to/root')
    expect(status!.workspace_differs).toBe(true)
    expect(status!.paused).toBe(false)
    expect(status!.version).toBe('1.0.0')
  })

  it('reuses the shared server-status normalizer for shell-derived truth fields', () => {
    const result = normalizeNamespaceTruth({
      root: {
        status: {
          coordination_root: '/path/to/root',
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
            governance_feed_ok: false,
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
        governance_feed_ok: false,
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

  // ── meta_cognition block ──

  it('extracts meta_cognition block', () => {
    const result = normalizeNamespaceTruth({
      meta_cognition: {
        provenance: 'reflection',
        latest_digest: {
          post_id: 'p1',
          title: 'Daily Digest',
          created_at: '2026-04-17',
        },
      },
    })
    expect(result.meta_cognition?.provenance).toBe('reflection')
    const digest = result.meta_cognition?.latest_digest
    expect(digest).not.toBeNull()
    expect(digest!.post_id).toBe('p1')
    expect(digest!.title).toBe('Daily Digest')
  })

  it('returns null digest when required fields missing', () => {
    const result = normalizeNamespaceTruth({
      meta_cognition: {
        latest_digest: { post_id: 'p1' }, // missing title, created_at
      },
    })
    expect(result.meta_cognition?.latest_digest).toBeNull()
  })

  it('extracts digest with optional fields', () => {
    const result = normalizeNamespaceTruth({
      meta_cognition: {
        latest_digest: {
          post_id: 'p1',
          title: 'Digest',
          created_at: '2026-04-17',
          updated_at: '2026-04-17T12:00:00Z',
          hearth: 'active',
          digest_key: 'dk-1',
          matches_summary: true,
          provenance: 'self',
        },
      },
    })
    const digest = result.meta_cognition?.latest_digest
    expect(digest!.updated_at).toBe('2026-04-17T12:00:00Z')
    expect(digest!.hearth).toBe('active')
    expect(digest!.matches_summary).toBe(true)
  })

  // ── operator block ──

  it('extracts operator block', () => {
    const result = normalizeNamespaceTruth({
      operator: {
        health: 'ok',
        provenance: 'operator-daemon',
        attention_summary: {
          count: 10,
          bad_count: 2,
          warn_count: 3,
          provenance: 'monitor',
        },
        recommendation_summary: {
          count: 5,
          provenance: 'advisor',
        },
      },
    })
    expect(result.operator?.health).toBe('ok')
    expect(result.operator?.provenance).toBe('operator-daemon')
    expect(result.operator?.attention_summary?.count).toBe(10)
    expect(result.operator?.attention_summary?.bad_count).toBe(2)
    expect(result.operator?.recommendation_summary?.count).toBe(5)
  })

  it('defaults operator.health to null', () => {
    const result = normalizeNamespaceTruth({})
    expect(result.operator?.health).toBeNull()
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
        status: { coordination_root: '/root', workspace_path: '/ws' },
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
      meta_cognition: {
        provenance: 'reflection',
      },
      operator: {
        health: 'healthy',
        provenance: 'operator',
      },
      focus: null,
    })
    expect(result.generated_at).toBe('2026-04-17T12:00:00Z')
    expect(result.root.counts?.agents).toBe(3)
    expect(result.root.configured_keepers).toBe(4)
    expect(result.execution?.provenance).toBe('runtime')
    expect(result.command?.active_operations).toBe(1)
    expect(result.operator?.health).toBe('healthy')
    expect(result.focus).toBeNull()
  })
})
