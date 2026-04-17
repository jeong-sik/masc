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

  it('appends stale-binary hint when operatorErrorStatus is 404 (structured)', async () => {
    const operatorStore = await import('../../operator-store')
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
    operatorError.value = 'GET /api/v1/operator: 404 Not Found'
    operatorStore.operatorErrorStatus.value = 404
    operatorDigestError.value = null
    operatorStore.operatorDigestErrorStatus.value = null
    operatorSnapshot.value = null as unknown as OperatorSnapshot
    operatorRoomDigest.value = null as unknown as OperatorDigest
    operatorActionLog.value = []

    render(html`<${Ops} />`, container)
    await flushUi()

    const banner = container.querySelector('[data-testid="operator-error-banner"]')
    expect(banner).toBeTruthy()
    const hint = container.querySelector('[data-testid="operator-error-hint"]')
    expect(hint).toBeTruthy()
    expect(hint?.textContent).toContain('서버 바이너리')

    operatorStore.operatorErrorStatus.value = null
  }, 60000)

  it('falls back to message regex when status is null (legacy string error)', async () => {
    const operatorStore = await import('../../operator-store')
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
    operatorError.value = 'GET /api/v1/operator: 404 Not Found'
    operatorStore.operatorErrorStatus.value = null
    operatorDigestError.value = null
    operatorStore.operatorDigestErrorStatus.value = null
    operatorSnapshot.value = null as unknown as OperatorSnapshot
    operatorRoomDigest.value = null as unknown as OperatorDigest
    operatorActionLog.value = []

    render(html`<${Ops} />`, container)
    await flushUi()

    const hint = container.querySelector('[data-testid="operator-error-hint"]')
    expect(hint).toBeTruthy()
    expect(hint?.textContent).toContain('서버 바이너리')
  }, 60000)

  it('does not show the stale-binary hint for non-route errors', async () => {
    const operatorStore = await import('../../operator-store')
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
    operatorStore.operatorErrorStatus.value = null
    operatorDigestError.value = 'GET /api/v1/operator/digest: 500 Internal Server Error'
    operatorStore.operatorDigestErrorStatus.value = 500
    operatorSnapshot.value = null as unknown as OperatorSnapshot
    operatorRoomDigest.value = null as unknown as OperatorDigest
    operatorActionLog.value = []

    render(html`<${Ops} />`, container)
    await flushUi()

    const banner = container.querySelector('[data-testid="operator-error-banner"]')
    expect(banner).toBeTruthy()
    expect(banner?.textContent).toContain('500')
    expect(container.querySelector('[data-testid="operator-error-hint"]')).toBeNull()

    operatorStore.operatorDigestErrorStatus.value = null
  }, 60000)
})
