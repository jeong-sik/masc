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
  }
}

describe('Ops surface', () => {
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

  it('renders a combined activity timeline merging recent reviews and interventions', async () => {
    const {
      Ops,
      route,
      operatorActionLog,
      operatorDigestError,
      operatorError,
      operatorRoomDigest,
      operatorSnapshot,
      hydratedWorkflowId,
    } = await loadOps()

    route.value = { tab: 'command', params: { section: 'operations' }, postId: null } as RouteState
    hydratedWorkflowId.value = null
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
    expect(container.textContent).toContain('QuickIntervene')
    expect(container.textContent).toContain('FlowControlPanel')

    // Placeholder-heavy review queue surface is gone — Live Judge + Keeper HITL
    // handling lives on the Governance page.
    expect(container.textContent).not.toContain('review_item')
    expect(container.textContent).not.toContain('큐에서 항목을 고르세요')
    expect(container.textContent).not.toContain('현재 이 항목에 연결된 operator guidance가 없습니다')
    expect(container.textContent).not.toContain('실행 작업대')

    const items = Array.from(container.querySelectorAll('[data-testid="ops-activity-item"]'))
    expect(items).toHaveLength(3)
    expect(items[0]?.textContent).toContain('프로젝트 검토 완료')
    expect(items[1]?.textContent).toContain('keeper-a에게 메시지 전달')
    expect(items[2]?.textContent).toContain('키퍼 메시지는 잠시 보류')
  }, 120000)

  it('renders the same single surface when active review items are present (no 3-column unhealthy branch)', async () => {
    const {
      Ops,
      route,
      operatorActionLog,
      operatorDigestError,
      operatorError,
      operatorRoomDigest,
      operatorSnapshot,
      hydratedWorkflowId,
    } = await loadOps()

    route.value = { tab: 'command', params: { section: 'operations' }, postId: null } as RouteState
    hydratedWorkflowId.value = null
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
      recent_reviews: [],
      worker_cards: [],
    } as unknown as OperatorDigest
    operatorActionLog.value = []

    render(html`<${Ops} />`, container)
    await flushUi()

    expect(container.textContent).toContain('QuickIntervene')
    expect(container.textContent).toContain('FlowControlPanel')
    expect(container.textContent).toContain('최근 운영 활동')

    // The placeholder-heavy review queue panel no longer exists, and the
    // review_queue/deferred_queue/review_summary fields were dropped from
    // OperatorDigest. review items surface via Governance / Live Judge.
    expect(container.textContent).not.toContain('방 제어 상태를 재확인하세요')
    expect(container.textContent).not.toContain('마찰 요인')
    expect(container.textContent).not.toContain('운영 판단')
    expect(container.textContent).not.toContain('매뉴얼 처리')
  }, 120000)

  it('shows paused-namespace hint in activity timeline empty state when namespace is paused', async () => {
    const {
      Ops,
      route,
      operatorActionLog,
      operatorDigestError,
      operatorError,
      operatorRoomDigest,
      operatorSnapshot,
      hydratedWorkflowId,
    } = await loadOps()

    route.value = { tab: 'command', params: { section: 'operations' }, postId: null } as RouteState
    hydratedWorkflowId.value = null
    operatorError.value = null
    operatorDigestError.value = null
    operatorSnapshot.value = {
      root: { paused: true, namespace: 'default', pause_reason: '배포 윈도우', paused_by: 'vincent' },
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
      recent_reviews: [],
      worker_cards: [],
    } as unknown as OperatorDigest
    operatorActionLog.value = []

    render(html`<${Ops} />`, container)
    await flushUi()

    const empty = container.querySelector('[data-testid="ops-activity-timeline-empty"]')
    expect(empty).toBeTruthy()
    expect(empty?.textContent).toContain('namespace가 일시정지')
    expect(empty?.textContent).toContain('배포 윈도우')
    expect(empty?.textContent).toContain('by vincent')
  }, 60000)

  it('shows standard empty message when running namespace has no recent activity', async () => {
    const {
      Ops,
      route,
      operatorActionLog,
      operatorDigestError,
      operatorError,
      operatorRoomDigest,
      operatorSnapshot,
      hydratedWorkflowId,
    } = await loadOps()

    route.value = { tab: 'command', params: { section: 'operations' }, postId: null } as RouteState
    hydratedWorkflowId.value = null
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
      recent_reviews: [],
      worker_cards: [],
    } as unknown as OperatorDigest
    operatorActionLog.value = []

    render(html`<${Ops} />`, container)
    await flushUi()

    const empty = container.querySelector('[data-testid="ops-activity-timeline-empty"]')
    expect(empty).toBeTruthy()
    expect(empty?.textContent).toContain('최근 운영 활동이 없습니다')
    expect(empty?.textContent).not.toContain('일시정지')
  }, 60000)
})
