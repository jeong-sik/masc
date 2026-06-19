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
    // risk_level is surfaced uppercased on the .ap-kind badge
    expect(container.textContent).toContain('CRITICAL')
    expect(container.textContent).toContain('HIGH')
    expect(container.textContent).toContain('MEDIUM')
    expect(container.textContent).toContain('LOW')
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
    // KPI strip counts the queue
    expect(container.querySelector('[data-testid="approvals-queue"]')).not.toBeNull()
  }, 20000)

  it('shows the empty state when no approvals are pending', async () => {
    const { ApprovalsSurface } = await loadSurface([])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="approvals-empty"]')).not.toBeNull()
    expect(container.textContent).toContain('열린 승인이 없습니다')
    expect(container.querySelector('[data-testid="approvals-queue"]')).toBeNull()
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
