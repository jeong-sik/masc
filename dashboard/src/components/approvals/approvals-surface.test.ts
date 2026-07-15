import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { html } from 'htm/preact'
import { render } from 'preact'
import * as Vitest from 'vitest'
import type { DashboardGateResponse, KeeperApprovalQueueItem, KeeperResolvedApprovalItem } from '../../types'

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
    waiting_s: 92,
    input_preview: '{"path":"config.json","content":"hello"}',
    task_id: 'T-1',
    ...overrides,
  }
}

function responseWithQueue(
  approval_queue: KeeperApprovalQueueItem[],
  recent_resolved: KeeperResolvedApprovalItem[] = [],
  hitl: DashboardGateResponse['hitl'] = {
    gate_mode: { mode: 'manual', configured: true, state: 'ready' },
  },
): DashboardGateResponse {
  return {
    generated_at: '2026-06-19T00:00:00Z',
    approval_queue,
    recent_resolved,
    hitl,
  } as DashboardGateResponse
}

// Mock the API seam refreshGate() reaches on mount, plus the SSE refresh
// registry.
async function loadSurface(
  approval_queue: KeeperApprovalQueueItem[],
  recent_resolved: KeeperResolvedApprovalItem[] = [],
  hitl?: DashboardGateResponse['hitl'],
) {
  vi.resetModules()
  const resolveGateApproval = vi
    .fn()
    .mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' })
  const setGateMode = vi
    .fn()
    .mockResolvedValue({ ok: true, mode: 'auto_judge', previous_mode: 'manual', actor: 'op', changed_at: '2026-06-19T00:00:00Z' })
  const response = hitl
    ? responseWithQueue(approval_queue, recent_resolved, hitl)
    : responseWithQueue(approval_queue, recent_resolved)
  const apiMock = () => ({
    fetchDashboardGate: vi.fn().mockResolvedValue(response),
    resolveGateApproval,
    setGateMode,
  })
  vi.doMock('../../api', apiMock)
  vi.doMock('../../api/dashboard-gate', apiMock)
  vi.doMock('../../sse-store', () => ({ registerGateRefresh: vi.fn() }))
  // Preserve the real router (route signal etc.) but capture navigate() so the
  // "open keeper conversation" wiring can be asserted without a real route change.
  const navigate = vi.fn()
  vi.doMock('../../router', async (importOriginal) => ({
    ...(await importOriginal<typeof import('../../router')>()),
    navigate,
  }))
  const mod = await import('./approvals-surface')
  return { ApprovalsSurface: mod.ApprovalsSurface, resolveGateApproval, setGateMode, navigate }
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
    vi.doUnmock('../../api/dashboard-gate')
    vi.doUnmock('../../sse-store')
  })

  it('renders a card per pending approval bound to the live queue fields', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({ id: 'appr-1', keeper_name: 'masc-improver', tool_name: 'filesystem_write' }),
      queueItem({ id: 'appr-2', keeper_name: 'issue-king', tool_name: 'execute', waiting_s: 12 }),
      queueItem({ id: 'appr-3', keeper_name: 'reviewer', tool_name: 'connector_post' }),
      queueItem({ id: 'appr-4', keeper_name: 'reviewer', tool_name: 'image_generate' }),
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
    expect(container.textContent).toContain('filesystem_write')
    expect(container.textContent).toContain('Human HITL')
    expect(container.textContent).toContain('nonblocking')
    expect(container.querySelector('[data-approval-id="appr-1"]')?.className).toContain('sev-info')
    expect(container.querySelector('[data-approval-id="appr-3"]')?.className).toContain('sev-info')
    expect(container.querySelector('[data-approval-id="appr-4"]')?.className).toContain('sev-info')
    expect(container.querySelector('[data-approval-id="appr-2"]')?.className).toContain('sev-info')
    // the two live decisions are exposed; the prototype's defer/undo are not
    expect(container.textContent).toContain('승인')
    expect(container.textContent).toContain('거부')
    expect(container.textContent).not.toContain('보류')
    expect(container.textContent).not.toContain('되돌리기')
    expect(container.textContent).not.toContain('처리이력')
    // KPI strip counts the queue
    expect(container.querySelector('[data-testid="approvals-queue"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="approvals-aside"]')?.textContent)
      .toContain('Gate 모드')
    expect(container.querySelector('[data-testid="approvals-aside"]')?.textContent)
      .toContain('Human')
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
            generated_at: '2026-07-04T00:00:00Z',
            model_run_id: 'run-1',
            context_summary: 'The request needs workspace context.',
            key_questions: ['Is there a verified backup?'],
            judgment: 'require_human',
            rationale: 'A Human should confirm the intended target.',
          },
        },
      }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const summaryEl = container.querySelector('[data-testid="approval-summary"]')
    expect(summaryEl).not.toBeNull()
    expect(summaryEl?.getAttribute('data-summary-state')).toBe('available')
    expect(container.textContent).toContain('The request needs workspace context')
    expect(container.textContent).toContain('Is there a verified backup?')
    expect(container.textContent).toContain('A Human should confirm the intended target.')
    expect(container.textContent).toContain('Human 판단 필요')
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

  it('reports the observed Keeper count without classifying the queue', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({ id: 'a1', keeper_name: 'keeper-a' }),
      queueItem({ id: 'a2', keeper_name: 'keeper-a' }),
      queueItem({ id: 'b1', keeper_name: 'keeper-b' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const kpi = container.querySelector('[data-testid="gate-kpi-keepers"]')
    expect(kpi).not.toBeNull()
    expect(kpi?.textContent?.trim()).toBe('2')
  }, 20000)

  it('renders a selected request dossier from backed approval queue fields', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({
        id: 'appr-1',
        keeper_name: 'masc-improver',
        tool_name: 'fs_write',
        waiting_s: 125,
        requested_at: '2026-06-19T00:00:00Z',
        turn_id: 7,

        input_preview: 'first approval preview',
        input: { path: 'config.json', content: 'first' },
      }),
      queueItem({
        id: 'appr-2',
        keeper_name: 'issue-king',
        tool_name: 'shell',
        input_preview: 'second approval preview',
        input: { argv: ['status'] },
      }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const panel = container.querySelector('[data-testid="approval-detail-panel"]')
    expect(panel).not.toBeNull()
    expect(panel?.getAttribute('data-approval-id')).toBe('appr-1')
    expect(panel?.textContent).toContain('fs_write Gate 요청')
    expect(panel?.textContent).toContain('Keeper lane nonblocking')
    expect(panel?.textContent).toContain('task T-1')
    expect(panel?.textContent).toContain('first approval preview')
    expect(container.querySelector('[data-approval-id="appr-1"]')?.getAttribute('data-selected')).toBe('true')

    container.querySelector<HTMLButtonElement>('[data-approval-id="appr-2"] .ap-detail-toggle')?.click()
    await flushUi()

    const switchedPanel = container.querySelector('[data-testid="approval-detail-panel"]')
    expect(switchedPanel?.getAttribute('data-approval-id')).toBe('appr-2')
    expect(switchedPanel?.textContent).toContain('shell Gate 요청')
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
        input_preview: 'first approval preview',
      }),
      queueItem({
        id: 'appr-2',
        keeper_name: 'issue-king',
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
          decision: 'reject',
          decision_source: 'human_operator',
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
    expect(history?.textContent).toContain('Human')
    expect(history?.textContent).toContain('appr-done')
    expect(history?.querySelector('.ap-history-decision')?.className).toContain('decision-reject')
    expect(history?.querySelector('.ap-history-decision')?.className).not.toContain('operator denied')
    expect(history?.querySelector('.ap-history-at')?.textContent).toContain('2026')
  }, 20000)

  it('filters resolved approval history by decision', async () => {
    const { ApprovalsSurface } = await loadSurface(
      [],
      [
        {
          id: 'appr-approved',
          keeper_name: 'keeper-a',
          tool_name: 'fs_write',
          decision: 'approve',
          decision_source: 'always_allowed',
          resolved_at: '2026-06-27T02:02:03Z',
        },
        {
          id: 'appr-rejected',
          keeper_name: 'keeper-b',
          tool_name: 'shell',
          decision: 'reject',
          decision_source: 'auto_judge',
          resolved_at: '2026-06-27T01:02:03Z',
        },
      ],
    )

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    container.querySelector<HTMLButtonElement>('.ap-viewbtn:not(.on)')?.click()
    await flushUi()

    const rejectFilter = Array.from(container.querySelectorAll<HTMLButtonElement>('.ap-hist-f'))
      .find(button => button.textContent === '거부')
    rejectFilter?.click()
    await flushUi()

    const history = container.querySelector('[data-testid="approvals-history-view"]')
    expect(history?.textContent).toContain('appr-rejected')
    expect(history?.textContent).not.toContain('appr-approved')
  }, 20000)

  it('shows the empty state when no approvals are pending', async () => {
    const { ApprovalsSurface } = await loadSurface([])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="approvals-empty"]')).not.toBeNull()
    expect(container.textContent).toContain('열린 Human 판단이 없습니다')
    expect(container.querySelector('[data-testid="approvals-queue"]')).toBeNull()
  })

  it('shows a loading state on first load, not the empty state, before data arrives', async () => {
    // gateResource is stale-while-revalidate, so gateData is null
    // ONLY before the first fetch resolves. Hold the fetch pending and assert the
    // surface shows the loading state, not an unverified empty-state claim.
    // assert an empty queue we have not actually loaded yet.
    vi.resetModules()
    let resolveFetch: (value: DashboardGateResponse) => void = () => {}
    const fetchDashboardGate = vi.fn(
      () => new Promise<DashboardGateResponse>(resolve => { resolveFetch = resolve }),
    )
    vi.doMock('../../api', () => ({
      fetchDashboardGate,
      resolveGateApproval: vi.fn().mockResolvedValue({ ok: true }),
      setGateMode: vi.fn().mockResolvedValue({ ok: true }),
    }))
    vi.doMock('../../api/dashboard-gate', () => ({
      fetchDashboardGate,
      resolveGateApproval: vi.fn().mockResolvedValue({ ok: true }),
      setGateMode: vi.fn().mockResolvedValue({ ok: true }),
    }))
    vi.doMock('../../sse-store', () => ({ registerGateRefresh: vi.fn() }))
    const { ApprovalsSurface } = await import('./approvals-surface')

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    // fetch still pending → first load → loading state, NOT empty state
    expect(container.querySelector('.loading-state')).not.toBeNull()
    expect(container.textContent).toContain('Gate 큐 불러오는 중')
    expect(container.querySelector('[data-testid="approvals-empty"]')).toBeNull()
    expect(container.querySelector('[data-testid="gate-kpi-keepers"]')).toBeNull()

    // resolve so the surface transitions out of loading (and no pending promise leaks)
    resolveFetch(responseWithQueue([]))
    await flushUi()
    expect(container.querySelector('.loading-state')).toBeNull()
    expect(container.querySelector('[data-testid="approvals-empty"]')).not.toBeNull()
  })

  it('shows the error banner without the all-clear empty state when the first fetch fails', async () => {
    // On a failed first fetch the managed resource sets loading=false with null
    // data, so items=[] and gateError is set. The "✓ 큐가 비어 있습니다 —
    // keeper들이 진행 중" panel is a success claim and must NOT render under the
    // error banner (it would contradict the failure).
    vi.resetModules()
    const fetchDashboardGate = vi.fn().mockRejectedValue(new Error('승인 큐 로드 실패'))
    vi.doMock('../../api', () => ({
      fetchDashboardGate,
      resolveGateApproval: vi.fn().mockResolvedValue({ ok: true }),
      setGateMode: vi.fn().mockResolvedValue({ ok: true }),
    }))
    vi.doMock('../../api/dashboard-gate', () => ({
      fetchDashboardGate,
      resolveGateApproval: vi.fn().mockResolvedValue({ ok: true }),
      setGateMode: vi.fn().mockResolvedValue({ ok: true }),
    }))
    vi.doMock('../../sse-store', () => ({ registerGateRefresh: vi.fn() }))
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
    // <main> with data-screen-label.
    // Asserting it keeps the approvals surface consistent with that convention.
    const { ApprovalsSurface } = await loadSurface([])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const main = container.querySelector('[data-testid="approvals-surface"]')
    expect(main?.getAttribute('data-screen-label')).toBe('Gate HITL 큐')
  })

  it('routes the 승인 action through respondToKeeperApproval → resolveGateApproval', async () => {
    const { ApprovalsSurface, resolveGateApproval } = await loadSurface([
      queueItem({ id: 'appr-9', keeper_name: 'masc-improver' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const approveBtn = container.querySelector<HTMLButtonElement>('.ap-card .ap-act.approve')
    expect(approveBtn).not.toBeNull()
    approveBtn?.click()
    await flushUi()

    expect(resolveGateApproval).toHaveBeenCalledWith('appr-9', 'approve')
  })

  it('routes the 거부 action through resolveGateApproval with the reject decision', async () => {
    const { ApprovalsSurface, resolveGateApproval } = await loadSurface([
      queueItem({ id: 'appr-r', keeper_name: 'masc-improver' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    container.querySelector<HTMLButtonElement>('.ap-card .ap-act.deny')?.click()
    await flushUi()

    expect(resolveGateApproval).toHaveBeenCalledWith('appr-r', 'reject')
  })

  it('binds the three non-hierarchical choices to hitl.gate_mode', async () => {
    const { ApprovalsSurface } = await loadSurface([], [], {
      gate_mode: { mode: 'auto_judge', configured: true, state: 'ready' },
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const selector = container.querySelector('[data-testid="gate-mode-selector"]')
    expect(selector?.getAttribute('role')).toBe('radiogroup')
    const choices = Array.from(selector?.querySelectorAll<HTMLButtonElement>('[role="radio"]') ?? [])
    expect(choices.map(choice => choice.textContent)).toEqual(['Human', 'Auto Judge', 'Always Allow'])
    expect(choices.find(choice => choice.textContent === 'Auto Judge')?.getAttribute('aria-checked')).toBe('true')
    const aside = container.querySelector('[data-testid="approvals-aside"]')
    expect(aside?.textContent).toContain('Auto Judge')
    expect(aside?.textContent).toContain('workspace의 명시적 선택')
  }, 20000)

  it('shows Human as the selected Gate mode when configured', async () => {
    const { ApprovalsSurface } = await loadSurface([], [], {
      gate_mode: { mode: 'manual', configured: true, state: 'ready' },
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const human = Array.from(container.querySelectorAll<HTMLButtonElement>('[data-testid="gate-mode-selector"] [role="radio"]'))
      .find(choice => choice.textContent === 'Human')
    expect(human?.getAttribute('aria-checked')).toBe('true')
  }, 20000)

  it('routes a Gate mode choice through setGateMode', async () => {
    const { ApprovalsSurface, setGateMode } = await loadSurface([], [], {
      gate_mode: { mode: 'manual', configured: true, state: 'ready' },
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const autoJudge = Array.from(container.querySelectorAll<HTMLButtonElement>('[data-testid="gate-mode-selector"] [role="radio"]'))
      .find(choice => choice.textContent === 'Auto Judge')
    expect(autoJudge?.disabled).toBe(false)
    autoJudge?.click()
    await flushUi()

    expect(setGateMode).toHaveBeenCalledWith('auto_judge')
  }, 20000)

  it('surfaces a visible error and re-enables the actions when a decision fails (no silent failure)', async () => {
    const { ApprovalsSurface, resolveGateApproval } = await loadSurface([
      queueItem({ id: 'appr-e', keeper_name: 'masc-improver' }),
    ])
    // The next decision call rejects: the operator must SEE the failure, because a
    // silently-failed reject would let the keeper proceed while the queue clears.
    resolveGateApproval.mockRejectedValueOnce(new Error('승인 서버 연결 실패'))

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

  it('renders nonblocking state separately from the clickable task link', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({ id: 'appr-sb', keeper_name: 'masc-improver', task_id: 'T-1' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const card = container.querySelector('[data-approval-id="appr-sb"]')
    const meta = card?.querySelector('.ap-req-meta')
    expect(meta).not.toBeNull()
    expect(meta?.tagName).toBe('SPAN')
    expect(meta?.textContent).toContain('nonblocking')
    const taskLinks = Array.from(card?.querySelectorAll('.ap-req-task') ?? [])
    expect(taskLinks.length).toBeGreaterThan(0)
    for (const el of taskLinks) {
      expect(el.tagName).toBe('BUTTON')
      expect(el.textContent).not.toContain('nonblocking')
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
