import { html } from 'htm/preact'
import { render } from 'preact'
import * as Vitest from 'vitest'
import type { DashboardGovernanceResponse, KeeperApprovalQueueItem } from '../../types'

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

function responseWithQueue(approval_queue: KeeperApprovalQueueItem[]): DashboardGovernanceResponse {
  return {
    generated_at: '2026-06-19T00:00:00Z',
    summary: { judge_online: false },
    items: [],
    activity: [],
    judgments: [],
    pending_actions: [],
    approval_queue,
  } as DashboardGovernanceResponse
}

// Mirrors governance.test.ts loadComponentWithApi: mock the api seam that
// refreshGovernance() reaches on mount, plus the sse-store refresh registry.
async function loadSurface(approval_queue: KeeperApprovalQueueItem[]) {
  vi.resetModules()
  const resolveGovernanceApproval = vi
    .fn()
    .mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' })
  vi.doMock('../../api', () => ({
    decideGovernanceExecutionOrder: vi.fn().mockResolvedValue(undefined),
    fetchDashboardGovernance: vi.fn().mockResolvedValue(responseWithQueue(approval_queue)),
    fetchGovernanceCaseStatus: vi.fn().mockResolvedValue(null),
    resolveGovernanceApproval,
    deleteGovernanceApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
    submitGovernanceCaseBrief: vi.fn().mockResolvedValue(null),
    submitGovernancePetition: vi.fn().mockResolvedValue({ case: { id: 'x' } }),
  }))
  vi.doMock('../../sse-store', () => ({ registerGovernanceRefresh: vi.fn() }))
  const mod = await import('./approvals-surface')
  return { ApprovalsSurface: mod.ApprovalsSurface, resolveGovernanceApproval }
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

    expect(container.querySelector('[data-testid="approvals-surface"]')).not.toBeNull()
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

  it('keeps prototype-only defer, undo, and history controls out of the live surface', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({ id: 'appr-no-fake-controls', keeper_name: 'masc-improver' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('.ap-act.defer')).toBeNull()
    expect(container.querySelector('.ap-history')).toBeNull()
    expect(container.textContent).not.toContain('보류')
    expect(container.textContent).not.toContain('되돌리기')
    expect(container.textContent).not.toContain('처리이력')
  }, 20000)

  it('shows the empty state when no approvals are pending', async () => {
    const { ApprovalsSurface } = await loadSurface([])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="approvals-empty"]')).not.toBeNull()
    expect(container.textContent).toContain('열린 승인이 없습니다')
    expect(container.querySelector('[data-testid="approvals-queue"]')).toBeNull()
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
})
