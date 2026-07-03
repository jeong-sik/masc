// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { waitFor, fireEvent } from '@testing-library/preact'
import {
  CopilotDock,
  CopilotDockFab,
  CopilotDockTopBarButton,
  getSurfaceContext,
  starterPromptsForContext,
  useCopilotDock,
  useCopilotDockShortcuts,
} from './copilot-dock'
import { route } from '../router'
import { keepers } from '../store'
import { globalShortcutManager } from '../lib/global-shortcut-manager'

describe('CopilotDock', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    window.innerWidth = 1280
    window.dispatchEvent(new Event('resize'))
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
    vi.unstubAllGlobals()
    vi.clearAllMocks()
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
    expect(btn?.classList.contains('v2-shell-action')).toBe(true)
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

    expect(container.querySelector('.v2-shell-surface')).not.toBeNull()

    const closeBtn = container.querySelector('[title="닫기 (Esc)"]')
    expect(closeBtn).not.toBeNull()
    ;(closeBtn as HTMLButtonElement).click()
    expect(dock.state.value.open).toBe(false)
  })

  it('forces a full docked panel on mobile even when float mode was persisted', async () => {
    window.innerWidth = 390
    window.dispatchEvent(new Event('resize'))
    const dock = renderDock()
    dock.setMode('float')
    dock.open()

    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock"]')).not.toBeNull())

    const panel = container.querySelector('[data-testid="copilot-dock"]') as HTMLElement
    expect(panel.classList.contains('docked')).toBe(true)
    expect(panel.classList.contains('float')).toBe(false)
    expect(panel.getAttribute('data-mobile-docked')).toBe('true')
    expect(container.querySelector('[title="플로팅으로 띄우기"]')).toBeNull()
    expect(container.querySelector('[title="오른쪽에 도킹"]')).toBeNull()
    expect(container.querySelector('[title="닫기 (Esc)"]')).not.toBeNull()
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
    expect(ctx.label).toBe('IDE')
    expect(ctx.fields.length).toBe(0)
  })

  it('labels the dedicated schedule surface for co-view context', () => {
    route.value = { tab: 'schedule', params: {}, postId: null }
    const ctx = getSurfaceContext()
    expect(ctx.route).toBe('/schedule')
    expect(ctx.label).toBe('Schedule')
    expect(ctx.scene).toBe('예약 자동화와 wake signal을 함께 보는 중')
  })

  it('uses selected backed keeper context for the Keepers surface', () => {
    keepers.value = [
      { name: 'masc-improver', keeper_id: 'masc-improver', koreanName: 'MASC Improver', status: 'running', phase: 'Running', runtime_id: 'fleet', needs_attention: true, total_turns: 12, context_ratio: 0.8 },
      { name: 'nick0cave', keeper_id: 'nick0cave', koreanName: 'nick0cave', status: 'idle', phase: 'Idle', runtime_id: 'ops', needs_attention: false, total_turns: 8, context_ratio: 0.3 },
    ] as unknown as typeof keepers.value
    route.value = { tab: 'keepers', params: {}, postId: null }

    const ctx = getSurfaceContext('masc-improver')

    expect(ctx.label).toBe('Keepers')
    expect(ctx.route).toBe('/keepers')
    expect(ctx.scene).toBe('MASC Improver와 1:1 스레드')
    expect(ctx.fields).toEqual([
      { k: 'state', v: 'Running' },
      { k: 'ctx', v: '80%', tone: 'volt' },
      { k: 'ns', v: 'fleet' },
    ])
  })

  it('keeps backed fleet context as the Keepers fallback when no keeper is selected', () => {
    keepers.value = [
      { name: 'masc-improver', keeper_id: 'masc-improver', koreanName: 'MASC Improver', status: 'running', phase: 'Running', runtime_id: 'fleet', needs_attention: true, total_turns: 12, context_ratio: 0.8 },
      { name: 'nick0cave', keeper_id: 'nick0cave', koreanName: 'nick0cave', status: 'idle', phase: 'Idle', runtime_id: 'ops', needs_attention: false, total_turns: 8, context_ratio: 0.3 },
    ] as unknown as typeof keepers.value
    route.value = { tab: 'keepers', params: {}, postId: null }

    const ctx = getSurfaceContext()

    expect(ctx.label).toBe('Keepers')
    expect(ctx.route).toBe('/keepers')
    expect(ctx.scene).toBe('Keeper workspace를 함께 보는 중')
    expect(ctx.fields).toEqual([
      { k: '실행', v: '1/2' },
      { k: '주의', v: '1', tone: 'bad' },
      { k: 'ctx', v: '55%', tone: 'volt' },
      { k: 'trace', v: '20' },
    ])
  })

  it('uses route-specific starter prompts with a generic fallback', () => {
    expect(starterPromptsForContext({ route: '/schedule' })).toEqual([
      '승인 차단 예약 정리',
      '다음 due 항목 요약',
      'wake signal 이상 징후',
    ])
    expect(starterPromptsForContext({ route: '/schedule/active?filter=due' })).toEqual([
      '승인 차단 예약 정리',
      '다음 due 항목 요약',
      'wake signal 이상 징후',
    ])
    expect(starterPromptsForContext({ route: '/unknown' })).toEqual([
      '이 화면 요약해줘',
      '다음 액션 추천',
      '주의 항목 정리해줘',
    ])
  })

  it('renders route-specific starter buttons in the empty dock', async () => {
    route.value = { tab: 'schedule', params: {}, postId: null }
    const dock = renderDock()
    dock.open()

    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock"]')).not.toBeNull())

    const starters = Array.from(container.querySelectorAll('[data-dock-starter]')).map(el => el.textContent)
    expect(starters).toEqual([
      '›승인 차단 예약 정리',
      '›다음 due 항목 요약',
      '›wake signal 이상 징후',
    ])
  })

  it('renders normalized dock field tone classes', async () => {
    keepers.value = [
      { name: 'masc-improver', keeper_id: 'masc-improver', koreanName: 'MASC Improver', status: 'running', phase: 'Running', runtime_id: 'fleet', needs_attention: true, total_turns: 3, context_ratio: 0.9 },
    ] as unknown as typeof keepers.value
    route.value = { tab: 'overview', params: {}, postId: null }

    const dock = renderDock()
    dock.open()

    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock-coview"]')).not.toBeNull())
    expect(container.querySelector('.dock-field.bad')?.textContent).toContain('주의1')
    expect(container.querySelector('.dock-field.warn')?.textContent).toContain('ctx90%')
  })

  it('updates surface context when route changes', async () => {
    route.value = { tab: 'connectors', params: { section: 'connector-status' }, postId: null }
    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock-coview"]')).not.toBeNull())

    const coview = container.querySelector('[data-testid="copilot-dock-coview"]')
    expect(coview?.textContent).toContain('Connectors')
    expect(coview?.textContent).toContain('/connectors/connector-status')
  })

  function sseResponse(events: unknown[]) {
    const encoder = new TextEncoder()
    const payload = events
      .map(e => `data: ${JSON.stringify(e)}\n\n`)
      .join('')
    return new Response(
      new ReadableStream({
        start(controller) {
          controller.enqueue(encoder.encode(payload))
          controller.close()
        },
      }),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    )
  }

  it('sends a message and shows a streaming reply', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      sseResponse([
        { type: 'TEXT_MESSAGE_START', role: 'Assistant', messageId: 'm1' },
        { type: 'TEXT_MESSAGE_CONTENT', delta: '안녕하세요' },
        { type: 'TEXT_MESSAGE_END' },
        { type: 'RUN_FINISHED' },
      ]),
    )
    vi.stubGlobal('fetch', fetchMock)

    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock-textarea"]')).not.toBeNull())

    const textarea = container.querySelector('[data-testid="copilot-dock-textarea"]') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: '요약해줘' } })

    const sendBtn = container.querySelector('[aria-label="메시지 전송"]') as HTMLButtonElement
    expect(sendBtn?.classList.contains('dock-send')).toBe(true)
    sendBtn.click()

    await waitFor(() => expect(container.querySelectorAll('[data-dock-message="user"]').length).toBe(1))
    await waitFor(() => expect(container.querySelectorAll('[data-dock-message="assistant"]').length).toBe(1), { timeout: 3000 })

    const assistant = container.querySelector('[data-dock-message="assistant"]')
    expect(assistant?.textContent).toContain('안녕하세요')
  })

  it('posts copilot channel and surface context to the keeper stream', async () => {
    window.history.replaceState({}, '', '/?agent=dashboard-eager-manta')
    const fetchMock = vi.fn().mockResolvedValue(
      sseResponse([{ type: 'RUN_FINISHED' }]),
    )
    vi.stubGlobal('fetch', fetchMock)

    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock-textarea"]')).not.toBeNull())

    const textarea = container.querySelector('[data-testid="copilot-dock-textarea"]') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: '요약해줘' } })

    const sendBtn = container.querySelector('[aria-label="메시지 전송"]') as HTMLButtonElement
    sendBtn.click()

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(String(init.body))
    expect(body.channel).toBe('copilot')
    expect(body.channel_workspace_id).toBe('dashboard-eager-manta')
    expect(body.surface_context).toMatchObject({
      label: expect.any(String),
      route: '/overview',
      scene: expect.any(String),
      fields: expect.any(Array),
    })
  })

  it('switches keeper via picker', async () => {
    keepers.value = [
      { name: 'masc-improver', keeper_id: 'masc-improver', koreanName: 'MASC Improver', status: 'running', phase: 'Running', runtime_id: 'fleet', needs_attention: false, total_turns: 0, context_ratio: 0.2 },
      { name: 'nick0cave', keeper_id: 'nick0cave', koreanName: 'nick0cave', status: 'running', phase: 'Running', runtime_id: 'ops', needs_attention: false, total_turns: 0, context_ratio: 0.3 },
    ] as unknown as typeof keepers.value
    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock-picker"]')).not.toBeNull())

    const picker = container.querySelector('[data-testid="copilot-dock-picker"]') as HTMLButtonElement
    picker.click()
    await waitFor(() => expect(container.querySelector('.dock-menu')).not.toBeNull())

    const rows = container.querySelectorAll('.dock-menu-row')
    expect(rows.length).toBeGreaterThan(1)
    // a11y (audit #6): rows are keyboard-operable native <button>s with an
    // accessible name; the current keeper row is marked aria-current.
    rows.forEach(r => expect(r.tagName).toBe('BUTTON'))
    expect((rows[0] as HTMLButtonElement).getAttribute('aria-label')).toContain('전환')
    const onRow = container.querySelector('.dock-menu-row.on')
    if (onRow) expect(onRow.getAttribute('aria-current')).toBe('true')
    ;(rows[1] as HTMLButtonElement).click()

    expect(dock.state.value.keeperId).not.toBe('masc-improver')
  })

  it('drops the runtime namespace from the keeper picker sub and conversation hint', async () => {
    keepers.value = [
      { name: 'masc-improver', keeper_id: 'masc-improver', koreanName: 'MASC Improver', status: 'running', phase: 'Running', runtime_id: 'fleet', needs_attention: false, total_turns: 0, context_ratio: 0.2 },
      { name: 'nick0cave', keeper_id: 'nick0cave', koreanName: 'nick0cave', status: 'running', phase: 'Running', runtime_id: 'ops', needs_attention: false, total_turns: 0, context_ratio: 0.3 },
    ] as unknown as typeof keepers.value
    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock-picker"]')).not.toBeNull())

    // conversation hint no longer trails the runtime alias ("· <ns>")
    const hint = container.querySelector('.dock-idrow-hint') as HTMLElement
    expect(hint.textContent).toContain('와 대화 중')
    expect(hint.textContent).not.toContain('·')
    expect(hint.textContent).not.toContain('fleet')
    expect(hint.textContent).not.toContain('ops')

    // picker rows show the phase only, not "phase · ns"
    const picker = container.querySelector('[data-testid="copilot-dock-picker"]') as HTMLButtonElement
    picker.click()
    await waitFor(() => expect(container.querySelector('.dock-menu')).not.toBeNull())
    const subs = Array.from(container.querySelectorAll('.dock-menu-row .sub')).map(s => s.textContent ?? '')
    expect(subs.length).toBeGreaterThan(0)
    subs.forEach(s => {
      expect(s).toContain('Running')
      expect(s).not.toContain('·')
      expect(s).not.toContain('fleet')
      expect(s).not.toContain('ops')
    })
  })
})
