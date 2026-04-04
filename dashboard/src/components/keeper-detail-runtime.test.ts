import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import '@testing-library/jest-dom'

import type { DashboardMissionKeeperBrief, Keeper, KeeperConfig } from '../types'
import {
  AllowlistPreview,
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
      allowed_tool_names: ['compat_only_allowlist'],
    } as DashboardMissionKeeperBrief & { allowed_tool_names: string[] }

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
})

describe('AllowlistPreview', () => {
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
    expect(screen.getByText('나머지 3개 보기')).toBeInTheDocument()

    fireEvent.click(screen.getByText('나머지 3개 보기'))

    expect(screen.getByText('tool-13')).toBeInTheDocument()
    expect(screen.getByText('tool-15')).toBeInTheDocument()
    expect(screen.getByText('접기')).toBeInTheDocument()
  })
})
