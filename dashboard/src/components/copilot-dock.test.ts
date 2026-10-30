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
import { useKeyboardShortcutHost } from '../../design-system/headless-preact/use-keyboard-shortcut'

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
    useKeyboardShortcutHost(globalShortcutManager)
    useCopilotDockShortcuts(dock)
    return h(CopilotDock, { dock })
  }

  function renderDock() {
    const dock = useCopilotDock()
    render(h(DockHarness, { dock }), container)
    return dock
  }

  it.each([false, true])('lets an unrelated modal receive Escape with dock open=%s', async (open) => {
    const dock = renderDock()
    if (open) dock.open()
    await waitFor(() => expect(globalShortcutManager.getById('copilot-dock.toggle')).toBeDefined())
    const button = document.createElement('button')
    document.body.appendChild(button)
    const closeModal = vi.fn()
    window.addEventListener('keydown', closeModal)
    try {
      const event = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })
      fireEvent(button, event)
      expect(closeModal).toHaveBeenCalledTimes(1)
      expect(event.defaultPrevented).toBe(false)
      expect(dock.state.value.open).toBe(open)
    } finally {
      window.removeEventListener('keydown', closeModal)
      button.remove()
    }
  })

  it('closes the focused dock through the real shortcut host', async () => {
    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(globalShortcutManager.getById('copilot-dock.close')).toBeDefined())
    const button = container.querySelector('[data-testid="copilot-dock"] button') as HTMLButtonElement
    const event = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })
    fireEvent(button, event)
    expect(dock.state.value.open).toBe(false)
    expect(event.defaultPrevented).toBe(true)
  })

  it.each([{ isComposing: true }, { keyCode: 229 }, { defaultPrevented: true }])('keeps an owned or composing Escape out of the dock shortcut (%o)', async (flags) => {
    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(globalShortcutManager.getById('copilot-dock.close')).toBeDefined())
    const button = container.querySelector('[data-testid="copilot-dock"] button') as HTMLButtonElement
    const event = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true, ...flags })
    if ('defaultPrevented' in flags) event.preventDefault()
    fireEvent(button, event)
    expect(dock.state.value.open).toBe(true)
  })

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

  it('labels missing context as unobserved instead of fabricating zero percent', () => {
    keepers.value = [
      {
        name: 'rondo',
        keeper_id: 'rondo',
        status: 'running',
        phase: 'Running',
        runtime_id: 'fleet',
        context_ratio: null,
      },
    ] as unknown as typeof keepers.value
    route.value = { tab: 'keepers', params: {}, postId: null }

    const selected = getSurfaceContext('rondo')
    const fleet = getSurfaceContext()

    expect(selected.fields.find(field => field.k === 'ctx')).toEqual({
      k: 'ctx',
      v: '미관측',
      tone: undefined,
    })
    expect(fleet.fields.find(field => field.k === 'ctx')).toEqual({
      k: 'ctx',
      v: '미관측',
      tone: undefined,
    })
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

  const DEV_TOKEN_PATH = '/api/v1/dashboard/dev-token'

  /* `streamKeeperMessage` bootstraps the loopback dashboard credential before
     it builds the request (#28371), so the dock now issues a dev-token GET
     ahead of the keeper POST. A bare `mockResolvedValue(sseResponse(...))`
     breaks on both counts: the GET becomes call[0], and the single Response's
     body stream is consumed by whichever call reads it first, leaving the POST
     with nothing to parse. Route by URL and build a fresh Response per call. */
  function dockFetchMock(events: unknown[]) {
    return vi.fn(async (url: string, _init?: RequestInit) =>
      String(url).includes(DEV_TOKEN_PATH)
        ? new Response(
            JSON.stringify({ token: 'dock-dev-token', actor: 'dashboard', role: 'admin' }),
            { status: 200, headers: { 'Content-Type': 'application/json' } },
          )
        : sseResponse(events))
  }

  function keeperStreamCalls(mock: ReturnType<typeof dockFetchMock>) {
    return mock.mock.calls.filter(([url]) => !String(url).includes(DEV_TOKEN_PATH))
  }

  it('sends a message and shows a streaming reply', async () => {
    const fetchMock = dockFetchMock([
      { type: 'TEXT_MESSAGE_START', threadId: 'keeper-consumer:sangsu', timestamp: 1, role: 'assistant', messageId: 'm1' },
      { type: 'TEXT_MESSAGE_CONTENT', threadId: 'keeper-consumer:sangsu', timestamp: 2, messageId: 'm1', delta: '안녕하세요' },
      { type: 'TEXT_MESSAGE_END', threadId: 'keeper-consumer:sangsu', timestamp: 3, messageId: 'm1' },
      { type: 'RUN_FINISHED', threadId: 'keeper-consumer:sangsu', timestamp: 4, runId: 'run-1' },
    ])
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

    /* The streaming placeholder also carries `data-dock-message="assistant"`,
       so waiting for the element alone resolves on "작성 중…" — the settled
       reply only lands in the `.then` of `streamKeeperMessage`. Wait on the
       text the test is actually about. */
    await waitFor(
      () => expect(container.querySelector('[data-dock-message="assistant"]')?.textContent)
        .toContain('안녕하세요'),
      { timeout: 3000 },
    )
  })

  async function sendDockMessageAndReadReply(events: unknown[]): Promise<string> {
    vi.stubGlobal('fetch', dockFetchMock(events))
    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock-textarea"]')).not.toBeNull())
    const textarea = container.querySelector('[data-testid="copilot-dock-textarea"]') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: '요약해줘' } })
    const replies = () => Array.from(container.querySelectorAll('[data-dock-message="assistant"]'))
    const before = replies().length
    ;(container.querySelector('[aria-label="메시지 전송"]') as HTMLButtonElement).click()
    await waitFor(() => {
      expect(replies().length).toBeGreaterThan(before)
      expect(replies().some(reply => reply.textContent?.includes('작성 중'))).toBe(false)
    }, { timeout: 3000 })
    return replies().at(-1)?.textContent ?? ''
  }

  const dockContent = (timestamp: number, delta: unknown, extra: Record<string, unknown> = {}) => (
    { type: 'TEXT_MESSAGE_CONTENT', threadId: 'keeper-consumer:sangsu', timestamp, messageId: 'm1', delta, ...extra }
  )
  const dockFinished = { type: 'RUN_FINISHED', threadId: 'keeper-consumer:sangsu', timestamp: 9, runId: 'run-1' }

  it('drops a delayed delta from a superseded response', async () => {
    const reply = await sendDockMessageAndReadReply([
      dockContent(1, 'current', { textResponse: { content_generation: 5, stream_scope: 0 } }),
      dockContent(2, 'STALE', { textResponse: { content_generation: 4, stream_scope: 3 } }),
      dockFinished,
    ])
    expect(reply).toContain('current')
    expect(reply).not.toContain('STALE')
  })

  const dockCustom = (timestamp: number, name: string, value: unknown) => (
    { type: 'CUSTOM', threadId: 'keeper-consumer:sangsu', timestamp, runId: 'run-1', name, value }
  )
  const dockOwner = (generation: number) => ({ content_generation: generation, stream_scope: 0 })

  it('refuses a delayed delta of an older response after a newer header', async () => {
    const reply = await sendDockMessageAndReadReply([
      dockContent(1, 'second', { textResponse: dockOwner(2) }),
      dockCustom(2, 'KEEPER_STREAM_MESSAGE_START', { ...dockOwner(3), provider_message_id: '', model: '' }),
      dockContent(3, 'LATE-FROM-2', { textResponse: dockOwner(2) }),
      dockContent(4, 'third', { textResponse: dockOwner(3) }),
      dockFinished,
    ])
    expect(reply).toContain('secondthird')
    expect(reply).not.toContain('LATE-FROM-2')
  })

  it('refuses a delta of a response after its stop', async () => {
    const reply = await sendDockMessageAndReadReply([
      dockContent(1, 'done', { textResponse: dockOwner(2) }),
      dockCustom(2, 'KEEPER_STREAM_MESSAGE_STOP', dockOwner(2)),
      dockContent(3, 'AFTER-STOP', { textResponse: dockOwner(2) }),
      dockFinished,
    ])
    expect(reply).toContain('done')
    expect(reply).not.toContain('AFTER-STOP')
  })

  it('refuses a delta older than an observed content-activity generation', async () => {
    const reply = await sendDockMessageAndReadReply([
      dockContent(1, 'three', { textResponse: dockOwner(3) }),
      dockCustom(2, 'KEEPER_MODEL_CONTENT_ACTIVITY', { generation: 4, stream_scope: 0, block_index: 0, channel: 'text', state: 'observed' }),
      dockContent(3, 'LATE-FROM-3', { textResponse: dockOwner(3) }),
      dockFinished,
    ])
    expect(reply).toContain('three')
    expect(reply).not.toContain('LATE-FROM-3')
  })

  it('does not present a reply with a dropped frame as complete', async () => {
    const reply = await sendDockMessageAndReadReply([
      dockContent(1, 'first half'),
      dockContent(2, 42),
      dockContent(3, 'second half'),
      dockFinished,
    ])
    expect(reply).toContain('first halfsecond half')
    const note = container.querySelector('[data-dock-incomplete]')
    expect(note?.getAttribute('data-dock-incomplete')).toBe('A Keeper stream frame does not match the protocol.')
  })

  it('posts copilot channel and surface context to the keeper stream', async () => {
    window.history.replaceState({}, '', '/?agent=dashboard-eager-manta')
    const fetchMock = dockFetchMock([{ type: 'RUN_FINISHED' }])
    vi.stubGlobal('fetch', fetchMock)

    const dock = renderDock()
    dock.open()
    await waitFor(() => expect(container.querySelector('[data-testid="copilot-dock-textarea"]')).not.toBeNull())

    const textarea = container.querySelector('[data-testid="copilot-dock-textarea"]') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: '요약해줘' } })

    const sendBtn = container.querySelector('[aria-label="메시지 전송"]') as HTMLButtonElement
    sendBtn.click()

    await waitFor(() => expect(keeperStreamCalls(fetchMock)).toHaveLength(1))
    const [, init] = keeperStreamCalls(fetchMock)[0] as [string, RequestInit]
    const body = JSON.parse(String(init.body))
    expect(body.channel).toBe('copilot')
    /* The `?agent=` query is a hint, and a managed dev-token credential
       outranks it (#28334). `currentDashboardActor` returns the stored dev
       token's actor whenever one exists and only falls back to the URL name
       otherwise, so once the dock bootstraps a credential (#28371) the hint
       must not reach the wire. Keeping the query in the URL pins that
       precedence rather than asserting a value the hint no longer decides. */
    expect(body.channel_workspace_id).toBe('dashboard')
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
