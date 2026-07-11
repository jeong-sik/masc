import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { html } from 'htm/preact'
import { render } from 'preact'
import * as Vitest from 'vitest'
import type { DashboardGovernanceResponse, KeeperApprovalQueueItem, KeeperApprovalRule, KeeperResolvedApprovalItem } from '../../types'

const { afterEach, beforeEach, describe, expect, it, vi } = Vitest

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

function queueItem(overrides: Partial<KeeperApprovalQueueItem> & { id: string }): KeeperApprovalQueueItem {
  return {
    keeper_name: 'keeper-x',
    tool_name: 'fs_write',
    risk_level: 'critical',
    waiting_s: 92,
    input_preview: 'echo hello > /etc/config',
    task_id: 'T-1',
    ...overrides,
  }
}

function responseWithQueue(
  approval_queue: KeeperApprovalQueueItem[],
  recent_resolved: KeeperResolvedApprovalItem[] = [],
  approval_rules: KeeperApprovalRule[] = [],
  hitl: DashboardGovernanceResponse['hitl'] = {
    enabled: true,
    disabled_by_env: false,
    env_name: 'MASC_DISABLE_HITL',
    default_enabled: true,
  },
): DashboardGovernanceResponse {
  return {
    generated_at: '2026-06-19T00:00:00Z',
    summary: { judge_online: false },
    items: [],
    activity: [],
    judgments: [],
    pending_actions: [],
    approval_queue,
    recent_resolved,
    approval_rules,
    hitl,
  } as DashboardGovernanceResponse
}

// Mirrors governance.test.ts loadComponentWithApi: mock the api seam that
// refreshGovernance() reaches on mount, plus the sse-store refresh registry.
async function loadSurface(
  approval_queue: KeeperApprovalQueueItem[],
  recent_resolved: KeeperResolvedApprovalItem[] = [],
  approval_rules: KeeperApprovalRule[] = [],
  hitl?: DashboardGovernanceResponse['hitl'],
) {
  vi.resetModules()
  const resolveGovernanceApproval = vi
    .fn()
    .mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' })
  const setApprovalMode = vi
    .fn()
    .mockResolvedValue({ ok: true, mode: 'auto_low_risk', previous_mode: 'manual', actor: 'op', changed_at: '2026-06-19T00:00:00Z' })
  const response = hitl
    ? responseWithQueue(approval_queue, recent_resolved, approval_rules, hitl)
    : responseWithQueue(approval_queue, recent_resolved, approval_rules)
  const apiMock = () => ({
    decideGovernanceExecutionOrder: vi.fn().mockResolvedValue(undefined),
    fetchDashboardGovernance: vi.fn().mockResolvedValue(response),
    fetchGovernanceCaseStatus: vi.fn().mockResolvedValue(null),
    resolveGovernanceApproval,
    deleteGovernanceApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
    setApprovalMode,
    submitGovernanceCaseBrief: vi.fn().mockResolvedValue(null),
    submitGovernancePetition: vi.fn().mockResolvedValue({ case: { id: 'x' } }),
  })
  vi.doMock('../../api', apiMock)
  vi.doMock('../../api/dashboard-governance', apiMock)
  vi.doMock('../../sse-store', () => ({ registerGovernanceRefresh: vi.fn() }))
  // Preserve the real router (route signal etc.) but capture navigate() so the
  // "open keeper conversation" wiring can be asserted without a real route change.
  const navigate = vi.fn()
  vi.doMock('../../router', async (importOriginal) => ({
    ...(await importOriginal<typeof import('../../router')>()),
    navigate,
  }))
  const mod = await import('./approvals-surface')
  return { ApprovalsSurface: mod.ApprovalsSurface, resolveGovernanceApproval, setApprovalMode, navigate }
}

describe('ApprovalsSurface', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../../api')
    vi.doUnmock('../../api/dashboard-governance')
    vi.doUnmock('../../sse-store')
  })

  it('renders a card per pending approval bound to the live queue fields', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({ id: 'appr-1', keeper_name: 'masc-improver', tool_name: 'fs_write', risk_level: 'critical' }),
      queueItem({ id: 'appr-2', keeper_name: 'issue-king', tool_name: 'shell', risk_level: 'low', waiting_s: 12 }),
      queueItem({ id: 'appr-3', keeper_name: 'risk-checker', tool_name: 'shell', risk_level: 'high' }),
      queueItem({ id: 'appr-4', keeper_name: 'risk-checker', tool_name: 'shell', risk_level: 'medium' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const surface = container.querySelector('[data-testid="approvals-surface"]')
    expect(surface).not.toBeNull()
    // ap-surface scopes the .ov-scroll overflow override that lets the sticky
    // detail rail work; without the class the CSS rule below never matches.
    expect(surface?.className).toContain('ap-surface')
    const cards = container.querySelectorAll('[data-testid="approval-card"]')
    expect(cards.length).toBe(4)
    expect(container.textContent).toContain('masc-improver')
    expect(container.textContent).toContain('fs_write')
    // risk_level is surfaced as a humanized Korean label on the .ap-kind badge
    // (keeperApprovalRiskLabel — exhaustive over the closed risk-level union).
    expect(container.textContent).toContain('심각')
    expect(container.textContent).toContain('높음')
    expect(container.textContent).toContain('보통')
    expect(container.textContent).toContain('낮음')
    expect(container.querySelector('[data-approval-id="appr-1"]')?.className).toContain('sev-bad')
    expect(container.querySelector('[data-approval-id="appr-3"]')?.className).toContain('sev-warn')
    expect(container.querySelector('[data-approval-id="appr-4"]')?.className).toContain('sev-accent')
    expect(container.querySelector('[data-approval-id="appr-2"]')?.className).toContain('sev-info')
    // the three live decisions are exposed; the prototype's defer/undo are not
    expect(container.textContent).toContain('승인')
    expect(container.textContent).toContain('항상 승인')
    expect(container.textContent).toContain('거부')
    expect(container.textContent).not.toContain('보류')
    expect(container.textContent).not.toContain('되돌리기')
    expect(container.textContent).not.toContain('처리이력')
    // KPI strip counts the queue
    expect(container.querySelector('[data-testid="approvals-queue"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="approvals-aside"]')?.textContent)
      .toContain('HITL 상태')
    expect(container.querySelector('[data-testid="approvals-aside"]')?.textContent)
      .toContain('enabled')
  }, 20000)

  it('formats a multi-hour HITL wait with an hour tier, not a minute-only breakdown', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({ id: 'appr-long', waiting_s: 9000 }), // 2h 30m — previously "150분 0초 대기"
      queueItem({ id: 'appr-short', waiting_s: 92 }), // 1m 32s
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-approval-id="appr-long"] .ap-age')?.textContent)
      .toBe('2시간 30분 대기')
    expect(container.querySelector('[data-approval-id="appr-short"] .ap-age')?.textContent)
      .toBe('1분 대기')
  }, 20000)

  it('renders the HITL context summary (available) inside the pending card', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({
        id: 'appr-summary',
        keeper_name: 'masc-improver',
        summary_status: {
          status: 'available',
          summary: {
            summary_version: 1,
            generated_at_iso: '2026-07-04T00:00:00Z',
            model_run_id: 'run-1',
            context_summary: 'Deletes the production database — irreversible.',
            key_questions: ['Is there a verified backup?'],
            suggested_options: [
              { label: '거부', rationale: '복구 불가', estimated_risk_delta: 'critical' },
            ],
            risk_rationale: 'writes outside the sandbox',
            uncertainty: 0.6,
          },
        },
      }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const summaryEl = container.querySelector('[data-testid="approval-summary"]')
    expect(summaryEl).not.toBeNull()
    expect(summaryEl?.getAttribute('data-summary-state')).toBe('available')
    expect(container.textContent).toContain('Deletes the production database')
    expect(container.textContent).toContain('Is there a verified backup?')
    expect(container.textContent).toContain('복구 불가')
    // uncertainty rendered as a rounded percentage
    expect(container.textContent).toContain('60%')
  }, 20000)

  it('surfaces pending and failed summary states rather than hiding them', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({ id: 'appr-pending', summary_status: { status: 'pending' } }),
      queueItem({
        id: 'appr-failed',
        summary_status: { status: 'failed', reason: 'provider unavailable', retryable: true },
      }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const states = Array.from(
      container.querySelectorAll('[data-testid="approval-summary"]'),
    ).map(el => el.getAttribute('data-summary-state'))
    expect(states).toContain('pending')
    expect(states).toContain('failed')
    expect(container.textContent).toContain('provider unavailable')
  }, 20000)

  it('renders no summary block when the approval has no summary status', async () => {
    const { ApprovalsSurface } = await loadSurface([queueItem({ id: 'appr-nosummary' })])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="approval-card"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="approval-summary"]')).toBeNull()
  }, 20000)

  it('counts only the bad (critical) visual band in the 비가역·위험 KPI, matching the red card rails', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({ id: 'c1', risk_level: 'critical' }),
      queueItem({ id: 'h1', risk_level: 'high' }),
      queueItem({ id: 'm1', risk_level: 'medium' }),
      queueItem({ id: 'l1', risk_level: 'low' }),
      queueItem({ id: 'c2', risk_level: 'critical' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    // Two critical items render the red sev-bad rail; high/medium/low do not.
    const badCards = container.querySelectorAll('.ap-card.sev-bad')
    expect(badCards.length).toBe(2)

    // The KPI must equal that bad-band card count (not high+critical), so the
    // red-styled value never claims irreversible items no card flags red.
    const kpi = container.querySelector('[data-testid="approvals-kpi-irreversible"]')
    expect(kpi).not.toBeNull()
    expect(kpi?.textContent?.trim()).toBe('2')
    expect(kpi?.className).toContain('bad')
  }, 20000)

  it('renders a selected request dossier from backed approval queue fields', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({
        id: 'appr-1',
        keeper_name: 'masc-improver',
        tool_name: 'fs_write',
        action_key: 'write guarded config',
        waiting_s: 125,
        requested_at: '2026-06-19T00:00:00Z',
        turn_id: 7,
        goal_id: 'G-1',
        sandbox_target: 'project-root',
        runtime_contract: {
          sandbox_profile: 'workspace-write',
          network_mode: 'restricted',
          backend: 'eio',
          task_id: 'T-runtime',
          goal_id: 'G-runtime',
          goal_ids: ['G-extra'],
        },
        disposition: 'manual_review',
        disposition_reason: 'requires operator signoff',
        rule_match: { rule_id: 'rule-1', matched_by: 'fingerprint' },
        input_preview: 'first approval preview',
      }),
      queueItem({
        id: 'appr-2',
        keeper_name: 'issue-king',
        tool_name: 'shell',
        risk_level: 'low',
        action_key: 'run read-only check',
        input_preview: 'second approval preview',
        runtime_contract: {
          sandbox_profile: 'read-only',
          network_mode: 'restricted',
          backend: 'local',
        },
      }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const panel = container.querySelector('[data-testid="approval-detail-panel"]')
    expect(panel).not.toBeNull()
    expect(panel?.getAttribute('data-approval-id')).toBe('appr-1')
    expect(panel?.textContent).toContain('write guarded config')
    expect(panel?.textContent).toContain('workspace-write')
    expect(panel?.textContent).toContain('restricted')
    expect(panel?.textContent).toContain('eio')
    expect(panel?.textContent).toContain('goal G-1')
    expect(panel?.textContent).toContain('runtime task T-runtime')
    expect(panel?.textContent).toContain('requires operator signoff')
    expect(panel?.textContent).toContain('rule rule-1')
    expect(panel?.textContent).toContain('first approval preview')
    expect(container.querySelector('[data-approval-id="appr-1"]')?.getAttribute('data-selected')).toBe('true')

    container.querySelector<HTMLButtonElement>('[data-approval-id="appr-2"] .ap-detail-toggle')?.click()
    await flushUi()

    const switchedPanel = container.querySelector('[data-testid="approval-detail-panel"]')
    expect(switchedPanel?.getAttribute('data-approval-id')).toBe('appr-2')
    expect(switchedPanel?.textContent).toContain('run read-only check')
    expect(switchedPanel?.textContent).toContain('read-only')
    expect(switchedPanel?.textContent).toContain('second approval preview')
    expect(switchedPanel?.textContent).not.toContain('first approval preview')
    expect(container.querySelector('[data-approval-id="appr-1"]')?.getAttribute('data-selected')).toBe('false')
    expect(container.querySelector('[data-approval-id="appr-2"]')?.getAttribute('data-selected')).toBe('true')
  }, 20000)

  it('renders the selected request dossier inline after the selected card for mobile layout', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({
        id: 'appr-1',
        keeper_name: 'masc-improver',
        action_key: 'write guarded config',
        input_preview: 'first approval preview',
      }),
      queueItem({
        id: 'appr-2',
        keeper_name: 'issue-king',
        risk_level: 'low',
        action_key: 'run read-only check',
        input_preview: 'second approval preview',
      }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const firstInlinePanel = container.querySelector('[data-testid="approval-detail-panel-inline"]')
    expect(firstInlinePanel).not.toBeNull()
    expect(firstInlinePanel?.getAttribute('data-approval-id')).toBe('appr-1')
    expect(firstInlinePanel?.previousElementSibling?.getAttribute('data-approval-id')).toBe('appr-1')
    expect(firstInlinePanel?.textContent).toContain('first approval preview')
    expect(container.querySelectorAll('[data-testid="approval-detail-panel"]').length).toBe(1)
    expect(container.querySelectorAll('[data-testid="approval-detail-panel-inline"]').length).toBe(1)

    container.querySelector<HTMLButtonElement>('[data-approval-id="appr-2"] .ap-detail-toggle')?.click()
    await flushUi()

    const secondInlinePanel = container.querySelector('[data-testid="approval-detail-panel-inline"]')
    expect(secondInlinePanel?.getAttribute('data-approval-id')).toBe('appr-2')
    expect(secondInlinePanel?.previousElementSibling?.getAttribute('data-approval-id')).toBe('appr-2')
    expect(secondInlinePanel?.textContent).toContain('second approval preview')
    expect(secondInlinePanel?.textContent).not.toContain('first approval preview')
    expect(container.querySelectorAll('[data-testid="approval-detail-panel-inline"]').length).toBe(1)
    expect(container.textContent).not.toContain('보류')
    expect(container.textContent).not.toContain('되돌리기')
    expect(container.textContent).not.toContain('처리이력')
  }, 20000)

  it('keeps prototype-only defer and undo controls out while exposing backed queue/history tabs', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({ id: 'appr-no-fake-controls', keeper_name: 'masc-improver' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('.ap-act.defer')).toBeNull()
    expect(container.querySelector('.ap-viewseg')).not.toBeNull()
    expect(container.textContent).toContain('이력')
    expect(container.textContent).not.toContain('보류')
    expect(container.textContent).not.toContain('되돌리기')
    expect(container.textContent).not.toContain('처리이력')
  }, 20000)

  it('renders resolved approval history with resolved timestamp and closed decision class', async () => {
    const { ApprovalsSurface } = await loadSurface(
      [],
      [
        {
          id: 'appr-done',
          keeper_name: 'masc-improver',
          tool_name: 'fs_write',
          risk_level: 'medium',
          decision: 'reject',
          decision_raw: 'reject:operator denied',
          resolved_at: '2026-06-27T01:02:03Z',
        },
      ],
    )

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    container.querySelector<HTMLButtonElement>('.ap-viewbtn:not(.on)')?.click()
    await flushUi()

    const history = container.querySelector('[data-testid="approvals-history-view"]')
    expect(history).not.toBeNull()
    expect(history?.querySelector('.ap-hist-summary')?.getAttribute('aria-label')).toBe('승인 이력 요약')
    expect(history?.textContent).toContain('거부')
    expect(history?.textContent).toContain('fs_write')
    expect(history?.textContent).toContain('masc-improver')
    expect(history?.textContent).toContain('appr-done')
    expect(history?.querySelector('.ap-history-decision')?.className).toContain('decision-reject')
    expect(history?.querySelector('.ap-history-decision')?.className).not.toContain('operator denied')
    expect(history?.querySelector('.ap-history-at')?.textContent).toContain('2026')
  }, 20000)

  it('filters resolved approval history and surfaces Always-rule evidence', async () => {
    const { ApprovalsSurface } = await loadSurface(
      [],
      [
        {
          id: 'appr-approved',
          keeper_name: 'keeper-a',
          tool_name: 'fs_write',
          risk_level: 'medium',
          decision: 'approve',
          resolved_at: '2026-06-27T02:02:03Z',
          rule_match: { rule_id: 'rule-1', matched_by: 'fingerprint' },
        },
        {
          id: 'appr-rejected',
          keeper_name: 'keeper-b',
          tool_name: 'shell',
          risk_level: 'critical',
          decision: 'reject',
          resolved_at: '2026-06-27T01:02:03Z',
        },
      ],
      [
        {
          id: 'rule-1',
          keeper_name: 'keeper-a',
          tool_name: 'fs_write',
          max_risk: 'medium',
          match_count: 3,
        },
      ],
    )

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const aside = container.querySelector('[data-testid="approvals-aside"]')
    expect(aside?.textContent).toContain('Always Rules')
    expect(aside?.textContent).toContain('keeper-a')
    expect(aside?.textContent).toContain('fs_write')
    expect(aside?.textContent).toContain('match 3')

    container.querySelector<HTMLButtonElement>('.ap-viewbtn:not(.on)')?.click()
    await flushUi()

    expect(container.querySelector('[data-testid="approvals-history-view"]')?.textContent)
      .toContain('rule rule-1')

    const rejectFilter = Array.from(container.querySelectorAll<HTMLButtonElement>('.ap-hist-f'))
      .find(button => button.textContent === '거부')
    rejectFilter?.click()
    await flushUi()

    const history = container.querySelector('[data-testid="approvals-history-view"]')
    expect(history?.textContent).toContain('appr-rejected')
    expect(history?.textContent).not.toContain('appr-approved')
  }, 20000)

  it('makes hidden Always rules explicit when the aside list overflows its cap', async () => {
    const rules = Array.from({ length: 8 }, (_, i) => ({
      id: `rule-${i}`,
      keeper_name: 'keeper-a',
      tool_name: 'fs_write',
      max_risk: 'medium',
      match_count: 1,
    })) as KeeperApprovalRule[]
    const { ApprovalsSurface } = await loadSurface([], [], rules)

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    // Only the first 6 rows render, and the remaining 2 are surfaced explicitly
    // rather than silently dropped (Always rules have no other view).
    expect(container.querySelectorAll('[data-testid="approval-rule-row"]').length).toBe(6)
    expect(container.querySelector('[data-testid="approvals-rules-overflow"]')?.textContent)
      .toContain('외 2건')
  }, 20000)

  it('omits the rules overflow note when the list fits the cap', async () => {
    const rules = Array.from({ length: 6 }, (_, i) => ({
      id: `rule-${i}`,
      keeper_name: 'k',
      tool_name: 't',
      max_risk: 'low',
      match_count: 1,
    })) as KeeperApprovalRule[]
    const { ApprovalsSurface } = await loadSurface([], [], rules)

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="approvals-rules-overflow"]')).toBeNull()
  }, 20000)

  it('shows the empty state when no approvals are pending', async () => {
    const { ApprovalsSurface } = await loadSurface([])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="approvals-empty"]')).not.toBeNull()
    expect(container.textContent).toContain('열린 승인이 없습니다')
    expect(container.querySelector('[data-testid="approvals-queue"]')).toBeNull()
  })

  it('shows a loading state on first load, not the empty state, before data arrives', async () => {
    // governanceResource is stale-while-revalidate, so governanceData is null
    // ONLY before the first fetch resolves. Hold the fetch pending and assert the
    // surface shows the loading state — not "열린 승인이 없습니다", which would
    // assert an empty queue we have not actually loaded yet.
    vi.resetModules()
    let resolveFetch: (value: DashboardGovernanceResponse) => void = () => {}
    const fetchDashboardGovernance = vi.fn(
      () => new Promise<DashboardGovernanceResponse>(resolve => { resolveFetch = resolve }),
    )
    vi.doMock('../../api', () => ({
      decideGovernanceExecutionOrder: vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance,
      fetchGovernanceCaseStatus: vi.fn().mockResolvedValue(null),
      resolveGovernanceApproval: vi.fn().mockResolvedValue({ ok: true }),
      deleteGovernanceApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
      submitGovernanceCaseBrief: vi.fn().mockResolvedValue(null),
      submitGovernancePetition: vi.fn().mockResolvedValue({ case: { id: 'x' } }),
    }))
    vi.doMock('../../api/dashboard-governance', () => ({
      decideGovernanceExecutionOrder: vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance,
      fetchGovernanceCaseStatus: vi.fn().mockResolvedValue(null),
      resolveGovernanceApproval: vi.fn().mockResolvedValue({ ok: true }),
      deleteGovernanceApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
      submitGovernanceCaseBrief: vi.fn().mockResolvedValue(null),
      submitGovernancePetition: vi.fn().mockResolvedValue({ case: { id: 'x' } }),
    }))
    vi.doMock('../../sse-store', () => ({ registerGovernanceRefresh: vi.fn() }))
    const { ApprovalsSurface } = await import('./approvals-surface')

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    // fetch still pending → first load → loading state, NOT empty state
    expect(container.querySelector('.loading-state')).not.toBeNull()
    expect(container.textContent).toContain('승인 큐 불러오는 중')
    expect(container.querySelector('[data-testid="approvals-empty"]')).toBeNull()
    expect(container.querySelector('[data-testid="approvals-kpi-irreversible"]')).toBeNull()

    // resolve so the surface transitions out of loading (and no pending promise leaks)
    resolveFetch(responseWithQueue([]))
    await flushUi()
    expect(container.querySelector('.loading-state')).toBeNull()
    expect(container.querySelector('[data-testid="approvals-empty"]')).not.toBeNull()
  })

  it('shows the error banner without the all-clear empty state when the first fetch fails', async () => {
    // On a failed first fetch the managed resource sets loading=false with null
    // data, so items=[] and governanceError is set. The "✓ 큐가 비어 있습니다 —
    // keeper들이 진행 중" panel is a success claim and must NOT render under the
    // error banner (it would contradict the failure).
    vi.resetModules()
    const fetchDashboardGovernance = vi.fn().mockRejectedValue(new Error('승인 큐 로드 실패'))
    vi.doMock('../../api', () => ({
      decideGovernanceExecutionOrder: vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance,
      fetchGovernanceCaseStatus: vi.fn().mockResolvedValue(null),
      resolveGovernanceApproval: vi.fn().mockResolvedValue({ ok: true }),
      deleteGovernanceApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
      submitGovernanceCaseBrief: vi.fn().mockResolvedValue(null),
      submitGovernancePetition: vi.fn().mockResolvedValue({ case: { id: 'x' } }),
    }))
    vi.doMock('../../api/dashboard-governance', () => ({
      decideGovernanceExecutionOrder: vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance,
      fetchGovernanceCaseStatus: vi.fn().mockResolvedValue(null),
      resolveGovernanceApproval: vi.fn().mockResolvedValue({ ok: true }),
      deleteGovernanceApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
      submitGovernanceCaseBrief: vi.fn().mockResolvedValue(null),
      submitGovernancePetition: vi.fn().mockResolvedValue({ case: { id: 'x' } }),
    }))
    vi.doMock('../../sse-store', () => ({ registerGovernanceRefresh: vi.fn() }))
    const { ApprovalsSurface } = await import('./approvals-surface')

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const errorBanner = container.querySelector('[data-testid="approvals-error"]')
    expect(errorBanner).not.toBeNull()
    expect(errorBanner?.textContent).toContain('승인 큐 로드 실패')
    expect(container.querySelector('[data-testid="approvals-empty"]')).toBeNull()
    // the error must be announced to assistive tech — a HITL decision failure that
    // a screen reader never reads out is a silent failure for AT users.
    expect(errorBanner?.getAttribute('role')).toBe('alert')
  })

  it('labels the surface with the shared data-screen-label convention', async () => {
    // Every v2 surface (fusion/schedule/settings/connector/copilot) tags its
    // <main> with data-screen-label; the prototype names this screen 승인 큐.
    // Asserting it keeps the approvals surface consistent with that convention.
    const { ApprovalsSurface } = await loadSurface([])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const main = container.querySelector('[data-testid="approvals-surface"]')
    expect(main?.getAttribute('data-screen-label')).toBe('승인 큐')
  })

  it('routes the 승인 action through respondToKeeperApproval → resolveGovernanceApproval', async () => {
    const { ApprovalsSurface, resolveGovernanceApproval } = await loadSurface([
      queueItem({ id: 'appr-9', keeper_name: 'masc-improver' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const approveBtn = container.querySelector<HTMLButtonElement>('.ap-card .ap-act.approve')
    expect(approveBtn).not.toBeNull()
    approveBtn?.click()
    await flushUi()

    expect(resolveGovernanceApproval).toHaveBeenCalledWith('appr-9', 'approve', false)
  })

  it('routes the 거부 action through resolveGovernanceApproval with the reject decision', async () => {
    const { ApprovalsSurface, resolveGovernanceApproval } = await loadSurface([
      queueItem({ id: 'appr-r', keeper_name: 'masc-improver' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    container.querySelector<HTMLButtonElement>('.ap-card .ap-act.deny')?.click()
    await flushUi()

    expect(resolveGovernanceApproval).toHaveBeenCalledWith('appr-r', 'reject', false)
  })

  it('routes the 항상 승인 action through resolveGovernanceApproval with rememberRule=true', async () => {
    const { ApprovalsSurface, resolveGovernanceApproval } = await loadSurface([
      queueItem({ id: 'appr-a', keeper_name: 'masc-improver' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    container.querySelector<HTMLButtonElement>('.ap-card .ap-act.always')?.click()
    await flushUi()

    expect(resolveGovernanceApproval).toHaveBeenCalledWith('appr-a', 'approve', true)
  })

  it('binds the RFC-0319 approval-mode toggle to hitl.approval_mode (auto_low_risk → on)', async () => {
    const { ApprovalsSurface } = await loadSurface([], [], [], {
      enabled: true,
      disabled_by_env: false,
      env_name: 'MASC_DISABLE_HITL',
      default_enabled: true,
      approval_mode: { mode: 'auto_low_risk', auto_eligible_bands: ['low'], fail_closed: false },
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const toggle = container.querySelector<HTMLButtonElement>('[data-testid="approval-mode-toggle"]')
    expect(toggle).not.toBeNull()
    // A real toggle switch, not the former display-only aria-hidden span.
    expect(toggle?.getAttribute('role')).toBe('switch')
    expect(toggle?.getAttribute('aria-checked')).toBe('true')
    expect(toggle?.className).toContain('on')
    const aside = container.querySelector('[data-testid="approvals-aside"]')
    expect(aside?.textContent).toContain('자동 승인 (low-risk)')
    // the enforced separation-of-duties floor is stated, not decorative
    expect(aside?.textContent).toContain('비가역·파괴적·high-risk 요청은 항상 수동 결재')
    expect(aside?.textContent).toContain('자동 승인 대상: low')
  }, 20000)

  it('defaults the approval-mode toggle to off when hitl.approval_mode is manual', async () => {
    const { ApprovalsSurface } = await loadSurface([], [], [], {
      enabled: true,
      disabled_by_env: false,
      env_name: 'MASC_DISABLE_HITL',
      default_enabled: true,
      approval_mode: { mode: 'manual', auto_eligible_bands: ['low'], fail_closed: false },
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const toggle = container.querySelector<HTMLButtonElement>('[data-testid="approval-mode-toggle"]')
    expect(toggle?.getAttribute('aria-checked')).toBe('false')
    expect(toggle?.className).not.toContain('on')
    expect(container.querySelector('[data-testid="approvals-aside"]')?.textContent).toContain('수동 결재')
  }, 20000)

  it('routes the approval-mode toggle through setApprovalMode (manual → auto_low_risk)', async () => {
    const { ApprovalsSurface, setApprovalMode } = await loadSurface([], [], [], {
      enabled: true,
      disabled_by_env: false,
      env_name: 'MASC_DISABLE_HITL',
      default_enabled: true,
      approval_mode: { mode: 'manual', auto_eligible_bands: ['low'], fail_closed: false },
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const toggle = container.querySelector<HTMLButtonElement>('[data-testid="approval-mode-toggle"]')
    expect(toggle?.disabled).toBe(false)
    toggle?.click()
    await flushUi()

    expect(setApprovalMode).toHaveBeenCalledWith('auto_low_risk')
  }, 20000)

  it('disables the approval-mode toggle when HITL is disabled by env (nothing gates)', async () => {
    const { ApprovalsSurface, setApprovalMode } = await loadSurface([], [], [], {
      enabled: false,
      disabled_by_env: true,
      env_name: 'MASC_DISABLE_HITL',
      default_enabled: true,
      approval_mode: { mode: 'manual', auto_eligible_bands: ['low'], fail_closed: false },
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const toggle = container.querySelector<HTMLButtonElement>('[data-testid="approval-mode-toggle"]')
    expect(toggle?.disabled).toBe(true)
    toggle?.click()
    await flushUi()

    expect(setApprovalMode).not.toHaveBeenCalled()
  }, 20000)

  it('surfaces a visible error and re-enables the actions when a decision fails (no silent failure)', async () => {
    const { ApprovalsSurface, resolveGovernanceApproval } = await loadSurface([
      queueItem({ id: 'appr-e', keeper_name: 'masc-improver' }),
    ])
    // The next decision call rejects: the operator must SEE the failure, because a
    // silently-failed reject would let the keeper proceed while the queue clears.
    resolveGovernanceApproval.mockRejectedValueOnce(new Error('승인 서버 연결 실패'))

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    container.querySelector<HTMLButtonElement>('.ap-card .ap-act.deny')?.click()
    await flushUi()

    // visible error banner with the failure message
    const errorBanner = container.querySelector('[data-testid="approvals-error"]')
    expect(errorBanner).not.toBeNull()
    expect(errorBanner?.textContent).toContain('승인 서버 연결 실패')
    // actions are re-enabled (finally cleared the busy state) so the operator can retry
    const denyBtn = container.querySelector<HTMLButtonElement>('.ap-card .ap-act.deny')
    expect(denyBtn?.disabled).toBe(false)
  })

  it('opens the keeper conversation from 대화에서 검토', async () => {
    const { ApprovalsSurface, navigate } = await loadSurface([
      queueItem({ id: 'appr-k', keeper_name: 'masc-improver' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const reviewBtn = container.querySelector<HTMLButtonElement>('.ap-card .ap-act.ghost')
    expect(reviewBtn?.textContent).toContain('대화에서 검토')
    reviewBtn?.click()
    await flushUi()

    // routes to the keeper's detail page (which defaults to the conversation view)
    expect(navigate).toHaveBeenCalledWith('monitoring', {
      section: 'agents',
      view: 'keepers',
      keeper: 'masc-improver',
    })
  })

  it('renders sandbox metadata as a non-interactive span, not a clickable goal link', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({ id: 'appr-sb', keeper_name: 'masc-improver', sandbox_target: 'project-root', task_id: 'T-1' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const card = container.querySelector('[data-approval-id="appr-sb"]')
    // sandbox text is a static .ap-req-meta span (no click affordance)
    const meta = card?.querySelector('.ap-req-meta')
    expect(meta).not.toBeNull()
    expect(meta?.tagName).toBe('SPAN')
    expect(meta?.textContent).toContain('sandbox')
    expect(meta?.textContent).toContain('project-root')
    // the clickable .ap-req-goal is the task/goal button only — never the sandbox
    const goalEls = Array.from(card?.querySelectorAll('.ap-req-goal') ?? [])
    expect(goalEls.length).toBeGreaterThan(0)
    for (const el of goalEls) {
      expect(el.tagName).toBe('BUTTON')
      expect(el.textContent).not.toContain('sandbox')
    }
  })

  it('keeps the sticky detail rail working by un-clipping the approvals .ov-scroll', () => {
    // The rail is position: sticky, but the shared .ov-scroll wrapper's
    // overflow formed a non-scrolling sticky containing block. approvals-v2.css
    // must restore overflow:visible on the approvals-scoped wrapper only.
    const css = readFileSync(resolve(__dirname, '../../styles/approvals-v2.css'), 'utf8')
    expect(css).toMatch(/\.ap-surface\s*>\s*\.ov-scroll\s*\{[^}]*overflow:\s*visible/)
    const railRule = css.match(/\.ap-detail-panel\s*\{([^}]*)\}/)?.[1] ?? ''
    expect(railRule).toContain('position: sticky')
  })

  it('collapses the approvals shell to one column on narrow viewports', () => {
    const css = readFileSync(resolve(__dirname, '../../styles/approvals-v2.css'), 'utf8')
    expect(css).toMatch(/@media \(max-width: 980px\)[\s\S]*?\.ap-surface\s*\{\s*flex-direction:\s*column;/)
    expect(css).toMatch(/\.ap-surface\s*>\s*\.ov-scroll\s*\{[^}]*width:\s*100%/)
  })
})
