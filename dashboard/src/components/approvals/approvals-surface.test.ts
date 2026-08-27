import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { html } from 'htm/preact'
import { render } from 'preact'
import * as Vitest from 'vitest'
import type { DashboardGateResponse, KeeperApprovalQueueItem, KeeperApprovalRule, KeeperResolvedApprovalItem } from '../../types'

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
    input_hash: 'a'.repeat(64),
    sequence: 1,
    waiting_s: 92,
    input_preview: '{"path":"config.json","content":"hello"}',
    task_id: 'T-1',
    summary_status: { status: 'not_requested' },
    exact_attempt: { state: 'unbound' },
    summary_attempt_disposition: { code: 'ready' },
    ...overrides,
  }
}

function approvalRule(
  overrides: Partial<KeeperApprovalRule> & Pick<KeeperApprovalRule, 'id' | 'keeper_name' | 'tool_name'>,
): KeeperApprovalRule {
  return {
    request_fingerprint: 'a'.repeat(64),
    created_at: 1_782_525_723,
    created_by: 'operator',
    source_approval_id: 'appr-source',
    expires_at: null,
    ...overrides,
  }
}

function completedExactAttempt(id: string, callId: string) {
  return {
    state: 'bound' as const,
    approval_id: id,
    input_hash: 'a'.repeat(64),
    sequence: 1,
    slot_id: 'slot-1',
    call_id: callId,
    plan_fingerprint: 'plan-1',
    request_body_sha256: 'b'.repeat(64),
    status: 'completed' as const,
    quarantine_cause: null,
  }
}

function releasedRecoveryAttempt(id: string) {
  return {
    ...completedExactAttempt(id, 'call-recovery'),
    status: 'released_recovery_required' as const,
  }
}

function resolvedApproval(
  overrides: Partial<KeeperResolvedApprovalItem> = {},
): KeeperResolvedApprovalItem {
  const decision = overrides.decision ?? 'approve'
  return {
    id: 'appr-resolved',
    keeper_name: 'keeper-a',
    tool_name: 'fs_write',
    decision,
    decision_raw: decision === 'approve' ? 'approve' : 'reject:operator rejected',
    decision_reason: decision === 'approve' ? null : 'operator rejected',
    resolved_at: '2026-07-28T09:10:00Z',
    turn_id: null,
    task_id: null,
    goal_id: null,
    goal_ids: [],
    actor: 'operator',
    decision_source: 'human_operator',
    summary_status: { status: 'not_requested' },
    exact_attempt: { state: 'unbound' },
    ...overrides,
  }
}

function responseWithQueue(
  approval_queue: KeeperApprovalQueueItem[] | null,
  recent_resolved: KeeperResolvedApprovalItem[] | null = [],
  approval_rules: KeeperApprovalRule[] = [],
  hitl: DashboardGateResponse['hitl'] = {
    gate_mode: { mode: 'manual', configured: true, state: 'ready' },
    external_gate_mode: { mode: 'manual', configured: false, state: 'ready' },
    judge_lane: { status: 'available', lane_id: 'gate-judge', slots: ['judge'] },
  },
  approval_queue_state: DashboardGateResponse['approval_queue_state'] = {
    state: 'ready',
  },
  recent_resolved_page?: DashboardGateResponse['recent_resolved_page'],
  approval_queue_violations: DashboardGateResponse['approval_queue_violations'] = [],
  approval_rules_state: DashboardGateResponse['approval_rules_state'] = { state: 'ready' },
  recent_resolved_state: DashboardGateResponse['recent_resolved_state'] = { state: 'ready' },
  // Trailing overrides rather than two more positional parameters: this chain
  // is already ten deep and a caller that only cares about one field should
  // not have to spell the nine before it.
  extra: Partial<DashboardGateResponse> = {},
): DashboardGateResponse {
  const resolvedPage = recent_resolved_state.state === 'ready'
    ? recent_resolved_page ?? {
        returned: recent_resolved?.length ?? 0,
        matched: recent_resolved?.length ?? 0,
        limit: 20,
        window_minutes: 1440,
        truncated: false,
        scan_exhausted: false,
      }
    : null
  return {
    generated_at: '2026-06-19T00:00:00Z',
    approval_queue,
    approval_queue_state,
    approval_queue_violations,
    recent_resolved,
    recent_resolved_page: resolvedPage,
    recent_resolved_state,
    approval_rules,
    approval_rules_state,
    keeper_modes: [],
    keeper_modes_state: { state: 'ready' },
    keeper_judges: [],
    keeper_judges_state: { state: 'ready' },
    hitl,
    ...extra,
  } as DashboardGateResponse
}

// Mock the API seam refreshGate() reaches on mount, plus the SSE refresh
// registry.
async function loadSurface(
  approval_queue: KeeperApprovalQueueItem[] | null,
  recent_resolved: KeeperResolvedApprovalItem[] | null = [],
  approval_rules: KeeperApprovalRule[] = [],
  hitl?: DashboardGateResponse['hitl'],
  approval_queue_state: DashboardGateResponse['approval_queue_state'] = {
    state: 'ready',
  },
  recent_resolved_page?: DashboardGateResponse['recent_resolved_page'],
  approval_queue_violations: DashboardGateResponse['approval_queue_violations'] = [],
  approval_rules_state: DashboardGateResponse['approval_rules_state'] = { state: 'ready' },
  recent_resolved_state: DashboardGateResponse['recent_resolved_state'] = { state: 'ready' },
  extra: Partial<DashboardGateResponse> = {},
) {
  vi.resetModules()
  const resolveGateApproval = vi
    .fn()
    .mockResolvedValue({
      ok: true,
      id: 'appr-1',
      decision: 'approve',
      rule_id: null,
      audit_receipts: [{ event: 'resolved', recorded: true }],
    })
  const retryGateAutoJudge = vi
    .fn()
    .mockResolvedValue({ ok: true, id: 'appr-1' })
  const deleteGateApprovalRule = vi.fn().mockResolvedValue({
    ok: true,
    id: 'rule-1',
    audit: { event: 'rule_deleted', recorded: true },
  })
  const setGateMode = vi
    .fn()
    .mockResolvedValue({
      ok: true,
      mode: 'auto_judge',
      previous_mode: 'manual',
      actor: 'op',
      changed_at: '2026-06-19T00:00:00Z',
      recovery_status: 'completed',
      recovery_error: null,
      started: 0,
      queued: 0,
      recovery_failure_count: 0,
      recovery_failures: [],
    })
  const response = hitl
    ? responseWithQueue(
        approval_queue,
        recent_resolved,
        approval_rules,
        hitl,
        approval_queue_state,
        recent_resolved_page,
        approval_queue_violations,
        approval_rules_state,
        recent_resolved_state,
        extra,
      )
    : responseWithQueue(
        approval_queue,
        recent_resolved,
        approval_rules,
        undefined,
        approval_queue_state,
        recent_resolved_page,
        approval_queue_violations,
        approval_rules_state,
        recent_resolved_state,
        extra,
      )
  const setExternalGateMode = vi
    .fn()
    .mockResolvedValue({
      ok: true,
      mode: 'always_allow',
      previous_mode: 'manual',
      actor: 'op',
      changed_at: '2026-06-19T00:00:00Z',
      recovery_status: 'not_requested',
      recovery_error: null,
      started: 0,
      queued: 0,
      recovery_failure_count: 0,
      recovery_failures: [],
    })
  const apiMock = () => ({
    fetchDashboardGate: vi.fn().mockResolvedValue(response),
    resolveGateApproval,
    retryGateAutoJudge,
    deleteGateApprovalRule,
    setGateMode,
    setExternalGateMode,
  })
  vi.doMock('../../api', apiMock)
  vi.doMock('../../api/dashboard-gate', apiMock)
  vi.doMock('../../sse-store', () => ({
    registerGateRefresh: vi.fn(),
    registerGateAuditReceiptObserver: vi.fn(),
  }))
  // Preserve the real router (route signal etc.) but capture navigate() so the
  // "open keeper conversation" wiring can be asserted without a real route change.
  const navigate = vi.fn()
  vi.doMock('../../router', async (importOriginal) => ({
    ...(await importOriginal<typeof import('../../router')>()),
    navigate,
  }))
  const mod = await import('./approvals-surface')
  const gateSignals = await import('../gate-signals')
  gateSignals.clearGateAuditWriteFailures()
  return {
    ApprovalsSurface: mod.ApprovalsSurface,
    resolveGateApproval,
    retryGateAutoJudge,
    deleteGateApprovalRule,
    setGateMode,
    setExternalGateMode,
    navigate,
    gateSignals,
  }
}

describe('ApprovalsSurface', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    Object.defineProperty(window, 'prompt', {
      value: vi.fn().mockReturnValue('operator rejected'),
      configurable: true,
      writable: true,
    })
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
        exact_attempt: completedExactAttempt('appr-summary', 'run-1'),
        summary_attempt_disposition: { code: 'settled' },
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

  it('surfaces in-flight and terminal summary states rather than hiding them', async () => {
    const { ApprovalsSurface } = await loadSurface([
      queueItem({
        id: 'appr-pending',
        summary_status: { status: 'pending' },
        exact_attempt: {
          ...releasedRecoveryAttempt('appr-pending'),
          status: 'dispatch_uncertain',
        },
        summary_attempt_disposition: { code: 'in_flight' },
      }),
      queueItem({
        id: 'appr-failed',
        summary_status: { status: 'failed', reason: 'exact attempt quarantined' },
        exact_attempt: {
          ...completedExactAttempt('appr-failed', 'call-failed'),
          status: 'quarantined',
          quarantine_cause: 'flow_execution_failed',
        },
        summary_attempt_disposition: { code: 'settled' },
      }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const states = Array.from(
      container.querySelectorAll('[data-testid="approval-summary"]'),
    ).map(el => el.getAttribute('data-summary-state'))
    expect(states).toContain('pending')
    expect(states).toContain('failed')
    expect(container.textContent).toContain('exact attempt quarantined')
    expect(container.textContent).toContain('Human 판단 필요')
  }, 20000)

  it('rearms only operator-retryable typed Auto Judge states after an explicit click', async () => {
    const { ApprovalsSurface, retryGateAutoJudge } = await loadSurface([
      queueItem({
        id: 'appr-retry',
        summary_status: { status: 'pending' },
        exact_attempt: { state: 'unbound' },
        summary_attempt_disposition: {
          code: 'identity_unbound',
          operator_detail: 'Exact-output terminalization stopped before an attempt identity was bound.',
        },
      }),
      queueItem({
        id: 'appr-pre-worker',
        summary_status: { status: 'not_requested' },
        exact_attempt: { state: 'unbound' },
        summary_attempt_disposition: {
          code: 'pre_worker_unavailable',
          reason_code: 'mode_state_invalid',
          operator_detail: 'Gate mode state could not be read',
        },
      }),
      queueItem({
        id: 'appr-start-reserved',
        summary_status: { status: 'not_requested' },
        exact_attempt: { state: 'unbound' },
        summary_attempt_disposition: {
          code: 'pre_worker_unavailable',
          reason_code: 'start_reserved',
          operator_detail: 'Exact attempt start is already reserved',
        },
      }),
      queueItem({
        id: 'appr-recovery',
        summary_status: { status: 'pending' },
        exact_attempt: releasedRecoveryAttempt('appr-recovery'),
        summary_attempt_disposition: {
          code: 'persistence_uncertain',
          operator_detail: 'Exact-output terminalization durability is not confirmed.',
        },
      }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(retryGateAutoJudge).not.toHaveBeenCalled()
    expect(container.textContent).toContain('exact identity 미결합')
    expect(container.textContent).toContain('durability 확인 필요')
    expect(container.textContent).toContain('Gate mode 상태 불가')
    expect(container.textContent).toContain('Gate mode state could not be read')
    expect(container.textContent).toContain('exact identity 예약됨')
    expect(
      container.querySelector('[data-approval-id="appr-start-reserved"] .ap-act.retry'),
    ).toBeNull()
    container
      .querySelector<HTMLButtonElement>('[data-approval-id="appr-retry"] .ap-act.retry')
      ?.click()
    await flushUi()
    expect(retryGateAutoJudge).toHaveBeenCalledWith(
      'appr-retry',
      {
        input_hash: 'a'.repeat(64),
        sequence: 1,
        exact_attempt: { state: 'unbound' },
        summary_attempt_disposition: {
          code: 'identity_unbound',
          operator_detail:
            'Exact-output terminalization stopped before an attempt identity was bound.',
        },
      },
    )
    container
      .querySelector<HTMLButtonElement>('[data-approval-id="appr-pre-worker"] .ap-act.retry')
      ?.click()
    await flushUi()
    expect(retryGateAutoJudge).toHaveBeenLastCalledWith(
      'appr-pre-worker',
      {
        input_hash: 'a'.repeat(64),
        sequence: 1,
        exact_attempt: { state: 'unbound' },
        summary_attempt_disposition: {
          code: 'pre_worker_unavailable',
          reason_code: 'mode_state_invalid',
          operator_detail: 'Gate mode state could not be read',
        },
      },
    )
  }, 20000)

  it('does not offer rearm for a terminal exact Auto Judge failure', async () => {
    const { ApprovalsSurface, retryGateAutoJudge } = await loadSurface([
      queueItem({
        id: 'appr-terminal',
        summary_status: {
          status: 'failed',
          reason: 'exact attempt quarantined',
        },
        exact_attempt: {
          ...completedExactAttempt('appr-terminal', 'call-terminal'),
          status: 'quarantined',
          quarantine_cause: 'flow_execution_failed',
        },
        summary_attempt_disposition: { code: 'settled' },
      }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Human 판단 필요')
    expect(container.querySelector('.ap-card .ap-act.retry')).toBeNull()
    expect(retryGateAutoJudge).not.toHaveBeenCalled()
  }, 20000)

  it('renders an explicit unavailable state instead of an empty queue', async () => {
    const { ApprovalsSurface } = await loadSurface(
      null,
      [
        resolvedApproval({
          id: 'appr-resolved-during-reset',
          keeper_name: 'keeper-a',
          tool_name: 'fs_write',
          decision: 'reject',
          resolved_at: '2026-07-27T00:00:00Z',
        }),
      ],
      [],
      undefined,
      {
        state: 'unavailable',
        code: 'reset_required',
        title: 'Gate durable queue unavailable · runtime reset required',
        operator_detail: 'pending store requires reset',
        severity: 'bad',
        icon: '!',
      },
    )

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="approvals-empty"]')).toBeNull()
    const unavailable = container.querySelector('[data-testid="approvals-queue-unavailable"]')
    expect(unavailable).not.toBeNull()
    expect(unavailable?.getAttribute('data-severity')).toBe('bad')
    expect(unavailable?.textContent).toContain('!')
    expect(unavailable?.textContent).toContain('Gate durable queue unavailable · runtime reset required')
    expect(unavailable?.textContent).toContain('pending store requires reset')
    expect(container.querySelector('.ov-kpis')).toBeNull()
    expect(container.querySelector('[data-testid="approvals-aside"]')).toBeNull()
    expect(container.textContent).not.toContain('열린 승인 0건')

    container.querySelector<HTMLButtonElement>('.ap-viewbtn:not(.on)')?.click()
    await flushUi()
    expect(container.querySelector('[data-testid="approvals-history-view"]')?.textContent)
      .toContain('appr-resolved-during-reset')
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
        goal_id: 'G-1',
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
    expect(panel?.textContent).toContain('goal G-1')
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

  // The history list always travels with its exact server page bounds.
  const resolvedRow: KeeperResolvedApprovalItem = resolvedApproval({
    id: 'appr-1',
    keeper_name: 'rondo',
    tool_name: 'tool_execute',
    decision: 'approve',
    decision_source: 'auto_judge',
    resolved_at: '2026-07-28T02:53:47Z',
  })

  async function openHistory(page: DashboardGateResponse['recent_resolved_page']) {
    const { ApprovalsSurface } = await loadSurface(
      [],
      [resolvedRow],
      [],
      undefined,
      { state: 'ready' },
      page,
    )
    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()
    container.querySelector<HTMLButtonElement>('.ap-viewbtn:not(.on)')?.click()
    await flushUi()
    return container.querySelector('[data-testid="approvals-history-scope"]')
  }

  it('states the window and the total when the history is complete', async () => {
    const scope = await openHistory({
      returned: 1,
      matched: 1,
      limit: 20,
      window_minutes: 1440,
      truncated: false,
      scan_exhausted: false,
    })

    expect(scope?.textContent).toContain('최근 1일')
    expect(scope?.textContent).toContain('건 전체')
    expect(scope?.className).not.toContain('warn')
  }, 20000)

  it('says how much of the window is missing when the page is a slice', async () => {
    const scope = await openHistory({
      returned: 20,
      matched: 149,
      limit: 20,
      window_minutes: 1440,
      truncated: true,
      scan_exhausted: false,
    })

    expect(scope?.textContent).toContain('149')
    expect(scope?.textContent).toContain('20')
    expect(scope?.className).toContain('warn')
  }, 20000)

  it('says the window was not fully read when the server hit its row cap', async () => {
    const scope = await openHistory({
      returned: 20,
      matched: 20,
      limit: 20,
      window_minutes: 1440,
      truncated: false,
      scan_exhausted: true,
    })

    expect(scope?.textContent).toContain('읽지 못했습니다')
    expect(scope?.className).toContain('warn')
  }, 20000)

  it('renders audit-store unavailability instead of an empty history', async () => {
    const { ApprovalsSurface } = await loadSurface(
      [],
      null,
      [],
      undefined,
      { state: 'ready' },
      null,
      [],
      { state: 'ready' },
      {
        state: 'unavailable',
        stage: 'list_recent_resolved',
        error: 'audit JSONL unreadable',
      },
    )
    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const alert = container.querySelector('[data-testid="approvals-history-unavailable"]')
    expect(alert?.textContent).toContain('audit JSONL unreadable')
    expect(container.querySelector('[data-testid="approvals-history-count"]')).toBeNull()
  }, 20000)

  it('counts resolved decisions on the history tab so the default screen shows they exist', async () => {
    const { ApprovalsSurface } = await loadSurface([], [resolvedRow])
    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    // Still on the queue tab: the badge is the only cue that history exists.
    expect(container.querySelector('[data-testid="approvals-history-view"]')).toBeNull()
    expect(
      container.querySelector('[data-testid="approvals-history-count"]')?.textContent,
    ).toBe('1')
  }, 20000)

  it('renders resolved approval history with resolved timestamp and closed decision class', async () => {
    const { ApprovalsSurface } = await loadSurface(
      [],
      [
        resolvedApproval({
          id: 'appr-done',
          keeper_name: 'masc-improver',
          tool_name: 'fs_write',
          decision: 'reject',
          decision_source: 'human_operator',
          decision_raw: 'reject:operator denied',
          decision_reason: 'operator denied',
          actor: null,
          resolved_at: '2026-06-27T01:02:03Z',
        }),
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
    expect(history?.textContent).toContain('unattributed')
    expect(history?.textContent).toContain('appr-done')
    expect(history?.querySelector('.ap-hist-dec')?.className).toContain('bad')
    expect(history?.querySelector('.ap-hist-dec')?.className).not.toContain('operator denied')
    expect(history?.querySelector('.ap-hist-at')?.textContent).toContain('2026')
  }, 20000)

  it('unfolds judge evidence and slot only on rows that carry judge evidence', async () => {
    const { ApprovalsSurface } = await loadSurface(
      [],
      [
        resolvedApproval({
          id: 'appr-judged',
          keeper_name: 'keeper-a',
          tool_name: 'shell_exec',
          decision: 'approve',
          decision_source: 'auto_judge',
          resolved_at: '2026-07-28T09:39:00Z',
          summary_status: {
            status: 'available',
            summary: {
              summary_version: 2,
              generated_at: '2026-07-28T09:38:40Z',
              model_run_id: 'run-1',
              context_summary: 'Keeper requested a read-only listing.',
              key_questions: ['Is the path inside the sandbox?'],
              judgment: 'approve',
              rationale: 'Read-only and scoped.',
            },
          },
          exact_attempt: {
            state: 'bound',
            approval_id: 'appr-judged',
            input_hash: 'a'.repeat(64),
            sequence: 7,
            slot_id: 'glm-coding.glm-5-turbo',
            call_id: 'call-1',
            plan_fingerprint: 'plan-1',
            request_body_sha256: 'c'.repeat(64),
            status: 'completed',
            quarantine_cause: null,
          },
        }),
        resolvedApproval({
          id: 'appr-plain',
          keeper_name: 'keeper-a',
          tool_name: 'fs_write',
          decision: 'approve',
          resolved_at: '2026-07-28T09:10:00Z',
        }),
      ],
    )

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    container.querySelector<HTMLButtonElement>('.ap-viewbtn:not(.on)')?.click()
    await flushUi()

    const rows = container.querySelectorAll('[data-testid="approval-history-item"]')
    expect(rows).toHaveLength(2)
    const judged = container.querySelector('[data-approval-id="appr-judged"]')
    expect(judged?.querySelector('[data-testid="approval-history-slot"]')?.textContent)
      .toBe('glm-coding.glm-5-turbo')
    const fold = judged?.querySelector('[data-testid="approval-history-judge"]')
    expect(fold?.textContent).toContain('Keeper requested a read-only listing.')
    expect(fold?.textContent).toContain('Is the path inside the sandbox?')
    expect(fold?.textContent).toContain('Read-only and scoped.')
    const plain = container.querySelector('[data-approval-id="appr-plain"]')
    expect(plain?.querySelector('[data-testid="approval-history-slot"]')).toBeNull()
    expect(plain?.querySelector('[data-testid="approval-history-judge"]')).toBeNull()
  }, 20000)

  it('renders the recorded decision rationale in the reason slot only when the audit has one', async () => {
    const { ApprovalsSurface } = await loadSurface(
      [],
      [
        resolvedApproval({
          id: 'appr-with-reason',
          decision: 'reject',
          decision_source: 'human_operator',
          decision_reason: 'path outside the sandbox boundary',
          resolved_at: '2026-07-28T02:53:47Z',
        }),
        resolvedApproval({
          id: 'appr-no-reason',
          decision: 'approve',
          decision_reason: null,
          resolved_at: '2026-07-28T02:40:00Z',
        }),
      ],
    )

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    container.querySelector<HTMLButtonElement>('.ap-viewbtn:not(.on)')?.click()
    await flushUi()

    const withReason = container.querySelector('[data-approval-id="appr-with-reason"]')
    expect(withReason?.querySelector('[data-testid="approval-history-reason"]')?.textContent)
      .toBe('path outside the sandbox boundary')
    const noReason = container.querySelector('[data-approval-id="appr-no-reason"]')
    expect(noReason?.querySelector('[data-testid="approval-history-reason"]')).toBeNull()
  }, 20000)

  it('filters history by decision source and counts Auto Judge in the summary', async () => {
    const { ApprovalsSurface } = await loadSurface(
      [],
      [
        resolvedApproval({
          id: 'appr-human',
          decision: 'approve',
          decision_source: 'human_operator',
          resolved_at: '2026-07-28T03:00:00Z',
        }),
        resolvedApproval({
          id: 'appr-judged',
          decision: 'approve',
          decision_source: 'auto_judge',
          resolved_at: '2026-07-28T02:00:00Z',
        }),
        resolvedApproval({
          id: 'appr-always',
          decision: 'approve',
          decision_source: 'always_allowed',
          resolved_at: '2026-07-28T01:00:00Z',
        }),
      ],
    )

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    container.querySelector<HTMLButtonElement>('.ap-viewbtn:not(.on)')?.click()
    await flushUi()

    const history = container.querySelector('[data-testid="approvals-history-view"]')
    const judgeStat = Array.from(history?.querySelectorAll('.ap-hist-stat') ?? [])
      .find(stat => stat.textContent?.includes('Auto Judge'))
    expect(judgeStat?.textContent).toContain('1')

    const pill = (label: string) =>
      Array.from(container.querySelectorAll<HTMLButtonElement>('.ap-hist-f'))
        .find(button => button.textContent === label)

    pill('Auto Judge')?.click()
    await flushUi()
    expect(history?.textContent).toContain('appr-judged')
    expect(history?.textContent).not.toContain('appr-human')
    expect(history?.textContent).not.toContain('appr-always')

    pill('HITL 수동')?.click()
    await flushUi()
    expect(history?.textContent).toContain('appr-human')
    expect(history?.textContent).not.toContain('appr-judged')

    pill('Always')?.click()
    await flushUi()
    expect(history?.textContent).toContain('appr-always')
    expect(history?.textContent).not.toContain('appr-human')

    // The design's 보류 pill stays out: no live decision produces it.
    expect(pill('보류')).toBeUndefined()
  }, 20000)

  it('shows contract-violating queue rows as a visible banner instead of a clean empty queue', async () => {
    const { ApprovalsSurface } = await loadSurface(
      [],
      [],
      [],
      undefined,
      { state: 'ready' },
      null,
      [{ index: 0, id: 'appr-drifted', keeper_name: 'keeper-b', tool_name: 'fs_write' }],
    )

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const banner = container.querySelector('[data-testid="approvals-queue-violations"]')
    expect(banner).not.toBeNull()
    expect(banner?.textContent).toContain('표시 불가 대기 요청 1건')
    expect(banner?.textContent).toContain('appr-drifted')
    expect(container.querySelector('[data-testid="approvals-empty"]')).toBeNull()
  }, 20000)

  it('names the judge lane model in the Gate mode card, and its unavailability', async () => {
    const { ApprovalsSurface } = await loadSurface([], [], [], {
      gate_mode: { mode: 'auto_judge', configured: true, state: 'ready' },
      external_gate_mode: { mode: 'manual', configured: false, state: 'ready' },
      judge_lane: {
        status: 'available',
        lane_id: 'hitl_auto_judge',
        slots: ['glm-coding.glm-5-turbo', 'ollama_cloud.deepseek-v4-flash'],
      },
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const lane = container.querySelector('[data-testid="gate-judge-lane"]')
    expect(lane?.textContent).toContain('판정 모델 glm-coding.glm-5-turbo')
    expect(lane?.textContent).toContain('+1 failover')

    const { ApprovalsSurface: UnavailableSurface } = await loadSurface([], [], [], {
      gate_mode: { mode: 'auto_judge', configured: true, state: 'ready' },
      external_gate_mode: { mode: 'manual', configured: false, state: 'ready' },
      judge_lane: {
        status: 'unavailable',
        lane_id: 'hitl_auto_judge',
        reason: 'registry_not_published',
      },
    })

    render(html`<${UnavailableSurface} />`, container)
    await flushUi()

    const unavailable = container.querySelector('[data-testid="gate-judge-lane"]')
    expect(unavailable?.textContent).toContain('hitl_auto_judge')
    expect(unavailable?.textContent).toContain('registry_not_published')
  }, 20000)

  it('filters resolved approval history and renders current rules separately', async () => {
    const { ApprovalsSurface } = await loadSurface(
      [],
      [
        resolvedApproval({
          id: 'appr-approved',
          keeper_name: 'keeper-a',
          tool_name: 'fs_write',
          decision: 'approve',
          decision_source: 'human_operator',
          resolved_at: '2026-06-27T02:02:03Z',
        }),
        resolvedApproval({
          id: 'appr-rejected',
          keeper_name: 'keeper-b',
          tool_name: 'shell',
          decision: 'reject',
          decision_source: 'auto_judge',
          resolved_at: '2026-06-27T01:02:03Z',
        }),
      ],
      [
        approvalRule({
          id: 'rule-1',
          keeper_name: 'keeper-a',
          tool_name: 'fs_write',
          request_fingerprint: 'a'.repeat(64),
          created_at: 1782525723,
          created_by: 'operator',
          source_approval_id: 'appr-approved',
          expires_at: null,
        }),
      ],
    )

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const aside = container.querySelector('[data-testid="approvals-aside"]')
    expect(aside?.textContent).toContain('Always Rules')
    expect(aside?.textContent).toContain('keeper-a')
    expect(aside?.textContent).toContain('fs_write')
    expect(aside?.textContent).toContain('aaaaaaaaaaaa')

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

  it('makes hidden Always rules explicit when the aside list overflows its cap', async () => {
    const rules = Array.from({ length: 8 }, (_, i) => approvalRule({
      id: `rule-${i}`,
      keeper_name: 'keeper-a',
      tool_name: 'fs_write',
      request_fingerprint: i.toString(16).padStart(64, '0'),
    }))
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
    const rules = Array.from({ length: 6 }, (_, i) => approvalRule({
      id: `rule-${i}`,
      keeper_name: 'k',
      tool_name: 't',
      request_fingerprint: i.toString(16).padStart(64, '0'),
    }))
    const { ApprovalsSurface } = await loadSurface([], [], rules)

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="approvals-rules-overflow"]')).toBeNull()
  }, 20000)

  it('renders rule-store unavailability instead of an empty rule list', async () => {
    const { ApprovalsSurface } = await loadSurface(
      [],
      [],
      [],
      undefined,
      { state: 'ready' },
      null,
      [],
      { state: 'unavailable', error: 'approval rules store unreadable' },
    )

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="approval-rules-unavailable"]')?.textContent)
      .toContain('approval rules store unreadable')
    expect(container.textContent).not.toContain('저장된 Always 규칙 없음')
  }, 20000)

  it('shows expired rules and deletes the exact rule through the live action', async () => {
    const expiredRule = approvalRule({
      id: 'rule-expired',
      keeper_name: 'keeper-expired',
      tool_name: 'fs_write',
      created_at: 1_700_000_000,
      expires_at: 1_700_000_100,
    })
    const { ApprovalsSurface, deleteGateApprovalRule } = await loadSurface([], [], [expiredRule])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="approval-rule-expiry"]')?.textContent)
      .toContain('만료됨')
    const deleteButton = Array.from(container.querySelectorAll<HTMLButtonElement>('button'))
      .find(button => button.getAttribute('aria-label') === 'fs_write Always 규칙 삭제')
    deleteButton?.click()
    await flushUi()

    expect(deleteGateApprovalRule).toHaveBeenCalledWith('rule-expired')
  }, 20000)

  it('shows the empty state when no approvals are pending', async () => {
    const { ApprovalsSurface } = await loadSurface([])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="approvals-empty"]')).not.toBeNull()
    expect(container.textContent).toContain('열린 Human 판단 없음')
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
      retryGateAutoJudge: vi.fn().mockResolvedValue({ ok: true }),
      deleteGateApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
      setGateMode: vi.fn().mockResolvedValue({ ok: true }),
      setExternalGateMode: vi.fn().mockResolvedValue({ ok: true }),
    }))
    vi.doMock('../../api/dashboard-gate', () => ({
      fetchDashboardGate,
      resolveGateApproval: vi.fn().mockResolvedValue({ ok: true }),
      retryGateAutoJudge: vi.fn().mockResolvedValue({ ok: true }),
      deleteGateApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
      setGateMode: vi.fn().mockResolvedValue({ ok: true }),
      setExternalGateMode: vi.fn().mockResolvedValue({ ok: true }),
    }))
    vi.doMock('../../sse-store', () => ({
      registerGateRefresh: vi.fn(),
      registerGateAuditReceiptObserver: vi.fn(),
    }))
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
      retryGateAutoJudge: vi.fn().mockResolvedValue({ ok: true }),
      deleteGateApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
      setGateMode: vi.fn().mockResolvedValue({ ok: true }),
      setExternalGateMode: vi.fn().mockResolvedValue({ ok: true }),
    }))
    vi.doMock('../../api/dashboard-gate', () => ({
      fetchDashboardGate,
      resolveGateApproval: vi.fn().mockResolvedValue({ ok: true }),
      retryGateAutoJudge: vi.fn().mockResolvedValue({ ok: true }),
      deleteGateApprovalRule: vi.fn().mockResolvedValue({ ok: true }),
      setGateMode: vi.fn().mockResolvedValue({ ok: true }),
      setExternalGateMode: vi.fn().mockResolvedValue({ ok: true }),
    }))
    vi.doMock('../../sse-store', () => ({
      registerGateRefresh: vi.fn(),
      registerGateAuditReceiptObserver: vi.fn(),
    }))
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

    expect(resolveGateApproval).toHaveBeenCalledWith(
      'appr-9',
      { decision: 'approve', rememberRule: false },
    )
  })

  it('renders committed-but-unaudited HTTP success with a distinct RAW receipt', async () => {
    const { ApprovalsSurface, resolveGateApproval } = await loadSurface([
      queueItem({ id: 'appr-audit', keeper_name: 'masc-improver' }),
    ])
    resolveGateApproval.mockResolvedValueOnce({
      ok: true,
      id: 'appr-audit',
      decision: 'approve',
      rule_id: null,
      audit_receipts: [{
        event: 'resolved',
        recorded: false,
        stage: 'append',
        detail: 'audit append unavailable',
      }],
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()
    container.querySelector<HTMLButtonElement>('.ap-card .ap-act.approve')?.click()
    await flushUi()

    const alert = container.querySelector('[data-testid="approval-audit-write-unavailable"]')
    expect(alert?.textContent).toContain('권한 변경은 커밋됐지만 감사 기록은 저장되지 않았습니다')
    expect(alert?.textContent).toContain('resolved · append')
    expect(alert?.textContent).toContain('appr-audit · HTTP')
    const raw = container.querySelector('[data-testid="approval-audit-write-raw"]')
    expect(raw?.textContent).toContain('"recorded": false')
    expect(raw?.textContent).toContain('"detail": "audit append unavailable"')
  })

  it('routes the 거부 action through resolveGateApproval with the reject decision', async () => {
    const { ApprovalsSurface, resolveGateApproval } = await loadSurface([
      queueItem({ id: 'appr-r', keeper_name: 'masc-improver' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const prompt = vi.spyOn(window, 'prompt').mockReturnValueOnce('작업 범위를 벗어남')
    container.querySelector<HTMLButtonElement>('.ap-card .ap-act.deny')?.click()
    await flushUi()

    expect(prompt).toHaveBeenCalledWith('승인 요청을 거부하는 이유를 입력하세요.')
    expect(resolveGateApproval).toHaveBeenCalledWith(
      'appr-r',
      { decision: 'reject', reason: '작업 범위를 벗어남' },
    )
    prompt.mockRestore()
  })

  it('routes the 항상 승인 action through resolveGateApproval with rememberRule=true', async () => {
    const { ApprovalsSurface, resolveGateApproval } = await loadSurface([
      queueItem({ id: 'appr-a', keeper_name: 'masc-improver' }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    container.querySelector<HTMLButtonElement>('.ap-card .ap-act.always')?.click()
    await flushUi()

    expect(resolveGateApproval).toHaveBeenCalledWith(
      'appr-a',
      { decision: 'approve', rememberRule: true },
    )
  })

  it('binds the three non-hierarchical choices to hitl.gate_mode', async () => {
    const { ApprovalsSurface } = await loadSurface([], [], [], {
      gate_mode: { mode: 'auto_judge', configured: true, state: 'ready' },
      external_gate_mode: { mode: 'manual', configured: false, state: 'ready' },
      judge_lane: { status: 'available', lane_id: 'gate-judge', slots: ['judge'] },
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
    const { ApprovalsSurface } = await loadSurface([], [], [], {
      gate_mode: { mode: 'manual', configured: true, state: 'ready' },
      external_gate_mode: { mode: 'manual', configured: false, state: 'ready' },
      judge_lane: { status: 'available', lane_id: 'gate-judge', slots: ['judge'] },
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const human = Array.from(container.querySelectorAll<HTMLButtonElement>('[data-testid="gate-mode-selector"] [role="radio"]'))
      .find(choice => choice.textContent === 'Human')
    expect(human?.getAttribute('aria-checked')).toBe('true')
  }, 20000)

  it('routes a Gate mode choice through setGateMode', async () => {
    const { ApprovalsSurface, setGateMode } = await loadSurface([], [], [], {
      gate_mode: { mode: 'manual', configured: true, state: 'ready' },
      external_gate_mode: { mode: 'manual', configured: false, state: 'ready' },
      judge_lane: { status: 'available', lane_id: 'gate-judge', slots: ['judge'] },
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

  it('binds the external-services lane to hitl.external_gate_mode and routes through setExternalGateMode', async () => {
    // The lane exists because on 2026-08-27 the workspace lane was open
    // (374 of 379 decisions rode workspace always-allow) and outside-service
    // writes must not inherit that switch. The selector must read the
    // external lane, not the workspace one, and its choice must reach the
    // external endpoint.
    const { ApprovalsSurface, setExternalGateMode, setGateMode } = await loadSurface([], [], [], {
      gate_mode: { mode: 'always_allow', configured: true, state: 'ready' },
      external_gate_mode: { mode: 'manual', configured: false, state: 'ready' },
      judge_lane: { status: 'available', lane_id: 'gate-judge', slots: ['judge'] },
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const selector = container.querySelector('[data-testid="gate-external-mode-selector"]')
    expect(selector?.getAttribute('role')).toBe('radiogroup')
    const choices = Array.from(selector?.querySelectorAll<HTMLButtonElement>('[role="radio"]') ?? [])
    // The workspace lane says always_allow; the external selector must show manual.
    expect(choices.find(choice => choice.textContent === 'Human')?.getAttribute('aria-checked')).toBe('true')
    expect(choices.find(choice => choice.textContent === 'Always Allow')?.getAttribute('aria-checked')).toBe('false')

    choices.find(choice => choice.textContent === 'Auto Judge')?.click()
    await flushUi()
    expect(setExternalGateMode).toHaveBeenCalledWith('auto_judge')
    expect(setGateMode).not.toHaveBeenCalled()

    const aside = container.querySelector('[data-testid="approvals-aside"]')
    expect(aside?.textContent).toContain('바깥 서비스 쓰기')
  }, 20000)

  it('renders an identity_call row by its provider and remote tool, not the closed operation name', async () => {
    // Every outside-service call submits under one operation identity; a
    // human deciding "may this run" needs the provider and the real tool,
    // which ride in the input.
    const { ApprovalsSurface } = await loadSurface([
      queueItem({
        id: 'appr-identity',
        keeper_name: 'kidsnote',
        tool_name: 'identity_call',
        input: {
          provider_id: 'atlassian',
          remote_name: 'addCommentToJiraIssue',
          arguments: { issueIdOrKey: 'PK-1', body: 'hello' },
        },
        input_preview: '{"provider_id":"atlassian","remote_name":"addCommentToJiraIssue",…}',
      }),
    ])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const card = container.querySelector('[data-approval-id="appr-identity"]')
    expect(card?.querySelector('.ap-tool')?.textContent).toBe('atlassian · addCommentToJiraIssue')
    expect(card?.textContent).toContain('atlassian · addCommentToJiraIssue Gate 요청')
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
    const goalEls = Array.from(card?.querySelectorAll('.ap-req-goal') ?? [])
    expect(goalEls.length).toBeGreaterThan(0)
    for (const el of goalEls) {
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

  it('shows which Keepers were singled out', async () => {
    const { ApprovalsSurface } = await loadSurface([], [], [], undefined, undefined, undefined, undefined, undefined, undefined, {
      keeper_modes: [
        {
          keeper_name: 'kidsnote',
          mode: 'manual',
          updated_by: 'vincent',
          updated_at: '2026-08-27T05:00:00Z',
        },
      ],
      keeper_judges: [
        {
          keeper_name: 'kidsnote',
          slot_id: 'glm-coding.glm-5-turbo',
          updated_by: 'vincent',
          updated_at: '2026-08-27T05:00:00Z',
        },
      ],
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const modeRows = container.querySelectorAll('[data-testid="keeper-mode-row"]')
    expect(modeRows.length).toBe(1)
    expect(modeRows[0]?.textContent).toContain('kidsnote')
    // The label an operator picked in the mode control, not the wire value.
    expect(modeRows[0]?.textContent).toContain('Human')
    const judgeRows = container.querySelectorAll('[data-testid="keeper-judge-row"]')
    expect(judgeRows.length).toBe(1)
    expect(judgeRows[0]?.textContent).toContain('glm-coding.glm-5-turbo')
  })

  it('says nobody was singled out rather than showing nothing', async () => {
    const { ApprovalsSurface } = await loadSurface([], [], [])

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="keeper-gate-settings"]')?.textContent)
      .toContain('모드를 따로 정한 Keeper 없음')
  })

  it('reports an unreadable override file instead of an empty list', async () => {
    // Empty means nobody was singled out, which is a working configuration. A
    // file that could not be read must not be able to look like one.
    const { ApprovalsSurface } = await loadSurface([], [], [], undefined, undefined, undefined, undefined, undefined, undefined, {
      keeper_modes: [],
      keeper_modes_state: { state: 'unavailable', error: 'overrides unreadable' },
    })

    render(html`<${ApprovalsSurface} />`, container)
    await flushUi()

    const warn = container.querySelector('[data-testid="keeper-modes-unavailable"]')
    expect(warn?.textContent).toContain('overrides unreadable')
    expect(container.querySelectorAll('[data-testid="keeper-mode-row"]').length).toBe(0)
  })

})
