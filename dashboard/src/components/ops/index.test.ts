import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { OperatorDigest, OperatorSnapshot, RouteState } from '../../types'

void vi

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

async function loadOps() {
  vi.resetModules()
  vi.doMock('./quick-intervene', () => ({
    QuickIntervene: () => html`<div data-testid="quick-intervene">QuickIntervene</div>`,
  }))
  vi.doMock('../flow-control/flow-control-panel', () => ({
    FlowControlPanel: () => html`<div data-testid="flow-control-panel">FlowControlPanel</div>`,
  }))
  const router = await import('../../router')
  const operatorStore = await import('../../operator-store')
  const helpers = await import('./helpers')
  const mod = await import('./index')

  return {
    Ops: mod.Ops,
    route: router.route,
    operatorActionLog: operatorStore.operatorActionLog,
    operatorDigestError: operatorStore.operatorDigestError,
    operatorError: operatorStore.operatorError,
    operatorRoomDigest: operatorStore.operatorRoomDigest,
    operatorSnapshot: operatorStore.operatorSnapshot,
    hydratedWorkflowId: helpers.hydratedWorkflowId,
    reviewDecisionReason: helpers.reviewDecisionReason,
    selectedReviewItemId: helpers.selectedReviewItemId,
    selectedReviewTab: helpers.selectedReviewTab,
  }
}

describe('Ops intervene surface', () => {
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
    vi.doUnmock('./quick-intervene')
    vi.doUnmock('../flow-control/flow-control-panel')
  })

  it('renders a combined activity timeline for healthy mode without legacy KPI cards', async () => {
    const {
      Ops,
      route,
      operatorActionLog,
      operatorDigestError,
      operatorError,
      operatorRoomDigest,
      operatorSnapshot,
      hydratedWorkflowId,
      reviewDecisionReason,
      selectedReviewItemId,
      selectedReviewTab,
    } = await loadOps()

    route.value = { tab: 'command', params: { section: 'operations' }, postId: null } as RouteState
    hydratedWorkflowId.value = null
    reviewDecisionReason.value = ''
    selectedReviewItemId.value = ''
    selectedReviewTab.value = 'active'
    operatorError.value = null
    operatorDigestError.value = null
    operatorSnapshot.value = {
      root: { paused: false, namespace: 'default' },
      sessions: [],
      keepers: [],
      recent_messages: [],
      pending_confirms: [],
      available_actions: [],
    } as unknown as OperatorSnapshot
    operatorRoomDigest.value = {
      target_type: 'namespace',
      attention_items: [],
      recommended_actions: [],
      review_queue: [],
      deferred_queue: [],
      review_summary: {
        active_count: 0,
        deferred_count: 1,
        recent_count: 2,
      },
      recent_reviews: [
        {
          item_id: 'review-newest',
          fingerprint: 'fp-1',
          decision: 'resolved',
          actor: 'reviewer-1',
          reason: '프로젝트 검토 완료',
          at: '2026-03-31T10:05:00Z',
          target_type: 'namespace',
        },
        {
          item_id: 'review-oldest',
          fingerprint: 'fp-2',
          decision: 'deferred',
          actor: 'reviewer-2',
          reason: '키퍼 메시지는 잠시 보류',
          at: '2026-03-31T10:01:00Z',
          target_type: 'keeper',
          target_id: 'keeper-a',
        },
      ],
      worker_cards: [],
    } as unknown as OperatorDigest
    operatorActionLog.value = [
      {
        id: 7,
        at: '2026-03-31T10:03:00Z',
        actor: 'dashboard',
        action_type: 'keeper_message',
        target_label: 'keeper:keeper-a',
        outcome: 'executed',
        message: 'keeper-a에게 메시지 전달',
      },
    ]

    render(html`<${Ops} />`, container)
    await flushUi()

    expect(container.textContent).toContain('최근 운영 활동')
    expect(container.textContent).toContain('즉시 검토 0')
    expect(container.textContent).toContain('보류 1')
    expect(container.textContent).toContain('최근 처리 2')
    expect(container.textContent).toContain('프로젝트 진행 중')
    expect(container.textContent).toContain('QuickIntervene')
    expect(container.textContent).toContain('FlowControlPanel')
    expect(container.textContent).not.toContain('Active Queue')
    expect(container.textContent).not.toContain('Healthy Console')

    const items = Array.from(container.querySelectorAll('[data-testid="ops-activity-item"]'))
    expect(items).toHaveLength(3)
    expect(items[0]?.textContent).toContain('프로젝트 검토 완료')
    expect(items[1]?.textContent).toContain('keeper-a에게 메시지 전달')
    expect(items[2]?.textContent).toContain('키퍼 메시지는 잠시 보류')
  }, 120000)

  it('keeps the review workbench while replacing legacy KPI cards with compact badges', async () => {
    const {
      Ops,
      route,
      operatorActionLog,
      operatorDigestError,
      operatorError,
      operatorRoomDigest,
      operatorSnapshot,
      hydratedWorkflowId,
      reviewDecisionReason,
      selectedReviewItemId,
      selectedReviewTab,
    } = await loadOps()

    route.value = { tab: 'command', params: { section: 'operations' }, postId: null } as RouteState
    hydratedWorkflowId.value = null
    reviewDecisionReason.value = ''
    selectedReviewItemId.value = ''
    selectedReviewTab.value = 'active'
    operatorError.value = null
    operatorDigestError.value = null
    operatorSnapshot.value = {
      root: { paused: true, namespace: 'default' },
      sessions: [],
      keepers: [],
      recent_messages: [],
      pending_confirms: [],
      available_actions: [],
    } as unknown as OperatorSnapshot
    operatorRoomDigest.value = {
      target_type: 'namespace',
      attention_items: [],
      recommended_actions: [],
      review_queue: [
        {
          id: 'review-1',
          kind: 'room_gate',
          target_type: 'namespace',
          severity: 'warn',
          urgency: 'soon',
          summary: '방 제어 상태를 재확인하세요',
          why_now: 'pause 이후 후속 확인이 필요합니다.',
          fingerprint: 'fp-review-1',
        },
      ],
      deferred_queue: [],
      review_summary: {
        active_count: 1,
        deferred_count: 0,
        recent_count: 1,
      },
      recent_reviews: [
        {
          item_id: 'review-1',
          fingerprint: 'fp-review-1',
          decision: 'resolved',
          actor: 'dashboard',
          reason: '방 상태 확인 완료',
          at: '2026-03-31T10:10:00Z',
          target_type: 'namespace',
        },
      ],
      worker_cards: [],
    } as unknown as OperatorDigest
    operatorActionLog.value = []

    render(html`<${Ops} />`, container)
    await flushUi()

    expect(container.textContent).toContain('즉시 검토 1')
    expect(container.textContent).toContain('프로젝트 일시정지')
    expect(container.textContent).toContain('QuickIntervene')
    expect(container.textContent).toContain('FlowControlPanel')
    expect(container.textContent).toContain('실행 작업대')
    expect(container.textContent).toContain('현재 상태')
    expect(container.textContent).toContain('마찰 요인')
    expect(container.textContent).not.toContain('Active Queue')
    expect(container.textContent).not.toContain('Deferred')
    expect(container.textContent).not.toContain('Mode')
  }, 120000)
})
