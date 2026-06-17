// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { waitFor, fireEvent } from '@testing-library/preact'
import {
  CopilotDock,
  CopilotDockFab,
  CopilotDockTopBarButton,
  getSurfaceContext,
  useCopilotDock,
  useCopilotDockShortcuts,
} from './copilot-dock'
import { route } from '../router'
import { keepers } from '../store'
import { globalShortcutManager } from '../lib/global-shortcut-manager'

describe('CopilotDock', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    route.value = { tab: 'overview', params: {}, postId: null }
    keepers.value = []
    globalShortcutManager.unregisterAll('copilot-dock.')
    try { window.localStorage.removeItem('dashboard:copilot-dock') } catch { /* noop */ }
    // Reset the module-level shared signal so tests don't leak open state.
    const dock = useCopilotDock()
    dock.close()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    globalShortcutManager.unregisterAll('copilot-dock.')
    try { window.localStorage.removeItem('dashboard:copilot-dock') } catch { /* noop */ }
  })

  function DockHarness({ dock }: { dock: ReturnType<typeof useCopilotDock> }) {
    useCopilotDockShortcuts(dock)
    return h(CopilotDock, { dock })
  }

  function renderDock() {
    const dock = useCopilotDock()
    render(h(DockHarness, { dock }), container)
    return dock
  }

  it('renders closed by default and opens via top bar button', async () => {
    const dock = useCopilotDock()
    render(h(CopilotDockTopBarButton, { dock }), container)

    expect(dock.state.value.open).toBe(false)
    const btn = container.querySelector('[data-testid="copilot-dock-topbar-button"]')
    expect(btn).not.toBeNull()
    ;(btn as HTMLButtonElement).click()
    expect(dock.state.value.open).toBe(true)
  })

  it('renders floating FAB when closed', async () => {
    const dock = useCopilotDock()
    render(h(CopilotDockFab, { dock }), container)

    const fab = container.querySelector('[data-testid="copilot-dock-fab"]')
    expect(fab).not.toBeNull()
    ;(fab as HTMLButtonElement).click()
    expect(dock.state.value.open).toBe(true)
  })

  it('toggles open and close from the dock header', async () => {
    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock"]')).not.toBeNull())

    const closeBtn = container.querySelector('[title="닫기 (Esc)"]')
    expect(closeBtn).not.toBeNull()
    ;(closeBtn as HTMLButtonElement).click()
    expect(dock.state.value.open).toBe(false)
  })

  it('closes on Escape shortcut', async () => {
    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock"]')).not.toBeNull())

    await waitFor(() => expect(globalShortcutManager.getById('copilot-dock.close')).not.toBeUndefined())
    const shortcut = globalShortcutManager.getById('copilot-dock.close')!
    shortcut.action(new KeyboardEvent('keydown', { key: 'Escape' }))
    expect(dock.state.value.open).toBe(false)
  })

  it('opens on Cmd+J shortcut', async () => {
    const dock = renderDock()
    expect(dock.state.value.open).toBe(false)

    await waitFor(() => expect(globalShortcutManager.getById('copilot-dock.toggle')).not.toBeUndefined())
    const shortcut = globalShortcutManager.getById('copilot-dock.toggle')!
    expect(shortcut.chord.key).toBe('j')
    expect(shortcut.chord.modifiers).toContain('Mod')
    shortcut.action(new KeyboardEvent('keydown', { key: 'j', metaKey: true }))
    expect(dock.state.value.open).toBe(true)
  })

  it('persists open/state to localStorage', async () => {
    const dock = useCopilotDock()
    render(h(CopilotDock, { dock }), container)

    dock.open()
    dock.setMode('float')
    dock.setKeeper('nick0cave')

    await waitFor(() => {
      const raw = window.localStorage.getItem('dashboard:copilot-dock')
      expect(raw).not.toBeNull()
      const saved = JSON.parse(raw!)
      expect(saved.open).toBe(true)
      expect(saved.mode).toBe('float')
      expect(saved.keeperId).toBe('nick0cave')
    })
  })

  it('displays surface context for current route', () => {
    route.value = { tab: 'code', params: { section: 'ide-shell' }, postId: null }
    const ctx = getSurfaceContext()
    expect(ctx.route).toBe('/code/ide-shell')
    expect(ctx.label).toBe('IDE · round.ml')
    expect(ctx.fields.length).toBeGreaterThan(0)
  })

  it('updates surface context when route changes', async () => {
    route.value = { tab: 'connectors', params: { section: 'connector-status' }, postId: null }
    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock-coview"]')).not.toBeNull())

    const coview = container.querySelector('[data-testid="copilot-dock-coview"]')
    expect(coview?.textContent).toContain('커넥터 · Gate')
    expect(coview?.textContent).toContain('/connectors/connector-status')
  })

  it('sends a message and shows a streaming reply', async () => {
    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock-textarea"]')).not.toBeNull())

    const textarea = container.querySelector('[data-testid="copilot-dock-textarea"]') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: '요약해줘' } })

    const sendBtn = container.querySelector('.dock-send') as HTMLButtonElement
    sendBtn.click()

    await waitFor(() => expect(container.querySelectorAll('[data-dock-message="user"]').length).toBe(1))
    await waitFor(() => expect(container.querySelectorAll('[data-dock-message="assistant"]').length).toBe(1), { timeout: 3000 })
  })

  it('switches keeper via picker', async () => {
    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock-picker"]')).not.toBeNull())

    const picker = container.querySelector('[data-testid="copilot-dock-picker"]') as HTMLButtonElement
    picker.click()
    await waitFor(() => expect(container.querySelector('.dock-menu')).not.toBeNull())

    const rows = container.querySelectorAll('.dock-menu-row')
    expect(rows.length).toBeGreaterThan(1)
    ;(rows[1] as HTMLDivElement).click()

    expect(dock.state.value.keeperId).not.toBe('masc-improver')
  })
})
