import { h } from 'preact'
import { cleanup, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

// Gate connectors have no global boot-time fetch (unlike governance/tools,
// which app.ts loads at app-mount and this test file never mounts), so
// Overview's own useEffect calls fetchGateConnectors directly. Mock it here so
// (a) the blocked-fetch guard in vitest-setup.ts never fires and (b) the
// "live payload" tests below can control what it resolves to. Default: an
// empty-but-successful connector list, harmless for every test that does not
// care about connector content.
const { mockFetchGateConnectors } = vi.hoisted(() => ({
  mockFetchGateConnectors: vi.fn().mockResolvedValue({
    connectors: [],
    total: 0,
    active_count: 0,
    discord_trigger_policy: 'unknown',
    generated_at: '2026-01-01T00:00:00Z',
  }),
}))
vi.mock('../../api/gate', () => ({
  fetchGateConnectors: mockFetchGateConnectors,
}))

// toolsData/toolsError back the 예약 승인 KPI + 예약·자동화 card. The
// underlying resource in tool-state.ts is not exported (by design — every
// other consumer reads the computed signal, not the resource), so the module
// is mocked with a plain mutable `{ value }` stand-in tests can set directly
// before render, mirroring components/keeper-shared.test.ts's convention.
const { mockedToolsData } = vi.hoisted(() => ({
  mockedToolsData: { value: null as unknown },
}))
vi.mock('../tools/tool-state', () => ({
  toolsData: mockedToolsData,
  toolsError: { value: null },
}))

import {
  deriveKeeperAttentionReason,
  pickAttentionKeepers,
  computeOverviewStats,
  computeOverviewDigest,
  buildOverviewTelemetrySnapshot,
  OVERVIEW_TELEMETRY_BAR_COUNT,
  OVERVIEW_TELEMETRY_EVENTS_PER_BUCKET,
  OVERVIEW_TELEMETRY_EVENT_SAMPLE_LIMIT,
  Overview,
} from './overview'
import type { FusionRunRecord, TelemetryEntry, TelemetrySourceSummary } from '../../api/dashboard'
import type { DashboardScheduledAutomation, DashboardScheduledAutomationRequest } from '../../api'
import { keepers, goals, boardTotal } from '../../store'
import type { Keeper, Goal } from '../../types/core'
import { governanceResource } from '../governance-signals'
import type { DashboardGovernanceResponse, KeeperApprovalQueueItem } from '../../types'
import type { GateConnectorInfo, GateConnectorsData } from '../../api/gate'

const FIXED_NOW = new Date(2026, 3, 18, 10, 0, 0, 0).getTime()

function localIsoAt(
  hour: number,
  minute: number = 0,
  second: number = 0,
  dayOffset: number = 0,
): string {
  const d = new Date(FIXED_NOW)
  d.setDate(d.getDate() + dayOffset)
  d.setHours(hour, minute, second, 0)
  return d.toISOString()
}

function makeKeeper(partial: Partial<Keeper>): Keeper {
  return { name: 'k', status: 'active', ...partial }
}

describe('deriveKeeperAttentionReason', () => {
  it('returns default warn reason when keeper has no attention signal', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({ name: 'plain' }))
    expect(reason.sev).toBe('warn')
    expect(reason.text).toBe('주의 사유 미보고')
    expect(reason.act).toBe('상태 상세')
  })

  it('marks continue_gate keepers as warn with approval action', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'gate',
      runtime_blocker_continue_gate: true,
      runtime_blocker_class: 'ambiguous_post_commit_timeout',
    }))
    expect(reason.sev).toBe('warn')
    expect(reason.act).toBe('승인 검토')
  })

  it('marks critical lifecycle states as bad', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'dead',
      lifecycle_phase: 'Dead',
      runtime_blocker_class: 'exception',
    }))
    expect(reason.sev).toBe('bad')
    expect(reason.act).toBe('재시작')
  })

  it('surfaces trust attention_reason as warn', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'trust',
      trust: {
        needs_attention: true,
        attention_reason: '승인 대기 3건',
        next_human_action: '승인 검토',
      },
    }))
    expect(reason.sev).toBe('warn')
    expect(reason.text).toBe('승인 대기 3건')
    expect(reason.act).toBe('승인 검토')
  })

  it('humanizes known attention_reason / next_human_action wire codes', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'coded',
      attention_reason: 'runtime_blocked',
      next_human_action: 'inspect_latest_error',
    }))
    expect(reason.text).toBe('런타임 근거 확인 필요')
    expect(reason.act).toBe('최근 오류 확인')
  })

  it('humanizes known completion-contract composite reason codes', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'composite',
      attention_reason: 'passive_only',
    }))
    expect(reason.text).toBe('진행 작업 없는 수동 응답')
  })
})

describe('pickAttentionKeepers', () => {
  it('returns empty array when no keepers need attention', () => {
    expect(pickAttentionKeepers([makeKeeper({ name: 'k1' })])).toEqual([])
  })

  it('selects keepers with needs_attention flag', () => {
    const keepers = [
      makeKeeper({ name: 'ok' }),
      makeKeeper({ name: 'att', needs_attention: true }),
    ]
    expect(pickAttentionKeepers(keepers).map(k => k.name)).toEqual(['att'])
  })

  it('selects keepers with runtime blocker awaiting_operator', () => {
    const keepers = [
      makeKeeper({ name: 'ok' }),
      makeKeeper({ name: 'op', runtime_blocker_class: 'awaiting_operator' }),
    ]
    expect(pickAttentionKeepers(keepers).map(k => k.name)).toEqual(['op'])
  })
})

describe('computeOverviewStats', () => {
  it('returns zeroed stats when empty', () => {
    expect(computeOverviewStats([])).toEqual({
      run: 0,
      att: 0,
      hot: 0,
      total: 0,
    })
  })

  it('counts running keepers and context pressure', () => {
    const keepers = [
      makeKeeper({ name: 'a', status: 'active', context_ratio: 0.9 }),
      makeKeeper({ name: 'b', status: 'offline', context_ratio: 0.5 }),
    ]
    const stats = computeOverviewStats(keepers)
    expect(stats.run).toBe(1)
    expect(stats.total).toBe(2)
    expect(stats.hot).toBe(1)
  })
})

describe('buildOverviewTelemetrySnapshot', () => {
  const nowMs = Date.parse('2026-04-18T10:00:00Z')
  const entry = (minutesAgo: number): TelemetryEntry => ({
    source: 'oas_event',
    ts_unix: (nowMs - minutesAgo * 60 * 1000) / 1000,
  })
  const sources: TelemetrySourceSummary[] = [
    {
      source: 'oas_event',
      entry_count: 10,
      latest_age_s: 8,
      health: 'ok',
      active_coverage_gap_count: 0,
    },
    {
      source: 'tool_call_io',
      entry_count: 3,
      health: 'ok',
      active_coverage_gap_count: 1,
    },
  ]

  it('builds 5-minute buckets from real telemetry timestamps', () => {
    const snapshot = buildOverviewTelemetrySnapshot({
      entries: [entry(1), entry(2), entry(8), entry(200)],
      sources,
      nowMs,
      totalMatchingEntries: 4,
    })

    expect(snapshot.bars).toHaveLength(OVERVIEW_TELEMETRY_BAR_COUNT)
    expect(snapshot.peakPerBucket).toBe(2)
    expect(snapshot.averagePerBucket).toBe(0.1)
    expect(snapshot.eventCount).toBe(4)
    expect(snapshot.latestAgeSeconds).toBe(8)
    expect(snapshot.healthySourceCount).toBe(2)
    expect(snapshot.sourceCount).toBe(2)
    expect(snapshot.activeCoverageGaps).toBe(1)
    expect(snapshot.bars.at(-1)).toBe(1)
  })

  it('does not invent bars when there are no matching telemetry rows', () => {
    const snapshot = buildOverviewTelemetrySnapshot({
      entries: [],
      sources: [],
      nowMs,
    })

    expect(snapshot.bars).toHaveLength(OVERVIEW_TELEMETRY_BAR_COUNT)
    expect(snapshot.bars.every(value => value === 0)).toBe(true)
    expect(snapshot.peakPerBucket).toBe(0)
    expect(snapshot.averagePerBucket).toBe(0)
    expect(snapshot.sourceHealth).toBe('unknown')
  })

  it('keeps the overview event sample tied to the rendered bar budget', () => {
    expect(OVERVIEW_TELEMETRY_EVENT_SAMPLE_LIMIT)
      .toBe(OVERVIEW_TELEMETRY_BAR_COUNT * OVERVIEW_TELEMETRY_EVENTS_PER_BUCKET)
  })

  it('preserves the API truncation signal for sample-derived metrics', () => {
    const snapshot = buildOverviewTelemetrySnapshot({
      entries: [entry(1), entry(2)],
      sources,
      nowMs,
      totalMatchingEntries: OVERVIEW_TELEMETRY_EVENT_SAMPLE_LIMIT + 1,
      truncated: true,
    })

    expect(snapshot.truncated).toBe(true)
    expect(snapshot.eventCount).toBe(OVERVIEW_TELEMETRY_EVENT_SAMPLE_LIMIT + 1)
  })
})

describe('Overview v2 marker classes', () => {
  afterEach(() => {
    cleanup()
  })

  it('applies v2 surface and panel marker classes on render', () => {
    const { container } = render(h(Overview, null))

    expect(container.querySelector('.v2-overview-surface')).not.toBeNull()
    expect(container.querySelector('.v2-overview-primary-grid')).not.toBeNull()
    expect(container.querySelector('.v2-overview-domains')).not.toBeNull()
  })

  it('renders keeper-v2 port marker classes', () => {
    const { container } = render(h(Overview, null))

    expect(container.querySelector('.v2-overview-head')).not.toBeNull()
    expect(container.querySelector('.v2-overview-kpis')).not.toBeNull()
    expect(container.querySelector('.v2-overview-attention')).not.toBeNull()
    expect(container.querySelector('.v2-overview-telemetry')).not.toBeNull()
    expect(container.querySelector('.v2-overview-domains')).not.toBeNull()
  })
})

describe('Overview StyleSeed surfaces', () => {
  afterEach(() => {
    cleanup()
  })

  it('applies StyleSeed surface/page tokens to root', () => {
    const { container } = render(h(Overview, null))
    const root = container.querySelector('.v2-overview-surface')
    expect(root?.classList.contains('ss-surface')).toBe(true)
    expect(root?.classList.contains('ov')).toBe(true)
    expect(root?.classList.contains('text-text-primary')).toBe(true)
  })

  it('renders the prototype primary sequence (kpis → grid → domains)', () => {
    const { container } = render(h(Overview, null))
    const sequence = [...container.querySelectorAll(
      '[data-testid="overview-kpis"], [data-testid="overview-primary-grid"], [data-testid="overview-domains"]',
    )].map(el => el.getAttribute('data-testid'))

    expect(sequence).toEqual([
      'overview-kpis',
      'overview-primary-grid',
      'overview-domains',
    ])
    expect(container.querySelector('.v2-overview-kpis')?.classList.contains('ov-kpis')).toBe(true)
    expect(container.querySelector('.v2-overview-domains')?.classList.contains('ov-domains')).toBe(true)
  })

  it('uses the prototype two-column overview grid container', () => {
    const { container } = render(h(Overview, null))
    const grid = container.querySelector('[data-testid="overview-primary-grid"]')
    expect(grid?.classList.contains('ov-grid')).toBe(true)
    expect(grid?.classList.contains('v2-overview-primary-grid')).toBe(true)
  })
})

// ─── Cross-surface digest ─────────────────────────────────────────────────────

function makeGoal(partial: Partial<Goal>): Goal {
  return {
    id: 'g-1',
    title: 'goal',
    priority: 5,
    status: 'active',
    phase: 'observe',
    created_at: localIsoAt(1),
    updated_at: localIsoAt(1),
    ...partial,
  }
}

function makeFusionRun(partial: Partial<FusionRunRecord>): FusionRunRecord {
  return {
    runId: 'fr-1',
    keeper: 'sangsu',
    preset: 'default',
    startedAt: 1_700_000_000,
    status: 'running',
    ...partial,
  }
}

function queueItem(overrides: Partial<KeeperApprovalQueueItem> = {}): KeeperApprovalQueueItem {
  return {
    id: 'q-1',
    keeper_name: 'sangsu',
    tool_name: 'fs_write',
    risk_level: 'low',
    ...overrides,
  }
}

describe('computeOverviewDigest', () => {
  it('returns zeroed digest with no data', () => {
    const digest = computeOverviewDigest([], [], [])
    expect(digest.openApprovals).toBe(0)
    expect(digest.approvalsCritical).toBe(false)
    expect(digest.topGoals).toEqual([])
    expect(digest.topGoalLabel).toBeNull()
    expect(digest.topGoalPriority).toBeNull()
    expect(digest.fusionRunning).toBe(0)
    expect(digest.fusionDone).toBe(0)
    expect(digest.fusionTotal).toBe(0)
    expect(digest.fusionLatest).toBeNull()
  })

  it('counts the governance approval queue as open approvals', () => {
    const digest = computeOverviewDigest([], [], [queueItem({ id: 'a' }), queueItem({ id: 'b' })])
    expect(digest.openApprovals).toBe(2)
    expect(digest.approvalsCritical).toBe(false)
  })

  it('flags approvals critical when any queued item sits in the bad risk band', () => {
    const digest = computeOverviewDigest([], [], [queueItem({ id: 'a', risk_level: 'critical' })])
    expect(digest.approvalsCritical).toBe(true)
  })

  it('orders top ACTIVE goals by priority and labels the leader by title', () => {
    const digest = computeOverviewDigest(
      [
        makeGoal({ id: 'low', priority: 2 }),
        makeGoal({ id: 'lead', priority: 9, title: '핵심 목표' }),
        makeGoal({ id: 'mid', priority: 5 }),
      ],
      [],
      [],
    )
    expect(digest.topGoals.map(g => g.id)).toEqual(['lead', 'mid', 'low'])
    expect(digest.topGoalLabel).toBe('핵심 목표')
    expect(digest.topGoalPriority).toBe(9)
  })

  it('excludes dropped/done goals from the top-goal slot even at higher priority', () => {
    const digest = computeOverviewDigest(
      [
        makeGoal({ id: 'dropped-high', priority: 9, status: 'dropped', title: '취소된 목표' }),
        makeGoal({ id: 'active-lead', priority: 7, status: 'active', title: '활성 목표' }),
      ],
      [],
      [],
    )
    expect(digest.topGoals.map(g => g.id)).toEqual(['active-lead'])
    expect(digest.topGoalLabel).toBe('활성 목표')
    expect(digest.topGoalPriority).toBe(7)
  })

  it('summarizes fusion runs by status and picks the newest as latest', () => {
    const digest = computeOverviewDigest(
      [],
      [
        makeFusionRun({ runId: 'older', status: 'completed', startedAt: 100 }),
        makeFusionRun({ runId: 'newest', status: 'running', startedAt: 300 }),
        makeFusionRun({ runId: 'mid', status: 'running', startedAt: 200 }),
      ],
      [],
    )
    expect(digest.fusionRunning).toBe(2)
    expect(digest.fusionDone).toBe(1)
    expect(digest.fusionTotal).toBe(3)
    expect(digest.fusionLatest?.runId).toBe('newest')
  })
})

// ─── Prototype overview surface (header / KPIs / domains) ─────────────────────

describe('Overview prototype surface', () => {
  afterEach(() => {
    cleanup()
  })

  it('renders the eyebrow + display header verbatim from the prototype', () => {
    const { container } = render(h(Overview, null))
    const head = container.querySelector('[data-testid="overview-head"]')
    expect(head?.querySelector('.ov-eyebrow')?.textContent).toBe('운영 홈')
    expect(head?.querySelector('h1')?.textContent).toBe('지금, 전체')
    expect(head?.querySelector('.ov-sub')?.textContent).toBe('fleet 전체 — 목표 · 승인 · 심의 · 연결 한눈에')
  })

  it('renders exactly 7 cross-surface KPI cells with the prototype labels', () => {
    const { container } = render(h(Overview, null))
    const cells = container.querySelectorAll('[data-testid="overview-kpis"] .ov-kpi')
    expect(cells).toHaveLength(7)
    const labels = [...cells].map(c => c.querySelector('.ov-kpi-k')?.textContent)
    expect(labels).toEqual([
      '실행 중 keeper',
      '주의 필요',
      '열린 승인',
      '최우선 목표',
      '활성 커넥터',
      '예약 승인',
      '진행 심의',
    ])
  })

  it('marks deep-link KPI cells as buttons', () => {
    const { container } = render(h(Overview, null))
    const runCell = container.querySelector('[data-testid="kpi-run"]')
    expect(runCell?.classList.contains('link')).toBe(true)
    expect(runCell?.getAttribute('role')).toBe('button')
  })

  it('renders the 도메인 현황 section header', () => {
    const { container } = render(h(Overview, null))
    const header = container.querySelector('[data-testid="overview-domains-header"]')
    expect(header?.classList.contains('ov-section-h')).toBe(true)
    expect(header?.textContent).toBe('도메인 현황')
  })

  it('renders all 7 domain cards in prototype order', () => {
    const { container } = render(h(Overview, null))
    const cards = container.querySelectorAll('[data-testid="overview-domains"] .ov-dcard')
    expect(cards).toHaveLength(7)
    const titles = [...cards].map(c => c.querySelector('.ov-dcard-h h3')?.textContent)
    expect(titles).toEqual([
      '작업 · 목표',
      '승인 큐',
      '예약 · 자동화',
      'Fusion 심의',
      '보드',
      '커넥터',
      'Fleet 요약',
    ])
  })

  it('places the domain section last, after the primary grid', () => {
    const { container } = render(h(Overview, null))
    const order = [...container.querySelectorAll(
      '[data-testid="overview-primary-grid"], [data-testid="overview-domains"]',
    )].map(el => el.getAttribute('data-testid'))
    expect(order).toEqual(['overview-primary-grid', 'overview-domains'])
  })

  // Gap 1: KPI grid uses 6-column layout (surfaces.css:88 `repeat(6, 1fr)`)
  it('KPI grid declares 6-column repeat matching prototype surfaces.css:88', () => {
    const { container } = render(h(Overview, null))
    const grid = container.querySelector('[data-testid="overview-kpis"]') as HTMLElement | null
    expect(grid).not.toBeNull()
    // The grid class is ov-kpis; CSS sets grid-template-columns: repeat(6, 1fr)
    expect(grid?.classList.contains('ov-kpis')).toBe(true)
    // 7 cells exist — 7th wraps to second row in a 6-col grid (prototype intent)
    expect(container.querySelectorAll('[data-testid="overview-kpis"] .ov-kpi')).toHaveLength(7)
  })

  // Gap 2: attention panel title includes full subtitle (overview.jsx:119)
  it('attention panel h3 includes the full prototype title with subtitle', () => {
    const { container } = render(h(Overview, null))
    const attn = container.querySelector('[data-testid="overview-attention"]')
    const h3 = attn?.querySelector('.ov-card-h h3')
    expect(h3?.textContent).toBe('주의 필요 · 지금 손이 필요한 것')
  })

  // Gap 3: telemetry panel shows "로그 보기 →" button link (overview.jsx:143)
  it('telemetry panel header shows a "로그 보기 →" link button', () => {
    const { container } = render(h(Overview, null))
    const tel = container.querySelector('[data-testid="overview-telemetry"]')
    const btn = tel?.querySelector('button.ov-link')
    expect(btn).not.toBeNull()
    expect(btn?.textContent).toBe('로그 보기 →')
  })

  // The attention row's mono sublabel exists to show the wire name next to a
  // localized display name; when they are identical it printed "base base".
  it('attention row hides the ns sublabel when display name equals keeper name', () => {
    const previousKeepers = keepers.value
    keepers.value = [
      makeKeeper({ name: 'base', needs_attention: true }),
      makeKeeper({ name: 'nick0cave', koreanName: '닉케이브', needs_attention: true }),
    ]
    try {
      const { container } = render(h(Overview, null))
      const plain = container.querySelector('[data-testid="attention-row-base"] .ov-attn-name')
      expect(plain?.textContent?.trim()).toBe('base')
      expect(plain?.querySelector('.ov-attn-ns')).toBeNull()
      const localized = container.querySelector('[data-testid="attention-row-nick0cave"] .ov-attn-name')
      expect(localized?.querySelector('.ov-attn-ns')?.textContent).toBe('nick0cave')
    } finally {
      keepers.value = previousKeepers
    }
  })
})

// ─── KPI/domain card wiring from live payloads (masc campaign #43) ────────────
//
// governanceData/goals/boardTotal are real store signals — Overview's own
// render tree never fetches them (app.ts does, at boot, outside this test),
// so tests seed the signal directly. Gate connectors are the one signal
// Overview itself fetches (see loadOverviewConnectors), so that case mocks
// fetchGateConnectors and drives the real effect via waitFor instead.

function gateConnector(overrides: Partial<GateConnectorInfo> = {}): GateConnectorInfo {
  return {
    connector_id: 'discord',
    display_name: 'Discord',
    connected: true,
    available: true,
    ...overrides,
  } as GateConnectorInfo
}

function gateConnectorsData(connectors: GateConnectorInfo[]): GateConnectorsData {
  return {
    connectors,
    total: connectors.length,
    active_count: connectors.filter(c => c.connected).length,
    discord_trigger_policy: 'mention',
    generated_at: '2026-07-11T00:00:00Z',
  }
}

function scheduledRequest(overrides: Partial<DashboardScheduledAutomationRequest> = {}): DashboardScheduledAutomationRequest {
  return {
    schedule_id: 's-1',
    status: 'pending_approval',
    risk_class: 'low',
    approval_required: true,
    source: 'keeper',
    ...overrides,
  }
}

function scheduledAutomation(requests: DashboardScheduledAutomationRequest[]): DashboardScheduledAutomation {
  return {
    request_count: requests.length,
    request_limit: 100,
    truncated: false,
    counts: {},
    fsm: { state: 'idle', active_count: 0, terminal_count: 0 },
    requests,
  }
}

function governanceResponse(approvalQueue: KeeperApprovalQueueItem[]): DashboardGovernanceResponse {
  return { approval_queue: approvalQueue }
}

describe('Overview KPI + domain card wiring (live payloads)', () => {
  afterEach(() => {
    cleanup()
    governanceResource.reset(null)
    keepers.value = []
    goals.value = []
    boardTotal.value = null
    mockedToolsData.value = null
    mockFetchGateConnectors.mockClear()
  })

  it('renders 열린 승인 KPI + 승인 큐 card from governanceData.approval_queue, not keeper blocker flags', () => {
    governanceResource.state.value = {
      data: governanceResponse([
        queueItem({ id: 'a', risk_level: 'low' }),
        queueItem({ id: 'b', risk_level: 'critical' }),
      ]),
      loading: false,
      error: null,
    }
    // A keeper in a critical runtime state must NOT move this KPI any more —
    // it is no longer a keeper-blocker projection (the bug this PR fixes).
    keepers.value = [makeKeeper({ name: 'dead', lifecycle_phase: 'Dead', runtime_blocker_class: 'exception' })]

    const { container } = render(h(Overview, null))

    const kpi = container.querySelector('[data-testid="kpi-approvals"] .ov-kpi-v')
    expect(kpi?.firstChild?.textContent).toBe('2')
    expect(kpi?.classList.contains('bad')).toBe(true)
    const card = container.querySelector('[data-testid="domain-approvals"] .ov-dcount')
    expect(card?.textContent).toBe('2')
  })

  it('renders 최우선 목표 KPI as the top ACTIVE goal title + priority, excluding dropped goals', () => {
    goals.value = [
      makeGoal({ id: 'dropped', priority: 9, status: 'dropped', title: '취소된 목표' }),
      makeGoal({ id: 'lead', priority: 7, status: 'active', title: '핵심 목표' }),
    ]

    const { container } = render(h(Overview, null))

    const kpi = container.querySelector('[data-testid="kpi-top-goal"] .ov-kpi-v')
    expect(kpi?.firstChild?.textContent).toBe('핵심 목표')
    expect(kpi?.querySelector('small')?.textContent).toBe('P7')
  })

  it('renders 보드 domain card from the boardTotal store signal, not the client post array length', () => {
    boardTotal.value = 42

    const { container } = render(h(Overview, null))

    const card = container.querySelector('[data-testid="domain-board"] .ov-stat-row .v')
    expect(card?.textContent).toBe('42')
  })

  it('renders 활성 커넥터 KPI + 커넥터 domain card from the live gate connectors payload', async () => {
    mockFetchGateConnectors.mockResolvedValueOnce(gateConnectorsData([
      gateConnector({ connector_id: 'discord', display_name: 'Discord', connected: true }),
      gateConnector({ connector_id: 'slack', display_name: 'Slack', connected: false }),
    ]))

    const { container } = render(h(Overview, null))

    await waitFor(() => {
      const kpi = container.querySelector('[data-testid="kpi-connectors"] .ov-kpi-v')
      expect(kpi?.firstChild?.textContent).toBe('1')
    })
    const card = container.querySelector('[data-testid="domain-connectors"]')
    expect(card?.querySelectorAll('.ov-mini-row')).toHaveLength(2)
    expect(card?.textContent).toContain('Discord')
    expect(card?.textContent).toContain('Slack')
  })

  it('renders 예약 승인 KPI + 예약·자동화 card from the scheduled-automation projection', () => {
    mockedToolsData.value = {
      scheduled_automation: scheduledAutomation([
        scheduledRequest({ schedule_id: 's-1', status: 'pending_approval' }),
        scheduledRequest({ schedule_id: 's-2', status: 'scheduled' }),
      ]),
    }

    const { container } = render(h(Overview, null))

    const kpi = container.querySelector('[data-testid="kpi-schedule"] .ov-kpi-v')
    expect(kpi?.firstChild?.textContent).toBe('1')
    const card = container.querySelector('[data-testid="domain-schedule"]')
    expect(card?.textContent).toContain('승인 대기 1건')
    expect(card?.textContent).toContain('2')
  })
})
