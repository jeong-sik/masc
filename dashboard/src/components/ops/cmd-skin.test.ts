import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { OperatorDigest, OperatorSnapshot, RouteState } from '../../types'

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

async function loadOps() {
  vi.resetModules()
  vi.doMock('../board/composer-v2', () => ({
    ComposerV2: () => html`<div data-testid="composer-v2">ComposerV2</div>`,
  }))
  vi.doMock('../flow-control/flow-control-panel', () => ({
    FlowControlPanel: () => html`<div data-testid="flow-control-panel">FlowControlPanel</div>`,
  }))
  const router = await import('../../router')
  const operatorStore = await import('../../operator-store')
  const mod = await import('./index')

  return {
    Ops: mod.Ops,
    route: router.route,
    operatorActionLog: operatorStore.operatorActionLog,
    operatorDigestError: operatorStore.operatorDigestError,
    operatorError: operatorStore.operatorError,
    operatorWorkspaceDigest: operatorStore.operatorWorkspaceDigest,
    operatorSnapshot: operatorStore.operatorSnapshot,
  }
}

function seedStores(stores: Awaited<ReturnType<typeof loadOps>>, view?: string): void {
  stores.route.value = {
    tab: 'command',
    params: view ? { section: 'operations', view } : { section: 'operations' },
    postId: null,
  } as RouteState
  stores.operatorError.value = null
  stores.operatorDigestError.value = null
  stores.operatorSnapshot.value = {
    root: { paused: false, namespace: 'default' },
    sessions: [],
    keepers: [{ name: 'keeper-a', status: 'online' }],
    recent_messages: [],
    available_actions: [],
  } as unknown as OperatorSnapshot
  stores.operatorWorkspaceDigest.value = {
    target_type: 'namespace',
    attention_items: [],
    recommended_actions: [],
  } as unknown as OperatorDigest
}

describe('Ops command-surface skin (keeper-v2 command.jsx parity)', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-03-31T11:00:00Z'))
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.useRealTimers()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../board/composer-v2')
    vi.doUnmock('../flow-control/flow-control-panel')
  })

  it('renders the activity timeline with cmd-log design classes', async () => {
    const stores = await loadOps()
    seedStores(stores)
    stores.operatorActionLog.value = [
      {
        id: 7,
        at: '2026-03-31T10:03:00Z',
        actor: 'dashboard',
        action_type: 'keeper_message',
        target_label: 'keeper:keeper-a',
        outcome: 'executed',
        message: 'keeper-a에게 메시지 전달',
      },
      {
        id: 6,
        at: '2026-03-31T10:01:00Z',
        actor: 'dashboard',
        action_type: 'broadcast',
        target_label: 'workspace',
        outcome: 'error',
        message: 'broadcast 실패',
      },
    ]

    render(html`<${stores.Ops} />`, container)
    await flushUi()

    const log = container.querySelector('[data-testid="ops-activity-timeline"]')
    expect(log?.classList.contains('cmd-log')).toBe(true)

    const rows = Array.from(container.querySelectorAll('.cmd-log .cmd-log-row'))
    expect(rows).toHaveLength(2)
    expect(rows[0]?.querySelector('.cmd-log-h .ai-b.ok')?.textContent).toBe('Keeper Message')
    expect(rows[0]?.querySelector('.cmd-log-b')?.textContent).toContain('keeper-a에게 메시지 전달')
    expect(rows[1]?.querySelector('.cmd-log-h .ai-b.bad')?.textContent).toBe('Broadcast')
    expect(rows[0]?.querySelectorAll('.cmd-log-h .mono.dim').length).toBe(3)
  })

  it('wraps the context-metrics diagnostic in cmd-banner with the design note', async () => {
    const stores = await loadOps()
    seedStores(stores)
    stores.operatorActionLog.value = []
    stores.operatorSnapshot.value = {
      root: { paused: false },
      sessions: [],
      keepers: [{
        name: 'sangsu',
        context_metrics_unavailable: { kind: 'not_observed', reason: 'context_measurement_missing' },
      }],
      persistent_agents: [],
      recent_messages: [],
      available_actions: [],
    } as unknown as OperatorSnapshot

    render(html`<${stores.Ops} />`, container)
    await flushUi()

    const banner = container.querySelector('[data-testid="ops-context-metrics-unavailable"]')
    expect(banner?.classList.contains('cmd-banner')).toBe(true)
    expect(banner?.querySelector('b')?.textContent).toBe('Context metrics unavailable')
    expect(banner?.textContent).toContain('Keeper sangsu')
    expect(banner?.textContent).toContain('스냅샷은 occupancy 를 관측하지 않습니다')
  })

  it('lays the operations controls out in cmd-cols and mounts the intervene form', async () => {
    const stores = await loadOps()
    seedStores(stores)
    stores.operatorActionLog.value = []

    render(html`<${stores.Ops} />`, container)
    await flushUi()

    const controls = container.querySelector('section[aria-label="Operations controls"]')
    expect(controls?.classList.contains('cmd-cols')).toBe(true)
    expect(controls?.querySelector('[data-testid="cmd-intervene-form"] .cmd-form')).not.toBeNull()
  })

  it('shows cmd-gatelinks only on the Intervene view', async () => {
    const stores = await loadOps()
    seedStores(stores, 'ops')
    stores.operatorActionLog.value = []

    render(html`<${stores.Ops} />`, container)
    await flushUi()

    const links = container.querySelector('[data-testid="cmd-gate-links"] .cmd-gatelinks')
    expect(links).not.toBeNull()
    expect(links?.querySelector('.tm-lane-t')?.textContent).toBe('Gate 열기')
  })

  it('omits cmd-gatelinks on the default view (approvals surface is inline there)', async () => {
    const stores = await loadOps()
    seedStores(stores)
    stores.operatorActionLog.value = []

    render(html`<${stores.Ops} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="cmd-gate-links"]')).toBeNull()
  })
})
