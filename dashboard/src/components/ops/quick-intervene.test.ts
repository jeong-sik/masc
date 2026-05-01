import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { OperatorSnapshot } from '../../types'

void vi

async function flushUi(): Promise<void> {
  await Promise.resolve()
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
  return {
    QuickIntervene: mod.QuickIntervene,
    actorName: opsState.actorName,
    operatorActionBusy: operatorStore.operatorActionBusy,
    operatorSnapshot: operatorStore.operatorSnapshot,
    quickMessage: opsState.quickMessage,
    quickTarget: opsState.quickTarget,
  }
}

describe('QuickIntervene', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    clearActorStorage()
    container = document.createElement('div')
    document.body.appendChild(container)
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
      quickMessage,
      quickTarget,
    } = await loadQuickIntervene()

    actorName.value = 'dashboard-eager-manta'
    operatorActionBusy.value = false
    quickMessage.value = ''
    quickTarget.value = 'namespace'
    operatorSnapshot.value = {
      root: { paused: false, namespace: 'default' },
      sessions: [{ session_id: 'session-a', status: 'active' }],
      keepers: [{ name: 'keeper-a', status: 'online' }],
      recent_messages: [],
      pending_confirms: [],
      available_actions: [],
    } as unknown as OperatorSnapshot

    render(html`<${QuickIntervene} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Quick Intervention')
    expect((container.querySelector('select[aria-label="Intervention target"]') as HTMLSelectElement | null)?.value).toBe('namespace')
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
})
