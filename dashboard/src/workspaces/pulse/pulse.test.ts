import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { html } from 'htm/preact'
import { render, fireEvent, waitFor, cleanup } from '@testing-library/preact'
import {
  formatObserved,
  observedAbsent,
  observedValue,
  resourceCache,
} from '../../core/resource-cache'
import { resetTimeWindowForTests } from '../../core/time-window'
import { resetObserverStateForTests } from '../../core/observer'
import { resetAuthStateForTests, authSession } from '../../core/auth'
import {
  buildAttentionQueue,
  buildCompanyFleetGroups,
  buildPulseKpis,
  buildTeamHandoffPulse,
  classifySpendStatus,
  formatCompactCount,
  formatMilliCandle,
  observeKeeperContextPct,
} from './pulse-model'
import { loadPulseBundle } from './pulse-data'
import { PulseWorkspace } from './index'
import type { PulseKeeperRow } from './types'

function makeKeeper(overrides: Partial<PulseKeeperRow> = {}): PulseKeeperRow {
  return {
    name: 'code-reviewer-sister',
    status: 'running',
    phase: 'idle',
    health: 'healthy',
    paused: false,
    keepalive_running: true,
    runtime_id: 'claude-code',
    sandbox_profile: 'microvm',
    context_ratio: 0.42,
    context_tokens: 84_000,
    context_max: 200_000,
    context_unavailable_reason: null,
    next_action: null,
    runtime_blocker_summary: null,
    last_failure: null,
    recent_turns: null,
    candle_balance_milli: '5000',
    directory_issue: null,
    ...overrides,
  }
}

const USAGE_NOW = 1_700_000_000

describe('Pulse Workspace — Model & Formatters', () => {
  it('formats compact counts with exact tooltips and preserves zero vs absent', () => {
    expect(formatCompactCount(63_200_000)).toEqual({ short: '63.2M', exact: '63,200,000' })
    expect(formatCompactCount(400_000)).toEqual({ short: '400k', exact: '400,000' })
    expect(formatCompactCount(0)).toEqual({ short: '0', exact: '0' })

    const zeroCtx = observeKeeperContextPct(makeKeeper({ context_ratio: 0 }))
    expect(formatObserved(zeroCtx, (v) => `${v}%`)).toBe('0%')

    const absentCtx = observeKeeperContextPct(makeKeeper({ context_ratio: null, context_unavailable_reason: 'no_turn' }))
    expect(formatObserved(absentCtx, (v) => `${v}%`)).toBe('없음')
  })

  it('classifies $0 Sub, $0 Exhausted, ? Unreported, and reported USD honestly', () => {
    const subZero = classifySpendStatus(
      observedValue([
        { keeper_name: 'k1', total_cost_usd: null, cost_reported_samples: 0, cost_unreported_samples: 12, total_tokens: 1000, sample_count: 12 },
      ]),
      observedValue({
        state: 'available',
        days: 1,
        reported_no_windows: [],
        undecodable_points: 0,
        points: [{ scope_id: 'claude', source: 'sub', kind: 'subscription', limit_id: null, observed_at: USAGE_NOW - 60, resets_at: null, utilization: { unit: 'credit_unlimited' } }],
      }),
      0,
      USAGE_NOW,
    )
    expect(subZero.kind).toBe('subscription_zero')

    const realWindowSub = classifySpendStatus(
      observedValue([
        { keeper_name: 'k1', total_cost_usd: null, cost_reported_samples: 0, cost_unreported_samples: 5, total_tokens: 500, sample_count: 5 },
      ]),
      observedValue({
        state: 'available',
        days: 1,
        reported_no_windows: [],
        undecodable_points: 0,
        points: [
          { scope_id: 'claude', source: 'quota', kind: '5h', limit_id: null, observed_at: USAGE_NOW - 60, resets_at: USAGE_NOW + 3600, utilization: { unit: 'fraction', value: 0.35 } },
          { scope_id: 'codex', source: 'quota', kind: 'weekly', limit_id: null, observed_at: USAGE_NOW - 60, resets_at: USAGE_NOW + 86400, utilization: { unit: 'percent', value: 42 } },
        ],
      }),
      0,
      USAGE_NOW,
    )
    expect(realWindowSub.kind).toBe('subscription_zero')
    if (realWindowSub.kind === 'subscription_zero') {
      expect(realWindowSub.quota.subscription).toBe(2)
    }

    const exhaustedZero = classifySpendStatus(
      observedValue([
        { keeper_name: 'k1', total_cost_usd: null, cost_reported_samples: 0, cost_unreported_samples: 3, total_tokens: 500, sample_count: 3 },
      ]),
      observedValue({
        state: 'available',
        days: 1,
        reported_no_windows: [],
        undecodable_points: 0,
        points: [{ scope_id: 'codex', source: 'quota', kind: 'rate', limit_id: null, observed_at: USAGE_NOW - 60, resets_at: USAGE_NOW + 1800, utilization: { unit: 'fraction', value: 1.0 } }],
      }),
      0,
      USAGE_NOW,
    )
    expect(exhaustedZero.kind).toBe('exhausted_zero')

    const unreported = classifySpendStatus(
      observedAbsent(),
      observedValue({ state: 'unavailable', reason: 'ledger store offline' }),
      null,
      USAGE_NOW,
    )
    expect(unreported.kind).toBe('unreported')

    const reported = classifySpendStatus(
      observedValue([
        { keeper_name: 'k1', total_cost_usd: 14.25, cost_reported_samples: 10, cost_unreported_samples: 0, total_tokens: 400_000, sample_count: 10 },
      ]),
      observedAbsent(),
      null,
      USAGE_NOW,
    )
    expect(reported.kind).toBe('reported')
    if (reported.kind === 'reported') {
      expect(reported.usd).toBeCloseTo(14.25)
    }
  })

  it('builds strictly 4 KPI hero cards with zero orphan 7th card', () => {
    const kpis = buildPulseKpis({
      shell: observedValue({
        generated_at: null,
        project: 'masc',
        version: '0.81.0',
        counts: { agents: 4, tasks: 20, tasks_done_24h: 12, keepers: 3, configured_keepers: 4, total_runtimes: 2 },
        scorecard: {
          tasks_done_24h: 12,
          tasks_awaiting_verification: 3,
          tasks_in_progress: 2,
          turns_24h: 400_000,
          cost_24h_usd: 0,
          verifications_passed_24h: 10,
          verifications_rejected_24h: 1,
          goals_completed_24h: 1,
        },
        groups: [],
      }),
      keepers: observedValue([makeKeeper(), makeKeeper({ name: 'e-masc-the-leader', health: 'failing' })]),
      costs: observedValue([
        { keeper_name: 'code-reviewer-sister', total_cost_usd: null, cost_reported_samples: 0, cost_unreported_samples: 5, total_tokens: 63_200_000, sample_count: 5 },
      ]),
      usage: observedValue({
        state: 'available',
        days: 1,
        reported_no_windows: [],
        undecodable_points: 0,
        points: [{ scope_id: 'claude', source: 'sub', kind: 'subscription', limit_id: null, observed_at: USAGE_NOW - 60, resets_at: null, utilization: { unit: 'credit_unlimited' } }],
      }),
      window: '24h',
      nowSec: USAGE_NOW,
    })

    expect(kpis).toHaveLength(4)
    expect(kpis.map((k) => k.id)).toEqual(['active_keepers', 'tasks_24h', 'turns_24h', 'spend_24h'])
    expect(formatObserved(kpis[2]!.value)).toBe('400k')
    expect(kpis[2]!.secondary).toBe('63.2M tokens')
    expect(formatObserved(kpis[3]!.value)).toBe('$0 Sub')
  })

  it('sorts attention queue by severity and maps routes accurately', () => {
    const now = 1_700_000_000
    const queue = buildAttentionQueue({
      approvals: [{ approval_id: 'a1', keeper: 'code-reviewer-sister', tool_call_id: 'tc1', tool: 'bash', question: 'Run test?', because: null, asked_at: now - 30, timeout_sec: null }],
      asks: [{ ask_id: 'ask1', keeper: 'e-masc-the-leader', summary: 'Choose release tag', created_at: now - 120, question_count: 1 }],
      keepers: [makeKeeper({ name: 'broken-keeper', health: 'failing', runtime_blocker_summary: 'provider 429' })],
      nowSec: now,
    })

    expect(queue).toHaveLength(3)
    expect(queue[0]!.severity).toBe('critical')
    expect(queue.find((q) => q.kind === 'approval')?.route).toBe('/work/inbox')
    expect(queue.find((q) => q.kind === 'keeper_failure')?.route).toBe('/keepers/broken-keeper/chat')
  })

  it('groups fleet keepers by company and anchors 24h sparklines with null gaps before known_since', () => {
    const now = 1_700_000_000
    const slotTs = Math.floor(now / 1800) * 1800
    const groups = buildCompanyFleetGroups({
      keepers: [
        makeKeeper({
          name: 'code-reviewer-sister',
          recent_turns: {
            known_since: slotTs - 3600,
            slots: [{ starts_at: slotTs, ok: 4, rested: 1, failed: 0, scheduled: 2, reacted: 1, chat: 2, own: 0, unknown: 0 }],
          },
        }),
        makeKeeper({ name: 'code-reviewer-uncle' }),
      ],
      shellGroups: [{ group: 'Reviewers', keeper_count: 2, keepers: ['code-reviewer-sister', 'code-reviewer-uncle'] }],
      window: '7d',
      nowSec: now,
    })

    expect(groups).toHaveLength(1)
    expect(groups[0]!.company).toBe('Reviewers')
    expect(groups[0]!.window).toBe('24h')
    expect(groups[0]!.turnsInWindow).toBe(5)
    expect(groups[0]!.sparklineData[0]).toHaveLength(48)
    // Prior unobserved slots before known_since must be null (gap), NEVER fabricated 0
    expect(groups[0]!.sparklineData[1]![0]).toBeNull()
    expect(groups[0]!.sparklineData[1]![47]).toBe(5)
  })

  it('keeps Turns/Spend KPIs honestly labeled 24h even when global timeWindow is 7d/30d', () => {
    const kpis = buildPulseKpis({
      shell: observedValue({
        generated_at: null,
        project: 'masc',
        version: '0.81.0',
        counts: { agents: 1, tasks: 1, tasks_done_24h: 1, keepers: 1, configured_keepers: 1, total_runtimes: 1 },
        scorecard: {
          tasks_done_24h: 1,
          tasks_awaiting_verification: 0,
          tasks_in_progress: 0,
          turns_24h: 10,
          cost_24h_usd: 1.5,
          verifications_passed_24h: 1,
          verifications_rejected_24h: 0,
          goals_completed_24h: 0,
        },
        groups: [],
      }),
      keepers: observedValue([makeKeeper()]),
      costs: observedAbsent(),
      usage: observedAbsent(),
      window: '30d',
      nowSec: USAGE_NOW,
    })
    expect(kpis[2]!.label).toBe('Turns / 24h')
    expect(kpis[3]!.label).toBe('Spend / 24h')
    expect(kpis[3]!.secondary).toContain('비용 24h')
  })

  it('extracts multi-keeper team handoff & succession entries without Cytoscape', () => {
    const handoffs = buildTeamHandoffPulse(
      [
        {
          id: 'p1',
          title: 'PR #123 handoff',
          body: 'Passing review to @code-reviewer-uncle',
          author: 'code-reviewer-sister',
          hearth: 'pr-review',
          created_at: '2026-11-24T00:00:00Z',
          reply_count: 2,
          mentions: [],
          succession_parent_id: null,
        },
        {
          id: 'p2',
          title: 'Leader succession',
          body: 'Continuing sprint',
          author: 'e-masc-the-leader',
          hearth: 'ops',
          created_at: '2026-11-24T00:01:00Z',
          reply_count: 0,
          mentions: [],
          succession_parent_id: 'p0',
        },
      ],
      [makeKeeper({ name: 'code-reviewer-sister' }), makeKeeper({ name: 'code-reviewer-uncle' }), makeKeeper({ name: 'e-masc-the-leader' })],
    )

    expect(handoffs).toHaveLength(2)
    expect(handoffs[0]!.kind).toBe('handoff')
    expect(handoffs[0]!.toKeepers).toEqual(['code-reviewer-uncle'])
    expect(handoffs[0]!.route).toBe('/knowledge/board/p1')
    expect(handoffs[1]!.kind).toBe('succession')
    expect(handoffs[1]!.route).toBe('/knowledge/board/p2')
  })

  it('surfaces path-resting keepers, failover details, and ok/rested/failed breakdown on Pulse', () => {
    const now = 1_700_000_000
    const slotTs = Math.floor(now / 1800) * 1800
    const restingKeeper = makeKeeper({
      name: 'resting-keeper',
      health: 'healthy',
      keepalive_running: true,
      paused: false,
      runtime_path_rest: { status: 'resting', runtime_id: 'ollama_cloud', release_at: '2026-11-25T02:00:00Z', release_basis: 'rate_limit' },
      recent_turns: {
        known_since: slotTs - 3600,
        slots: [{ starts_at: slotTs, ok: 1, rested: 3, failed: 5, scheduled: 0, reacted: 0, chat: 0, own: 0, unknown: 0 }],
      },
    })
    const pausedOnRestingRuntime = makeKeeper({
      name: 'paused-keeper',
      health: 'healthy',
      phase: 'paused',
      keepalive_running: false,
      paused: true,
      runtime_path_rest: { status: 'resting', runtime_id: 'ollama_cloud', release_at: '2026-11-25T02:00:00Z', release_basis: 'rate_limit' },
    })
    const failingKeeper = makeKeeper({
      name: 'failing-keeper',
      health: 'failing',
      operator_disposition: 'retry_later',
      failing_since: now - 180,
      runtime_lane_failures: [
        { runtime_id: 'ollama_cloud', summary: 'session limit', fault_kind: 'rate_limit' },
      ],
    })
    const queue = buildAttentionQueue({
      approvals: [],
      asks: [],
      keepers: [restingKeeper, pausedOnRestingRuntime, failingKeeper],
      nowSec: now,
    })
    expect(queue).toHaveLength(2)
    expect(queue.some((q) => q.keeper === 'paused-keeper')).toBe(false)
    expect(queue.find((q) => q.keeper === 'resting-keeper')?.title).toContain('경로 휴식')
    expect(queue.find((q) => q.keeper === 'failing-keeper')?.detail).toContain('ollama_cloud')
    expect(queue.find((q) => q.keeper === 'failing-keeper')?.detail).toContain('retry_later')

    const groups = buildCompanyFleetGroups({
      keepers: [restingKeeper, pausedOnRestingRuntime, failingKeeper],
      shellGroups: [],
      window: '24h',
      nowSec: now,
    })
    const restGroup = groups.find((g) => g.keepers.some((k) => k.name === 'resting-keeper'))!
    expect(restGroup.activeCount).toBe(0)
    expect(restGroup.restingCount).toBe(1)
    expect(restGroup.okTurnsInWindow).toBe(1)
    expect(restGroup.restedTurnsInWindow).toBe(3)
    expect(restGroup.failedTurnsInWindow).toBe(5)
  })

  it('formats decimal-string milli-Candle values without float precision loss', () => {
    expect(formatObserved(formatMilliCandle('1234567890123'))).toBe('1,234,567,890.123')
    expect(formatObserved(formatMilliCandle('0'))).toBe('0.000')
    expect(formatObserved(formatMilliCandle(null))).toBe('없음')
  })

  it('uses zero raw hex colors and zero off-grid px spacing literals in pulse.css', () => {
    const cssPath = resolve(process.cwd(), 'src/workspaces/pulse/pulse.css')
    const css = readFileSync(cssPath, 'utf8')
    expect(css).not.toMatch(/#[0-9a-fA-F]{3,8}\b/)
    expect(css).not.toMatch(/\b(?:padding|margin|gap):\s*[^;]*\b(?:1|2|3|5|6|10)px\b/)
  })
})

describe('PulseWorkspace DOM Integration', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    resetTimeWindowForTests('24h')
    resetObserverStateForTests()
    resourceCache.clearAll()
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  it('renders 4-KPI Hero Strip, Attention Queue, Fleet Groups, and navigates on click with <1200 DOM nodes', async () => {
    let releaseUsage!: () => void
    const waitForUsage = new Promise<void>((resolve) => { releaseUsage = resolve })
    const mockFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      const json = (data: unknown) =>
        new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
      if (url.includes('/api/v1/dashboard/shell')) {
        return json({
          counts: { keepers: 2, configured_keepers: 2, tasks_done_24h: 9 },
          scorecard_24h: { tasks_done_24h: 9, tasks_awaiting_verification: 2, turns_24h: 1250, cost_24h_usd: 0 },
          groups: [{ group: 'Core', keeper_count: 2, keepers: ['code-reviewer-sister', 'e-masc-the-leader'] }],
        })
      }
      if (url.includes('/api/v1/gate/keepers')) {
        return json({
          keepers: [
            { name: 'code-reviewer-sister', status: 'running', phase: 'idle', health: 'healthy', paused: false, keepalive_running: true, runtime_id: 'claude-code', context_ratio: 0.35 },
            { name: 'e-masc-the-leader', status: 'running', phase: 'idle', health: 'failing', paused: false, keepalive_running: true, runtime_id: 'codex', context_ratio: 0.78, runtime_blocker_summary: 'rate limited' },
          ],
        })
      }
      if (url.includes('/api/v1/dashboard/keeper-costs')) {
        return json({ keepers: [{ keeper_name: 'code-reviewer-sister', total_cost_usd: null, cost_reported_samples: 0, cost_unreported_samples: 8, total_tokens: 400_000, sample_count: 8 }] })
      }
      if (url.includes('/api/v1/dashboard/provider-usage-history')) {
        await waitForUsage
        return json({ days: 1, reported_no_windows: [], points: [{ scope_id: 'claude', source: 'sub', kind: 'subscription', observed_at: Date.now() / 1000 - 60, resets_at: null, unit: 'credit_unlimited' }] })
      }
      if (url.includes('/api/v1/keepers/tool-approvals')) {
        return json({ pending: [{ approval_id: 'ap-1', keeper: 'code-reviewer-sister', tool_call_id: 'tc-1', tool: 'git_push', question: 'Allow push?', asked_at: Date.now() / 1000 - 15 }] })
      }
      if (url.includes('/api/v1/keepers/asks')) return json({ asks: [] })
      if (url.includes('/api/v1/dashboard/goals')) {
        return json({ approval_queue_state: { state: 'ready' }, tree: [{ id: 'g-1', title: 'Ship Proposal A+', phase: 'Verifying', task_count: 5, task_done_count: 4, task_summary: { awaiting_verification: 1 } }], summary: { pending_approvals: 0 } })
      }
      if (url.includes('/api/v1/dashboard/board')) {
        return json({ posts: [{ id: 'b1', title: 'Review handoff', body: 'Over to @e-masc-the-leader', author: 'code-reviewer-sister', comment_count: 2 }] })
      }
      if (url.includes('/api/v1/memory/world')) {
        return json({ schema_version: 1, instance_id: 'i1', generated_at_unix: 1, data: { ledger_state: 'available', inventory: { claims_count: 42, facts_count: 120, conflicts_count: 1 }, briefing: { status: 'ready', text: 'ok' }, world_mvcc: { wiki_count: 14, artifact_count: 7 } } })
      }
      if (url.includes('/api/v1/candle/ledger')) {
        return json({ schema_version: 1, instance_id: 'i1', generated_at_unix: 1, data: { ledger_state: 'missing', total_events: 0, policy: { configuration: 'off', disabled_reason: null, pricing_mode: 'off', half_life: { mode: 'off', half_life_hours: null } }, supply: { issued_milli: '0', burned_milli: '0', circulating_milli: '0', active_keepers: 0 } } })
      }
      return json({})
    })
    vi.stubGlobal('fetch', mockFetch)

    const onNavigate = vi.fn()
    const onInspect = vi.fn()

    const { container, getAllByRole, queryByText } = render(
      html`<${PulseWorkspace} subroute="" onNavigate=${onNavigate} onInspect=${onInspect} />`,
    )

    await waitFor(() => {
      expect(container.querySelectorAll('[data-kpi-id]').length).toBe(4)
      expect(container.textContent).toContain('Ship Proposal A+')
      expect(getAllByRole('button', { name: '이동' }).length).toBeGreaterThan(0)
    })
    expect(container.textContent).not.toContain('$0 Sub')
    fireEvent.click(getAllByRole('button', { name: '이동' })[0]!)
    expect(onNavigate).toHaveBeenCalledWith('/work/inbox')

    releaseUsage()
    await waitFor(() => expect(container.textContent).toContain('$0 Sub'))

    // Zero empty 0.000 Candle box when policy is off
    expect(queryByText('0.000 C')).toBeNull()

    // DOM node budget check (<1,200)
    expect(container.querySelectorAll('*').length).toBeLessThan(1200)

    // Zero inline style attributes on Pulse elements (outside uPlot/primitive internals)
    const inlineStyled = Array.from(container.querySelectorAll('[style]')).filter(
      (el) => !el.closest('.uplot-mount'),
    )
    expect(inlineStyled).toHaveLength(0)

  })

  it('clamps /api/v1/dashboard/keeper-costs?window=1440 on 7d and 30d windows (P1-4)', async () => {
    const requestedUrls: string[] = []
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: RequestInfo | URL) => {
        requestedUrls.push(String(input))
        return new Response(JSON.stringify({ keepers: [], pending: [], asks: [], tree: [], posts: [], data: {} }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }),
    )

    await loadPulseBundle('30d', 'manual')
    expect(requestedUrls).toContain('/api/v1/dashboard/keeper-costs?window=1440')
    expect(requestedUrls.some((u) => u.includes('keeper-costs?window=43200'))).toBe(false)
    expect(requestedUrls).toContain('/api/v1/dashboard/provider-usage-history?days=14')
  })

  it('surfaces unbridged approvals/asks honestly in multi_account_signed_in instead of green 0건 empty state', async () => {
    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'acc-1',
      email: 'operator@example.com',
      displayName: 'Operator',
      role: 'admin',
      csrfToken: 'csrf-tok-1',
      authMethods: { google: true, github: false, dev_token: false },
      workspaceId: 'default',
    }
    const requestedUrls: string[] = []
    let keeperHealth: 'healthy' | 'failing' = 'healthy'
    const mockFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      requestedUrls.push(url)
      const json = (data: unknown) =>
        new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
      if (url.includes('/api/v1/dashboard/shell')) {
        return json({ counts: { keepers: 1, configured_keepers: 1, tasks_done_24h: 0 }, groups: [] })
      }
      if (url.includes('/api/v1/gate/keepers')) {
        return json({
          keepers: [
            {
              name: 'code-reviewer-sister',
              status: 'running',
              phase: 'idle',
              health: keeperHealth,
              paused: false,
              keepalive_running: true,
              runtime_id: 'claude-code',
              runtime_blocker_summary: keeperHealth === 'failing' ? 'provider 429' : null,
            },
          ],
        })
      }
      return json({ keepers: [], points: [], tree: [], posts: [], data: {} })
    })
    vi.stubGlobal('fetch', mockFetch)

    // 1. All keepers healthy, approvals & asks unbridged -> MUST NOT claim green 0건 or empty queue
    const first = render(
      html`<${PulseWorkspace} subroute="" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
    )
    await waitFor(() => {
      const attn = first.container.querySelector('section[aria-label="주의 필요 대기열"]')
      expect(attn?.textContent).toContain('일부 미확인')
      expect(attn?.textContent).toContain('도구 승인 (멀티 계정 미지원)')
      expect(attn?.textContent).toContain('Keeper 질문 (멀티 계정 미지원)')
      expect(attn?.textContent).toContain('비어 있음으로 확정할 수 없습니다')
    })
    const attn1 = first.container.querySelector('section[aria-label="주의 필요 대기열"]')!
    const pill1 = attn1.querySelector('.pulse-header-meta .pulse-pill')!
    expect(pill1.getAttribute('data-tone')).toBe('warn')
    expect(pill1.textContent?.trim()).toBe('일부 미확인')
    expect(attn1.textContent).not.toContain('대기 중인 승인·질문·오류 없음')
    expect(attn1.textContent).toContain('비어 있음으로 확정할 수 없습니다')
    expect(requestedUrls.some((u) => u.includes('/api/v1/keepers/tool-approvals'))).toBe(false)
    expect(requestedUrls.some((u) => u.includes('/api/v1/keepers/asks'))).toBe(false)
    first.unmount()

    // 2. One keeper failing while approvals & asks remain unbridged -> count + partial unchecked notice
    resourceCache.clearAll()
    keeperHealth = 'failing'
    const second = render(
      html`<${PulseWorkspace} subroute="" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
    )
    await waitFor(() => {
      const attn = second.container.querySelector('section[aria-label="주의 필요 대기열"]')
      expect(attn?.textContent).toContain('1건 · 일부 미확인')
      expect(attn?.textContent).toContain('provider 429')
      expect(attn?.querySelector('[data-attention-unchecked="true"]')).not.toBeNull()
    })
  })
})
