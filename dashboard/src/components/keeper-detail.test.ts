import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'

import type { Keeper } from '../types'
import type { RouteState } from '../types'
import { keepers } from '../store'

const mocks = vi.hoisted(() => ({
  fetchKeeperTransitions: vi.fn(async () => ({ transitions: [] })),
  loadKeeperConfig: vi.fn(async () => {}),
  resetKeeperConfig: vi.fn(),
  selectKeeper: vi.fn(),
  navigate: vi.fn(),
  replaceRoute: vi.fn(),
  route: {
    value: {
      tab: 'monitoring',
      params: { section: 'agents', view: 'keepers' },
      postId: null,
    } as RouteState,
  },
}))

vi.mock('../api/keeper', async () => {
  const actual = await vi.importActual<typeof import('../api/keeper')>('../api/keeper')
  return {
    ...actual,
    bootKeeper: vi.fn(async () => ({ ok: true })),
    clearKeeper: vi.fn(async () => ({ ok: true })),
    fetchKeeperTransitions: mocks.fetchKeeperTransitions,
    pauseKeeper: vi.fn(async () => ({ ok: true })),
    resumeKeeper: vi.fn(async () => ({ ok: true })),
    shutdownKeeper: vi.fn(async () => ({ ok: true })),
    wakeKeeper: vi.fn(async () => ({ ok: true })),
  }
})

vi.mock('./keeper-config-state', async () => {
  const actual = await vi.importActual<typeof import('./keeper-config-state')>('./keeper-config-state')
  return {
    ...actual,
    loadKeeperConfig: mocks.loadKeeperConfig,
    resetKeeperConfig: mocks.resetKeeperConfig,
  }
})

vi.mock('./keeper-config-panel', async () => {
  const actual = await vi.importActual<typeof import('./keeper-config-panel')>('./keeper-config-panel')
  return {
    ...actual,
    // The real panel now owns the .kcf-overlay modal shell (backdrop +
    // close), so the page-level open/close flow asserts against the panel's
    // own overlay/close testids rather than a host wrapper. The stub mirrors
    // that contract: it renders the overlay container, the panel marker, and a
    // close affordance wired to onClose.
    KeeperConfigPanel: ({ keeperName, onClose }: { keeperName: string; onClose?: () => void }) =>
      html`<div data-testid="kw-config-overlay">
        <div data-testid="keeper-config-panel" data-keeper=${keeperName}>Config ${keeperName}</div>
        <button type="button" data-testid="kw-config-close" onClick=${onClose}>닫기</button>
      </div>`,
    loadKeeperConfig: mocks.loadKeeperConfig,
    resetKeeperConfig: mocks.resetKeeperConfig,
  }
})

vi.mock('./keeper-detail-charts', () => ({
  ContextChart: () => null,
  MetricsCharts: () => null,
  TokenTrendChart: () => null,
}))

vi.mock('./keeper-detail-ctx-composition', () => ({
  CtxCompositionPanel: () => null,
}))

vi.mock('./keeper-detail-debug', () => ({
  RawDataDebug: () => null,
}))

vi.mock('./keeper-detail-kpi', () => ({
  KpiGrid: () => null,
}))

vi.mock('./keeper-detail-lists', () => ({
  EquipmentList: () => null,
  RelationshipList: () => null,
  TraitsList: () => null,
}))

vi.mock('./keeper-detail-telemetry', () => ({
  InferenceTelemetryPanel: () => null,
  PromptTelemetryPanel: () => null,
}))

vi.mock('./keeper-detail-history', async () => {
  const actual = await vi.importActual<typeof import('./keeper-detail-history')>('./keeper-detail-history')
  return {
    ...actual,
    GenerationLineagePanel: () => null,
    KeeperCheckpointPanel: () => null,
  }
})

vi.mock('./keeper-state-diagram', () => ({
  KeeperStateDiagramPanel: () => null,
}))

vi.mock('./keeper-memory-tier-panel', () => ({
  KeeperMemoryTierPanel: () => null,
}))

vi.mock('./keeper-tool-telemetry', () => ({
  KeeperToolTelemetry: () => null,
}))

vi.mock('./keeper-tool-call-inspector', () => ({
  KeeperToolCallInspector: () => null,
}))

vi.mock('./keeper-supervisor-diagnostics', () => ({
  SupervisorDiagnosticsPanel: () => null,
}))

vi.mock('./keeper-eval-quality', () => ({
  KeeperEvalQualityPanel: () => null,
}))

vi.mock('./session-trace/session-trace-view', () => ({
  SessionTraceView: () => null,
}))

vi.mock('./agent-detail-journal', () => ({
  AgentJournalStream: () => null,
}))

vi.mock('./keeper-shared', () => ({
  KeeperConversationPanel: ({ keeperName }: { keeperName: string }) => `direct chat ${keeperName}`,
  KeeperDiagnosticSummary: () => null,
  KeeperRuntimeActions: () => null,
}))

vi.mock('../keeper-actions', async () => {
  const actual = await vi.importActual<typeof import('../keeper-actions')>('../keeper-actions')
  return {
    ...actual,
    selectKeeper: mocks.selectKeeper,
  }
})

vi.mock('../router', () => ({
  navigate: mocks.navigate,
  replaceRoute: mocks.replaceRoute,
  route: mocks.route,
}))

import { KeeperDetailPage } from './keeper-detail-page'
import { activeKeeperDetailSection } from './keeper-detail-shell'
import {
  clearKeeperDetailSelection,
  closeKeeperDetail,
  filterCheckpointHistory,
  keeperMobilePane,
  lineageTransitionLabel,
  lineageVerdictMeta,
  openKeeperDetail,
  selectedKeeper,
} from './keeper-detail'
import type { KeeperCheckpointSummary } from '../api/keeper'

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe('openKeeperDetail', () => {
  beforeEach(() => {
    selectedKeeper.value = null
    keepers.value = []
    mocks.fetchKeeperTransitions.mockClear()
    mocks.loadKeeperConfig.mockClear()
    mocks.resetKeeperConfig.mockClear()
    mocks.selectKeeper.mockClear()
    mocks.navigate.mockClear()
    mocks.replaceRoute.mockClear()
    mocks.route.value = {
      tab: 'monitoring',
      params: { section: 'agents', view: 'keepers' },
      postId: null,
    }
  })

  it('selects the keeper, preloads config, and routes into keeper detail', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
    }

    openKeeperDetail(keeper)

    expect(selectedKeeper.value).toEqual(keeper)
    expect(mocks.selectKeeper).toHaveBeenCalledWith('sangsu')
    expect(mocks.loadKeeperConfig).toHaveBeenCalledWith('sangsu')
    expect(mocks.navigate).toHaveBeenCalledWith('monitoring', {
      section: 'agents',
      view: 'keepers',
      keeper: 'sangsu',
    })
  })

  it('routes to monitoring agents when opened outside the agents directory', () => {
    mocks.route.value = {
      tab: 'workspace',
      params: { section: 'board' },
      postId: null,
    }
    const keeper: Keeper = {
      name: 'cheolsu',
      status: 'active',
    }

    openKeeperDetail(keeper)

    expect(mocks.navigate).toHaveBeenCalledWith('monitoring', {
      section: 'agents',
      keeper: 'cheolsu',
    })
  })

  it('resets detail-local state on close and returns to the agent directory view', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
    }

    openKeeperDetail(keeper)
    closeKeeperDetail()

    expect(selectedKeeper.value).toBeNull()
    expect(mocks.resetKeeperConfig).toHaveBeenCalledTimes(1)
    expect(mocks.selectKeeper).toHaveBeenLastCalledWith('')
    expect(mocks.navigate).toHaveBeenLastCalledWith('monitoring', {
      section: 'agents',
      view: 'keepers',
    })
  })

  it('only clears detail state for the matching keeper when cleanup is scoped', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      agent_name: 'sangsu-agent',
      status: 'active',
    }

    openKeeperDetail(keeper)
    mocks.resetKeeperConfig.mockClear()
    mocks.selectKeeper.mockClear()

    clearKeeperDetailSelection('other-keeper')

    expect(selectedKeeper.value).toEqual(keeper)
    expect(mocks.resetKeeperConfig).not.toHaveBeenCalled()
    expect(mocks.selectKeeper).not.toHaveBeenCalled()

    clearKeeperDetailSelection('sangsu-agent')

    expect(selectedKeeper.value).toBeNull()
    expect(mocks.resetKeeperConfig).toHaveBeenCalledTimes(1)
    expect(mocks.selectKeeper).toHaveBeenCalledWith('')
  })
})

describe('KeeperDetailPage', () => {
  beforeEach(() => {
    selectedKeeper.value = null
    keepers.value = []
    mocks.fetchKeeperTransitions.mockClear()
    mocks.loadKeeperConfig.mockClear()
    mocks.selectKeeper.mockClear()
    mocks.route.value = {
      tab: 'monitoring',
      params: { section: 'agents', view: 'keepers', keeper: 'analyst' },
      postId: null,
    }
    activeKeeperDetailSection.value = 'keeper-comms'
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({}), {
      headers: { 'content-type': 'application/json' },
      status: 200,
    })))
  })

  it('renders a live keeper detail route without tripping the monitoring error boundary', async () => {
    const analyst = {
      name: 'analyst',
      status: 'active',
      phase: 'Running',
      pipeline_stage: 'idle',
      agent_name: 'keeper-analyst-agent',
      runtime_class: 'keeper',
      keepalive_running: true,
      goal: '현재 대화의 근거와 핵심 수치를 먼저 정리한다.',
      generation: 0,
      turn_count: 97,
      last_turn_ago_s: 1108,
      primary_model: 'codex-cli:gpt-spark',
      active_model: 'claude-code:auto',
      active_model_label: 'claude-code:auto',
      context_ratio: 0.000008,
      context_tokens: 8,
      context_max: 1000000,
      recent_tool_names: ['keeper_board_post', 'keeper_tasks_list', 'Execute'],
      agent: {
        exists: true,
        name: 'keeper-analyst-agent',
        agent_type: 'agent',
        status: 'active',
        capabilities: ['keeper', 'research'],
        current_task: null,
        joined_at: '2026-05-01T00:46:51Z',
        last_seen: '2026-05-01T00:48:26Z',
        age_s: 1206,
        last_seen_ago_s: 1111,
        is_zombie: false,
      },
      diagnostic: {
        summary: 'Keeper runtime is reconciling back into live presence.',
        continuity_state: 'recovering',
        health_state: 'stale',
        quiet_reason: null,
        next_action_path: 'recover',
        recoverable: true,
        last_reply_status: 'never',
        last_reply_at: null,
        last_reply_preview: null,
        last_error: null,
        keepalive_running: true,
        next_eligible_at_s: null,
      },
      trust: {
        disposition: 'Blocked',
        disposition_reason: 'tool_route_recoverable_failure',
        needs_attention: true,
      },
    } as unknown as Keeper
    keepers.value = [analyst]

    const { container } = render(html`<${KeeperDetailPage} />`)
    // 3-pane workspace renders (roster | conversation | context rail) without
    // tripping the monitoring error boundary.
    expect(container.querySelector('.kw-grid')).toBeTruthy()
    // v2 reskin renamed the pane roots: KeeperWorkspaceRoster '.kw-roster' -> '.roster',
    // KeeperWorkspaceRail '.kw-rail' -> '.ctx'. Same elements, retargeted selectors.
    expect(container.querySelector('.roster')).toBeTruthy()
    expect(container.querySelector('.ctx')).toBeTruthy()
    // The grid binds data-mobile-pane to the keeperMobilePane signal — the
    // load-bearing hook the <=860px CSS pane-switch depends on. Entering a
    // keeper resets the signal to 'chat', so the attribute must reflect that
    // (guards against a silent attribute-name regression on the binding).
    const grid = container.querySelector('.kw-grid')
    expect(grid?.getAttribute('data-mobile-pane')).toBe('chat')
    expect(grid?.getAttribute('data-mobile-pane')).toBe(keeperMobilePane.value)
    // The keeper name appears in the roster row and the chat header.
    expect(screen.getAllByText('analyst').length).toBeGreaterThanOrEqual(1)
    // The reused chat engine is mounted in the conversation pane.
    expect(screen.getByText('direct chat analyst')).toBeTruthy()
    // FSM Hub is detail-only, not in the default conversation view.
    expect(screen.queryByText('FSM Hub (6축 상태 머신)')).toBeNull()
    expect(mocks.selectKeeper).toHaveBeenCalledWith('analyst')

    // "상세" flips to the full tabbed detail (KeeperDetailBody is reused).
    fireEvent.click(screen.getByRole('button', { name: '상세' }))
    const statusTab = await screen.findByRole('tab', { name: '상태' })
    fireEvent.click(statusTab)
    expect(statusTab.getAttribute('aria-selected')).toBe('true')
    expect(screen.getByText('운영 상태 개요')).toBeTruthy()
  })

  it('opens target keeper config as an overlay from the roster row menu after a keeper route change', async () => {
    keepers.value = [
      {
        name: 'analyst',
        status: 'active',
        phase: 'Running',
        lifecycle_phase: 'Running',
      },
      {
        name: 'executor',
        status: 'active',
        phase: 'Running',
        lifecycle_phase: 'Running',
      },
    ] as unknown as Keeper[]
    mocks.route.value = {
      tab: 'keepers',
      params: { keeper: 'analyst' },
      postId: null,
    }
    mocks.navigate.mockImplementationOnce((tab, params = {}) => {
      mocks.route.value = { tab, params, postId: null }
    })

    const { container, rerender } = render(html`<${KeeperDetailPage} />`)

    expect(container.querySelector('.kw-grid')?.getAttribute('data-detail')).toBe('closed')
    fireEvent.click(screen.getByTestId('kw-roster-menu-executor'))
    fireEvent.click(screen.getByTestId('kw-roster-menu-config'))
    rerender(html`<${KeeperDetailPage} />`)

    const grid = container.querySelector('.kw-grid')
    expect(mocks.navigate).toHaveBeenCalledWith('keepers', { keeper: 'executor' })
    expect(grid?.getAttribute('data-route-focused-keeper')).toBe('executor')
    expect(grid?.getAttribute('data-detail')).toBe('closed')
    expect(activeKeeperDetailSection.value).toBe('keeper-config')
    expect(screen.getByTestId('kw-config-overlay')).toBeTruthy()
    expect((await screen.findByTestId('keeper-config-panel')).getAttribute('data-keeper')).toBe('executor')

    fireEvent.click(screen.getByTestId('kw-config-close'))

    expect(container.querySelector('[data-testid="kw-config-overlay"]')).toBeNull()
  })

  // Removed test 'surfaces and clears keeper route focus...' (2026-05-19):
  // KeeperRouteFocusPanel was deleted as part of the Phase 5 layout SSOT
  // reconciliation. Page header (KeeperDetailHeaderInfo) renders the same
  // keeper name + status, and the existing close button covers the CLEAR
  // navigation. `data-route-focused-keeper` attribute moved to the outer
  // page container in keeper-detail-page.ts and remains testable from
  // there if needed.
})

function makeSummary(overrides: Partial<KeeperCheckpointSummary> = {}): KeeperCheckpointSummary {
  return {
    snapshot_id: 'snap-000',
    source_kind: 'oas_history',
    is_current: false,
    path: '/tmp/snap-000.json',
    created_at: 1_700_000_000,
    generation: 1,
    message_count: 10,
    system_prompt_present: true,
    latest_preview: null,
    file_stat: null,
    ...overrides,
  }
}

describe('filterCheckpointHistory', () => {
  const rows: readonly KeeperCheckpointSummary[] = [
    makeSummary({
      snapshot_id: 'snap-abc123',
      source_kind: 'oas_history',
      latest_preview: '유저 질문에 답변 완료',
    }),
    makeSummary({
      snapshot_id: 'snap-def456',
      source_kind: 'oas_current',
      latest_preview: 'Compaction triggered',
    }),
    makeSummary({
      snapshot_id: 'snap-ghi789',
      source_kind: 'oas_history',
      latest_preview: null,
    }),
  ]

  it('returns the input reference for empty query (no allocation)', () => {
    expect(filterCheckpointHistory(rows, '')).toBe(rows)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterCheckpointHistory(rows, '   \t\n ')).toBe(rows)
  })

  it('matches by snapshot_id substring (case-insensitive)', () => {
    const result = filterCheckpointHistory(rows, 'ABC')
    expect(result).toHaveLength(1)
    expect(result[0]?.snapshot_id).toBe('snap-abc123')
  })

  it('matches by source_kind', () => {
    const result = filterCheckpointHistory(rows, 'oas_current')
    expect(result).toHaveLength(1)
    expect(result[0]?.snapshot_id).toBe('snap-def456')
  })

  it('matches by latest_preview text including Korean', () => {
    const result = filterCheckpointHistory(rows, '답변')
    expect(result).toHaveLength(1)
    expect(result[0]?.snapshot_id).toBe('snap-abc123')
  })

  it('trims the query before matching', () => {
    const result = filterCheckpointHistory(rows, '  compaction  ')
    expect(result).toHaveLength(1)
    expect(result[0]?.snapshot_id).toBe('snap-def456')
  })

  it('returns empty array when nothing matches', () => {
    expect(filterCheckpointHistory(rows, 'no-such-token')).toEqual([])
  })

  it('does not mutate the input array or its elements', () => {
    const snapshot = rows.map(r => ({ ...r }))
    filterCheckpointHistory(rows, 'abc')
    expect(rows.map(r => ({ ...r }))).toEqual(snapshot)
  })

  it('handles rows with null preview without throwing', () => {
    const onlyNulls: readonly KeeperCheckpointSummary[] = [
      makeSummary({ snapshot_id: 'snap-null', latest_preview: null }),
    ]
    expect(() => filterCheckpointHistory(onlyNulls, 'missing')).not.toThrow()
    expect(filterCheckpointHistory(onlyNulls, 'missing')).toEqual([])
    expect(filterCheckpointHistory(onlyNulls, 'null')).toHaveLength(1)
  })

  it('preserves the original order of matching rows', () => {
    const result = filterCheckpointHistory(rows, 'snap-')
    expect(result.map(r => r.snapshot_id)).toEqual(['snap-abc123', 'snap-def456', 'snap-ghi789'])
  })
})

describe('lineageVerdictMeta', () => {
  it('maps verified to an operator-facing preserved-state explanation', () => {
    expect(lineageVerdictMeta('verified')).toEqual({
      badgeLabel: '상태 보존',
      detail: 'keeper 목표, 지침, 저장된 상태 요약이 핸드오프를 통해 전달됐는지 continuity 가 검사합니다.',
    })
  })

  it('maps drift_detected to a review-oriented explanation', () => {
    expect(lineageVerdictMeta('drift_detected')).toEqual({
      badgeLabel: '드리프트 검토',
      detail: '핸드오프는 완료됐지만 저장된 continuity 요약이 충분히 변경되어 operator 의 검토가 필요합니다.',
    })
  })

  it('falls back to unknown for unmapped verdicts', () => {
    expect(lineageVerdictMeta('mystery')).toEqual({
      badgeLabel: '알 수 없음',
      detail: 'continuity 신호는 존재하지만 본 판정이 아직 operator-facing 설명에 매핑되지 않았습니다.',
    })
  })
})

describe('lineageTransitionLabel', () => {
  it('uses root when the parent generation is absent', () => {
    expect(lineageTransitionLabel(null, 3)).toBe('root -> gen 3')
  })

  it('renders explicit generation-to-generation transitions', () => {
    expect(lineageTransitionLabel(4, 5)).toBe('gen 4 -> gen 5')
  })
})
