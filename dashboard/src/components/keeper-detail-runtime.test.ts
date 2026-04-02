import { describe, expect, it } from 'vitest'

import type { DashboardMissionKeeperBrief, Keeper, KeeperConfig } from '../types'
import {
  resolveKeeperObservedToolAudit,
  resolveKeeperToolPolicy,
} from './keeper-detail-runtime'

describe('resolveKeeperToolPolicy', () => {
  it('uses keeper config as the authoritative policy source', () => {
    const keeperConfig = {
      tools: {
        tool_access: {},
        tool_policy_mode: 'custom',
        tool_preset: null,
        tool_also_allow: ['mcp__masc__masc_join'],
        tool_custom_allowlist: ['mcp__masc__masc_board_post'],
        resolved_allowlist: ['mcp__masc__masc_board_post'],
        tool_denylist: ['mcp__masc__masc_board_delete'],
        active_masc_tool_count: 1,
        active_keeper_tool_count: 0,
        total_active: 1,
      },
    } satisfies Pick<KeeperConfig, 'tools'>

    expect(resolveKeeperToolPolicy(keeperConfig, 'loaded')).toEqual({
      source: 'keeper_config',
      mode: 'custom',
      preset: null,
      alsoAllow: ['mcp__masc__masc_join'],
      customAllowlist: ['mcp__masc__masc_board_post'],
      denylist: ['mcp__masc__masc_board_delete'],
      resolvedAllowlist: ['mcp__masc__masc_board_post'],
    })
  })

  it('reports loading instead of inventing defaults before config arrives', () => {
    expect(resolveKeeperToolPolicy(null, 'loading')).toEqual({
      source: 'loading',
      mode: 'preset',
      preset: null,
      alsoAllow: [],
      customAllowlist: [],
      denylist: [],
      resolvedAllowlist: [],
    })
  })

  it('reports none after config load when no policy payload is available', () => {
    expect(resolveKeeperToolPolicy(null, 'loaded')).toEqual({
      source: 'none',
      mode: 'preset',
      preset: null,
      alsoAllow: [],
      customAllowlist: [],
      denylist: [],
      resolvedAllowlist: [],
    })
  })

  it('preserves an explicit config error state', () => {
    expect(resolveKeeperToolPolicy(null, 'error')).toEqual({
      source: 'error',
      mode: 'preset',
      preset: null,
      alsoAllow: [],
      customAllowlist: [],
      denylist: [],
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
