import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { OperatorSnapshot } from '../../types'

void vi

const dispatchOperatorActionMock = vi.hoisted(() => vi.fn())

vi.mock('../../operator-store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../operator-store')>()
  return {
    ...actual,
    dispatchOperatorAction: dispatchOperatorActionMock,
  }
})

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await new Promise(resolve => setTimeout(resolve, 0))
  await Promise.resolve()
}

function clearActorStorage(): void {
  window.localStorage?.removeItem?.('masc_dashboard_agent_name')
}

async function loadQuickIntervene() {
  vi.resetModules()
  const mod = await import('./quick-intervene')
  const operatorStore = await import('../../operator-store')
  const opsState = await import('./ops-state')
  const router = await import('../../router')
  return {
    QuickIntervene: mod.QuickIntervene,
    actorName: opsState.actorName,
    operatorActionBusy: operatorStore.operatorActionBusy,
    operatorSnapshot: operatorStore.operatorSnapshot,
    quickComposerMode: opsState.quickComposerMode,
    quickMessage: opsState.quickMessage,
    quickTarget: opsState.quickTarget,
    route: router.route,
  }
}

describe('QuickIntervene', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    clearActorStorage()
    container = document.createElement('div')
    document.body.appendChild(container)
    dispatchOperatorActionMock.mockReset()
    dispatchOperatorActionMock.mockResolvedValue({
      status: 'ok',
      confirm_required: false,
      result: 'sent',
    })
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    clearActorStorage()
    vi.resetModules()
    vi.clearAllMocks()
  })

  it('keeps actor attribution hidden until advanced settings are opened', async () => {
    const {
      QuickIntervene,
      actorName,
      operatorActionBusy,
      operatorSnapshot,
      quickComposerMode,
      quickMessage,
      quickTarget,
      route,
    } = await loadQuickIntervene()

    actorName.value = 'dashboard-eager-manta'
    operatorActionBusy.value = false
    quickComposerMode.value = 'broadcast'
    quickMessage.value = ''
    quickTarget.value = 'namespace'
    route.value = { tab: 'command', params: { section: 'operations', view: 'ops' }, postId: null }
    operatorSnapshot.value = {
      root: { paused: false, namespace: 'default' },
      sessions: [{ session_id: 'session-a', status: 'active' }],
      keepers: [{ name: 'keeper-a', status: 'online' }],
      recent_messages: [],
      pending_confirms: [],
      available_actions: [],
    } as unknown as OperatorSnapshot

    await act(async () => { render(html`<${QuickIntervene} />`, container) })
    await flushUi()

    expect(container.textContent).toContain('Quick Intervention')
    expect(container.querySelector('div[aria-label="Composer mode"]')).not.toBeNull()
    expect(container.querySelector('input[name="quick_intervene_actor"]')).toBeNull()

    const toggle = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('Advanced'))
    toggle?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    const actorInput = container.querySelector('input[name="quick_intervene_actor"]') as HTMLInputElement | null
    expect(actorInput).not.toBeNull()
    expect(actorInput?.value).toBe('dashboard-eager-manta')

    actorInput!.value = 'dashboard-quiet-owl'
    actorInput!.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()

    expect(actorName.value).toBe('dashboard-quiet-owl')
  }, 15000)

  it('preselects state mode from command focus and inserts a state template', async () => {
    const {
      QuickIntervene,
      operatorActionBusy,
      operatorSnapshot,
      quickComposerMode,
      quickMessage,
      quickTarget,
      route,
    } = await loadQuickIntervene()

    operatorActionBusy.value = false
    quickComposerMode.value = 'broadcast'
    quickMessage.value = ''
    quickTarget.value = 'namespace'
    route.value = { tab: 'command', params: { section: 'operations', view: 'ops', focus: 'state' }, postId: null }
    operatorSnapshot.value = {
      root: { paused: false, namespace: 'default' },
      sessions: [],
      keepers: [{ name: 'keeper-a', status: 'online' }],
      recent_messages: [],
      pending_confirms: [],
      available_actions: [],
    } as unknown as OperatorSnapshot

    await act(async () => { render(html`<${QuickIntervene} />`, container) })
    await flushUi()

    const stateButton = container.querySelector('button[aria-label="State mode"]') as HTMLButtonElement | null
    const editor = container.querySelector('textarea[name="quick_intervene_message"]') as HTMLTextAreaElement | null

    expect(stateButton?.getAttribute('aria-pressed')).toBe('true')
    expect(editor?.value).toContain('[STATE]')
    expect(container.textContent).toContain('Goal')
    expect(container.textContent).toContain('Blocker')
  }, 15000)

  it('uses mention focus as keeper DM and sends to the first online keeper', async () => {
    const {
      QuickIntervene,
      operatorActionBusy,
      operatorSnapshot,
      quickComposerMode,
      quickMessage,
      quickTarget,
      route,
    } = await loadQuickIntervene()

    operatorActionBusy.value = false
    quickComposerMode.value = 'broadcast'
    quickMessage.value = 'ping keeper'
    quickTarget.value = 'namespace'
    route.value = { tab: 'command', params: { section: 'operations', view: 'ops', focus: 'mention' }, postId: null }
    operatorSnapshot.value = {
      root: { paused: false, namespace: 'default' },
      sessions: [],
      keepers: [
        { name: 'keeper-a', status: 'online' },
        { name: 'keeper-b', status: 'busy' },
      ],
      recent_messages: [],
      pending_confirms: [],
      available_actions: [],
    } as unknown as OperatorSnapshot

    await act(async () => { render(html`<${QuickIntervene} />`, container) })
    await flushUi()

    const dmButton = container.querySelector('button[aria-label="DM mode"]') as HTMLButtonElement | null
    const target = container.querySelector('select[aria-label="Keeper message target"]') as HTMLSelectElement | null
    const send = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.trim() === 'Send')

    expect(dmButton?.getAttribute('aria-pressed')).toBe('true')
    expect(target?.value).toBe('keeper:keeper-a')

    await act(async () => { send?.dispatchEvent(new MouseEvent('click', { bubbles: true })) })
    await flushUi()

    expect(dispatchOperatorActionMock).toHaveBeenCalledWith({
      actor: 'dashboard',
      action_type: 'keeper_message',
      target_type: 'keeper',
      target_id: 'keeper-a',
      payload: { message: 'ping keeper' },
    })
  }, 15000)

  it('filters mention autocomplete from @draft text and applies the selected keeper', async () => {
    const {
      QuickIntervene,
      operatorActionBusy,
      operatorSnapshot,
      quickComposerMode,
      quickMessage,
      quickTarget,
      route,
    } = await loadQuickIntervene()

    operatorActionBusy.value = false
    quickComposerMode.value = 'broadcast'
    quickMessage.value = 'Please verify @nick'
    quickTarget.value = 'namespace'
    route.value = { tab: 'command', params: { section: 'operations', view: 'ops', focus: 'mention' }, postId: null }
    operatorSnapshot.value = {
      root: { paused: false, namespace: 'default' },
      sessions: [],
      keepers: [
        { name: 'improver', status: 'online' },
        { name: 'nick0cave', status: 'busy' },
        { name: 'runtime', status: 'online' },
      ],
      recent_messages: [],
      pending_confirms: [],
      available_actions: [],
    } as unknown as OperatorSnapshot

    await act(async () => { render(html`<${QuickIntervene} />`, container) })
    await flushUi()

    const listbox = container.querySelector('div[role="listbox"]')
    const nickOption = Array.from(listbox?.querySelectorAll('button[role="option"]') ?? [])
      .find(button => button.textContent?.includes('@nick0cave')) as HTMLButtonElement | undefined
    const runtimeOption = Array.from(listbox?.querySelectorAll('button[role="option"]') ?? [])
      .find(button => button.textContent?.includes('@runtime'))

    expect(listbox?.getAttribute('aria-label')).toBe('Mention autocomplete (1 matches)')
    expect(nickOption).not.toBeUndefined()
    expect(runtimeOption).toBeUndefined()

    await act(async () => { nickOption?.dispatchEvent(new MouseEvent('click', { bubbles: true })) })
    await flushUi()

    const editor = container.querySelector('textarea[name="quick_intervene_message"]') as HTMLTextAreaElement | null
    expect(quickTarget.value).toBe('keeper:nick0cave')
    expect(editor?.value).toContain('@nick0cave')
    expect(quickMessage.value).toContain('@nick0cave')
    expect(container.querySelector('div[aria-label="Will mention: @nick0cave"]')).not.toBeNull()
  }, 15000)

  it('disables keeper DM send when no keepers are online', async () => {
    const {
      QuickIntervene,
      operatorActionBusy,
      operatorSnapshot,
      quickComposerMode,
      quickMessage,
      quickTarget,
      route,
    } = await loadQuickIntervene()

    operatorActionBusy.value = false
    quickComposerMode.value = 'broadcast'
    quickMessage.value = 'ping keeper'
    quickTarget.value = 'namespace'
    route.value = { tab: 'command', params: { section: 'operations', view: 'ops', focus: 'mention' }, postId: null }
    operatorSnapshot.value = {
      root: { paused: false, namespace: 'default' },
      sessions: [],
      keepers: [{ name: 'keeper-a', status: 'offline' }],
      recent_messages: [],
      pending_confirms: [],
      available_actions: [],
    } as unknown as OperatorSnapshot

    await act(async () => { render(html`<${QuickIntervene} />`, container) })
    await flushUi()

    const target = container.querySelector('select[aria-label="Keeper message target"]') as HTMLSelectElement | null
    const send = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.trim() === 'Send') as HTMLButtonElement | undefined

    expect(target?.disabled).toBe(true)
    expect(send?.disabled).toBe(true)
    expect(dispatchOperatorActionMock).not.toHaveBeenCalled()
  }, 15000)
})
