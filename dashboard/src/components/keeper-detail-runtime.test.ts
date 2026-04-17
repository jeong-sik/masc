import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import '@testing-library/jest-dom'

import type { DashboardMissionKeeperBrief, Keeper, KeeperConfig } from '../types'
import {
  AllowlistPreview,
  RuntimeSignals,
  filterSignalGroups,
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
    expect(screen.getByText('주요 모델')).toBeInTheDocument()
    expect(screen.getByText('주요 작업 종류')).toBeInTheDocument()
    expect(screen.getByText('masc_board_post')).toBeInTheDocument()
    expect(screen.getByText('gpt-5')).toBeInTheDocument()
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
