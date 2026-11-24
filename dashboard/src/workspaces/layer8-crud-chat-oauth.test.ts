// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  authSession,
  extractDeviceCode,
  extractOAuthUrl,
  releaseAllViewStreams,
  resetAuthStateForTests,
  resetObserverStateForTests,
  resourceCache,
  stripAnsi,
} from '../core'
import {
  buildLaneUnifiedDiff,
  deleteLaneFromToml,
  parseLanesFromToml,
  reorderCandidate,
  upsertLaneInToml,
} from './runtime/lane-toml-editor'
import { RuntimeWorkspace } from './runtime/index'
import {
  parseChatMessageBlocks,
  shouldRenderChatEntry,
  DEFAULT_CHAT_BLOCK_PREFS,
} from './keepers/chat-blocks'
import { KeeperChatTab } from './keepers/keeper-chat-tab'
import { KeeperConfigTab } from './keepers/keeper-config-tab'
import type { ChatTranscriptEntry, KeeperRosterItem } from './keepers/types'
import { AccountWorkspace } from './account/index'

vi.mock('uplot', () => {
  class MockUPlot {
    width = 480
    constructor(_opts: unknown, _data: unknown, mount?: HTMLElement) {
      if (mount) {
        const el = document.createElement('div')
        el.className = 'uplot-mock'
        mount.appendChild(el)
      }
    }
    setData(): void {}
    setSize(): void {}
    destroy(): void {}
    static sync(key: string) {
      return { key }
    }
  }
  return { default: MockUPlot }
})

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function sseResponse(events: readonly { event: string; data: unknown }[]): Response {
  const payload = events
    .map((e) => `event: ${e.event}\ndata: ${JSON.stringify(e.data)}\n\n`)
    .join('')
  return new Response(payload, {
    status: 200,
    headers: { 'Content-Type': 'text/event-stream' },
  })
}

async function flushUi(ms = 35): Promise<void> {
  await new Promise((r) => setTimeout(r, ms))
}

function makeKeeper(name = 'code-reviewer-sister'): KeeperRosterItem {
  return {
    name,
    status: 'running',
    phase: 'idle',
    health: 'healthy',
    paused: false,
    keepalive_running: true,
    activation_mode: 'autonomous',
    runtime_id: 'claude-code',
    sandbox_profile: 'microvm',
    company: 'code',
    context_ratio: 0.42,
    context_tokens: 84_000,
    context_max: 200_000,
    context_unavailable_reason: null,
    runtime_blocker_summary: null,
    last_failure: null,
    directory_issue: null,
    turns_24h: 12,
    candle_balance_milli: '5000',
    portrait_equipment: {
      face: 'glasses',
      neck: 'bare_neck',
      head: 'crown',
      hand: 'empty_hand',
      base: 'no_dish',
    },
    chat_control_token: 'ctrl-1',
    active_turn: null,
  }
}

const SAMPLE_RUNTIME_TOML = `[runtime]
default = "coding"

[runtime.lanes.coding]
candidates = [
  "ollama_cloud.deepseek-flash",
  "deepseek.deepseek-pro",
]

[runtime.exact_output_lanes.verifier_exact]
slots = ["glm-coding.glm-5", "ollama_cloud.deepseek-flash"]
max_output_tokens = 8192
`

describe('Layer 8 — Visual Lane CRUD, Chat 3-Block Toggles & Zero-Manual Web OAuth', () => {
  let container: HTMLDivElement
  let originalFetch: typeof globalThis.fetch

  beforeEach(() => {
    originalFetch = globalThis.fetch
    resetAuthStateForTests()
    resetObserverStateForTests()
    releaseAllViewStreams()
    resourceCache.clearAll()
    window.localStorage.clear()
    vi.spyOn(HTMLElement.prototype, 'clientHeight', 'get').mockReturnValue(420)
    vi.spyOn(HTMLElement.prototype, 'clientWidth', 'get').mockReturnValue(900)
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    releaseAllViewStreams()
    resourceCache.clearAll()
    globalThis.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('(A) Visual Runtime Lane CRUD parses, creates, reorders, previews via /raw/preview, CAS-saves via /raw, and deletes cleanly', async () => {
    // 1. Pure TOML lane engine checks
    const parsed = parseLanesFromToml(SAMPLE_RUNTIME_TOML)
    expect(parsed).toEqual([
      { kind: 'failover', id: 'coding', candidates: ['ollama_cloud.deepseek-flash', 'deepseek.deepseek-pro'] },
      { kind: 'exact_output', id: 'verifier_exact', candidates: ['glm-coding.glm-5', 'ollama_cloud.deepseek-flash'], maxOutputTokens: 8192, enabled: undefined },
    ])
    expect(reorderCandidate(['a', 'b', 'c'], 1, 'up')).toEqual(['b', 'a', 'c'])
    expect(reorderCandidate(['a', 'b', 'c'], 1, 'down')).toEqual(['a', 'c', 'b'])

    const created = upsertLaneInToml(SAMPLE_RUNTIME_TOML, {
      kind: 'failover',
      id: 'fast-lane',
      candidates: ['deepseek.deepseek-pro', 'ollama_cloud.deepseek-flash'],
    })
    expect(created.ok).toBe(true)
    if (created.ok) {
      expect(created.value).toContain('[runtime.lanes.fast-lane]')
      expect(buildLaneUnifiedDiff(SAMPLE_RUNTIME_TOML, created.value)).toContain('+[runtime.lanes.fast-lane]')
      const removed = deleteLaneFromToml(created.value, 'failover', 'fast-lane')
      expect(removed.ok).toBe(true)
      if (removed.ok) {
        expect(removed.value).not.toContain('[runtime.lanes.fast-lane]')
        expect(removed.value).toContain('[runtime.lanes.coding]')
      }
    }

    // 2. Full UI round-trip on 5 Runtime > Lanes
    const shaRev = 'a'.repeat(64)
    const previewBodies: unknown[] = []
    const saveBodies: unknown[] = []

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url === '/api/v1/runtime/resolved') {
        return jsonResponse({
          default_route: 'coding',
          default_runtime: { id: 'ollama_cloud.deepseek-flash' },
          lanes: [{ id: 'coding', runtime_ids: ['ollama_cloud.deepseek-flash', 'deepseek.deepseek-pro'] }],
          runtimes: [
            { id: 'ollama_cloud.deepseek-flash', provider: 'ollama_cloud', model: 'deepseek-flash' },
            { id: 'deepseek.deepseek-pro', provider: 'deepseek', model: 'deepseek-pro' },
          ],
          assignments: [],
        })
      }
      if (url.startsWith('/api/v1/dashboard/runtime-probe')) {
        return jsonResponse({ refresh_state: 'fresh', cache_hit: true, probe: { providers: [] } })
      }
      if (url === '/api/v1/runtime/config/raw' && (!init?.method || init.method === 'GET')) {
        return jsonResponse({
          ok: true,
          source_revision: shaRev,
          path: '/ws/masc/.masc/runtime.toml',
          source_text: SAMPLE_RUNTIME_TOML,
        })
      }
      if (url === '/api/v1/runtime/config/raw/preview' && init?.method === 'POST') {
        previewBodies.push(JSON.parse(String(init.body)))
        return jsonResponse({ ok: true, can_save: true, runtime_validation: null })
      }
      if (url === '/api/v1/runtime/config/raw' && init?.method === 'POST') {
        saveBodies.push(JSON.parse(String(init.body)))
        return jsonResponse({ ok: true, state: 'committed' })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${RuntimeWorkspace} subroute="lanes" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(50)

    expect(container.querySelector('[data-lane-row="failover:coding"]')).not.toBeNull()
    expect(container.querySelector('[data-lane-row="exact_output:verifier_exact"]')).not.toBeNull()

    // Edit 'coding' lane -> move second candidate UP -> Preview Diff -> CAS Save
    const editBtn = container.querySelector('[data-lane-row="failover:coding"] button') as HTMLButtonElement
    editBtn.click()
    await flushUi(20)

    const moveUpBtn = container.querySelector('button[aria-label="deepseek.deepseek-pro 위로 이동"]') as HTMLButtonElement
    expect(moveUpBtn).not.toBeNull()
    moveUpBtn.click()
    await flushUi(20)

    const previewBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('Diff 미리보기'),
    ) as HTMLButtonElement
    previewBtn.click()
    await flushUi(40)

    expect(previewBodies).toHaveLength(1)
    const diffBox = container.querySelector('[data-testid="lane-diff-preview"]')
    expect(diffBox).not.toBeNull()
    expect(diffBox!.textContent).toContain('deepseek.deepseek-pro')

    const applyBtn = [...diffBox!.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('변경 적용 (CAS Save)'),
    ) as HTMLButtonElement
    applyBtn.click()
    await flushUi(40)

    expect(saveBodies).toHaveLength(1)
    expect(saveBodies[0]).toMatchObject({
      expected_source_revision: shaRev,
      expected_source_path: '/ws/masc/.masc/runtime.toml',
    })
    const savedToml = String((saveBodies[0] as { source_text: string }).source_text)
    expect(parseLanesFromToml(savedToml)[0]!.candidates).toEqual([
      'deepseek.deepseek-pro',
      'ollama_cloud.deepseek-flash',
    ])
  })

  it('(B) Chat 3-block toggles (Alt+T Thinking, Tools summary/full/hidden, Memory & Autonomous hidden/shown) render structured collapsible cards', async () => {
    const rawToolMsg: ChatTranscriptEntry = {
      id: 'm-tool',
      role: 'tool',
      toolName: 'masc_search',
      content: JSON.stringify({ tool_name: 'masc_search', args: { query: 'oauth' }, result: { hits: 3 } }),
      ts: 100,
    }
    const parsedTool = parseChatMessageBlocks(rawToolMsg)
    expect(parsedTool.toolBlocks).toHaveLength(1)
    expect(parsedTool.toolBlocks[0]!.name).toBe('masc_search')
    expect(shouldRenderChatEntry(rawToolMsg, parsedTool, { ...DEFAULT_CHAT_BLOCK_PREFS, tools: 'hidden' })).toBe(false)

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/chat/history/page')) {
        return jsonResponse({
          has_more: false,
          next_cursor: null,
          messages: [
            {
              id: 'm-1',
              role: 'assistant',
              content: '<thinking>Checking OAuth routes carefully</thinking>Done checking routes.',
              tool_calls: [{ id: 'tc-1', name: 'rg_search', args: { pattern: 'oauth' }, result: '3 matches', status: 'ok' }],
              ts: 100,
            },
            {
              id: 'm-mem',
              role: 'system',
              kind: 'memory_recall',
              memory_recall: [{ claim: 'MASC runs on port 8935' }],
              content: '',
              ts: 101,
            },
            {
              id: 'm-auto',
              role: 'assistant',
              turn_kind: 'autonomous',
              content: JSON.stringify({ autonomous: true, summary: 'Patrolled open PRs', checked: 4 }),
              ts: 102,
            },
          ],
        })
      }
      if (url.includes('/chat/operations')) return jsonResponse({ operations: [] })
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${KeeperChatTab} keeper=${makeKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
      container,
    )
    await flushUi(50)

    // Defaults: Thinking collapsed (present, open=false), Tools summary (present, open=false), Memory/Autonomous hidden
    const thinkingCard = container.querySelector('[data-testid="chat-thinking-card"]') as HTMLDetailsElement
    expect(thinkingCard).not.toBeNull()
    expect(thinkingCard.open).toBe(false)
    expect(container.querySelector('[data-testid="chat-tool-card"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="chat-memory-card"]')).toBeNull()
    expect(container.querySelector('[data-testid="chat-autonomous-card"]')).toBeNull()
    // Toolbar shows hidden internal count (2)
    expect(container.querySelector('[data-testid="chat-toggle-internal"]')!.textContent).toContain('(2)')

    // Alt+T cycles Thinking: collapsed -> expanded -> hidden
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 't', altKey: true, bubbles: true }))
    await flushUi(20)
    expect((container.querySelector('[data-testid="chat-thinking-card"]') as HTMLDetailsElement).open).toBe(true)

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 't', altKey: true, bubbles: true }))
    await flushUi(20)
    expect(container.querySelector('[data-testid="chat-thinking-card"]')).toBeNull()

    // Cycle Tools toggle: summary -> full (open=true) -> hidden (removed)
    const toolsBtn = container.querySelector('[data-testid="chat-toggle-tools"]') as HTMLButtonElement
    toolsBtn.click()
    await flushUi(20)
    expect((container.querySelector('[data-testid="chat-tool-card"]') as HTMLDetailsElement).open).toBe(true)
    toolsBtn.click()
    await flushUi(20)
    expect(container.querySelector('[data-testid="chat-tool-card"]')).toBeNull()

    // Toggle Memory/Internal: hidden -> shown reveals structured cards (not raw JSON dump!)
    const internalBtn = container.querySelector('[data-testid="chat-toggle-internal"]') as HTMLButtonElement
    internalBtn.click()
    await flushUi(20)
    expect(container.querySelector('[data-testid="chat-memory-card"]')!.textContent).toContain('MASC runs on port 8935')
    expect(container.querySelector('[data-testid="chat-autonomous-card"]')!.textContent).toContain('Patrolled open PRs')
  })

  it('(C-1) Provider CLI OAuth reads SSE stream, auto-opens extracted URL, surfaces device code + /input prompt, and auto-verifies on complete', async () => {
    expect(stripAnsi('\x1b[32mhttps://auth.openai.com/device\x1b[0m')).toBe('https://auth.openai.com/device')
    expect(extractOAuthUrl('Visit \x1b[4mhttps://auth.openai.com/authorize?state=123\x1b[0m to continue.')).toBe(
      'https://auth.openai.com/authorize?state=123',
    )
    expect(extractDeviceCode('Enter one-time code: ABCD-1234 now')).toBe('ABCD-1234')

    const openedUrls: string[] = []
    vi.spyOn(window, 'open').mockImplementation((url) => {
      openedUrls.push(String(url))
      return { closed: false, close: vi.fn(), location: { href: '' } } as unknown as Window
    })

    const inputBodies: unknown[] = []
    const verifyBodies: unknown[] = []
    let releaseStream!: () => void
    const streamGate = new Promise<void>((r) => { releaseStream = r })

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url === '/api/v1/dashboard/provider-usage') return jsonResponse({ scopes: [] })
      if (url.startsWith('/api/v1/dashboard/provider-usage-history')) return jsonResponse({ state: 'unavailable', reason: 'none' })
      if (url === '/api/v1/runtime/resolved') {
        return jsonResponse({ default_route: 'default', runtimes: [{ id: 'codex.gpt-5', provider: 'codex_subscription', model: 'gpt-5-codex' }], lanes: [], assignments: [] })
      }
      if (url === '/api/v1/setup/inventory') {
        return jsonResponse({
          integrations: [{ id: 'codex_subscription', display_name: 'Codex Subscription', enabled: true, credential_kind: 'login' }],
        })
      }
      if (url === '/api/v1/runtime/config/raw') {
        return jsonResponse({ source_revision: 'b'.repeat(64) })
      }
      if (url === '/api/v1/setup/accounts/login' && init?.method === 'POST') {
        const encoder = new TextEncoder()
        const stream = new ReadableStream<Uint8Array>({
          async start(controller) {
            controller.enqueue(encoder.encode(
              `event: started\ndata: ${JSON.stringify({ login_id: 'login-77', integration_id: 'codex_subscription', status: 'running' })}\n\n`
              + `event: output\ndata: ${JSON.stringify({ stream: 'stdout', text: '\x1b[36mOpen https://auth.openai.com/device and enter code WXYZ-9876\x1b[0m\n' })}\n\n`
              + `event: input_ready\ndata: {}\n\n`,
            ))
            await streamGate
            controller.enqueue(encoder.encode(
              `event: complete\ndata: ${JSON.stringify({ login_id: 'login-77', integration_id: 'codex_subscription', status: 'complete', account_ref: 'acct-ref-77' })}\n\n`,
            ))
            controller.close()
          },
        })
        return new Response(stream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } })
      }
      if (url === '/api/v1/setup/accounts/login/login-77/input' && init?.method === 'POST') {
        inputBodies.push(JSON.parse(String(init.body)))
        releaseStream()
        return jsonResponse({ accepted: true }, 202)
      }
      if (url === '/api/v1/setup/accounts/verify' && init?.method === 'POST') {
        verifyBodies.push(JSON.parse(String(init.body)))
        return jsonResponse({ ok: true })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${RuntimeWorkspace} subroute="quotas" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(50)

    const cliOAuthBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.trim() === 'CLI OAuth',
    ) as HTMLButtonElement
    expect(cliOAuthBtn).toBeDefined()
    cliOAuthBtn.click()
    await flushUi(50)

    expect(openedUrls).toEqual(['https://auth.openai.com/device'])
    expect(container.querySelector('[data-testid="setup-login-device-code"]')!.textContent).toBe('WXYZ-9876')

    const inputEl = container.querySelector('input[aria-label="CLI 로그인 응답 입력"]') as HTMLInputElement
    expect(inputEl).not.toBeNull()
    inputEl.value = 'paste-code-42'
    inputEl.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi(15)
    const sendBtn = container.querySelector('[data-testid="setup-login-input-form"] button[type="submit"]') as HTMLButtonElement
    sendBtn.click()
    await flushUi(60)

    expect(inputBodies).toEqual([{ kind: 'text', text: 'paste-code-42' }])
    expect(verifyBodies).toEqual([{ provider_account_id: 'acct-ref-77', model: 'gpt-5-codex' }])
  })

  it('(C-2 & C-3) Keeper OAuth uses real Keeper selector, synchronous popup + postMessage/poll auto-refresh, GitHub device SSE, oauth/client drawer, and Account return_to', async () => {
    const popupMock = { closed: false, close: vi.fn(), location: { href: '' } }
    vi.spyOn(window, 'open').mockImplementation(() => popupMock as unknown as Window)

    const clientBodies: unknown[] = []
    let attachedSlack = false
    let githubStreamCalled = false

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.startsWith('/api/v1/tool-metrics/series')) {
        return jsonResponse({
          buckets: [],
          total: { call_count: 0, failure_count: 0, failure_rate: 0, p95_ms: null },
        })
      }
      if (url === '/api/v1/dashboard/tools') return jsonResponse({ tools: [] })
      if (url === '/api/v1/dashboard/shell') {
        return jsonResponse({ keepers: [{ name: 'sangsu' }, { name: 'code-reviewer-sister' }] })
      }
      if (url.startsWith('/api/v1/keepers/oauth/attached-tools')) {
        return jsonResponse({
          keeper: 'sangsu',
          callback: { url: 'http://127.0.0.1:8935/oauth/callback' },
          providers: [
            { provider: 'slack', provider_label: 'Slack', attached: attachedSlack, enabled: true, tools: attachedSlack ? ['slack_post'] : [] },
            { provider: 'github', provider_label: 'GitHub', attached: false },
          ],
        })
      }
      if (url === '/api/v1/keepers/sangsu/oauth-login' && init?.method === 'POST') {
        return jsonResponse({
          keeper: 'sangsu',
          provider: 'slack',
          provider_label: 'Slack',
          authorize_url: 'https://slack.com/oauth/v2/authorize?state=st-1',
          attempt_id: 'att-1',
        })
      }
      if (url === '/api/v1/keepers/sangsu/github-login' && init?.method === 'POST') {
        githubStreamCalled = true
        return sseResponse([
          { event: 'output', data: { stream: 'stdout', text: 'Open https://github.com/login/device and enter code GHAB-5678\n' } },
        ])
      }
      if (url === '/api/v1/keepers/oauth/client' && init?.method === 'POST') {
        clientBodies.push(JSON.parse(String(init.body)))
        return jsonResponse({ ok: true })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${RuntimeWorkspace} subroute="tools" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(40)

    const oauthTab = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('Keeper OAuth'),
    ) as HTMLButtonElement
    oauthTab.click()
    await flushUi(50)

    // Real keeper selector populated with 'sangsu' (NEVER hardcoded 'default'!)
    const keeperSelect = container.querySelector('select[aria-label="OAuth 대상 Keeper"]') as HTMLSelectElement
    expect(keeperSelect).not.toBeNull()
    expect(keeperSelect.value).toBe('sangsu')

    // Guided Custom OAuth App drawer shows callback URL and POSTs /api/v1/keepers/oauth/client
    const appSetupBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.trim() === '앱 설정',
    ) as HTMLButtonElement
    appSetupBtn.click()
    await flushUi(20)
    const clientForm = container.querySelector('[data-testid="tools-oauth-client-form"]')!
    expect(clientForm.textContent).toContain('http://127.0.0.1:8935/oauth/callback')
    const clientIdInput = clientForm.querySelector('input[aria-label="OAuth Client ID"]') as HTMLInputElement
    clientIdInput.value = 'my-slack-client-id'
    clientIdInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi(15)
    ;(clientForm.querySelector('button[type="submit"]') as HTMLButtonElement).click()
    await flushUi(40)
    expect(clientBodies).toEqual([{ provider: 'slack', client_id: 'my-slack-client-id' }])

    // Click Slack OAuth Connect -> popup navigated synchronously + postMessage settles & auto-refreshes!
    const connectButtons = [...container.querySelectorAll('button')].filter((b) =>
      b.textContent?.trim() === 'OAuth 연결',
    ) as HTMLButtonElement[]
    connectButtons[0]!.click()
    await flushUi(40)
    expect(popupMock.location.href).toBe('https://slack.com/oauth/v2/authorize?state=st-1')

    attachedSlack = true
    window.dispatchEvent(new MessageEvent('message', {
      origin: window.location.origin,
      data: { type: 'masc:oauth-complete', keeper: 'sangsu', provider: 'slack' },
    }))
    await flushUi(50)
    expect(popupMock.close).toHaveBeenCalled()
    expect(container.textContent).toContain('연결됨 · 도구 1개')

    // Click GitHub OAuth Connect -> streams /github-login SSE device flow!
    const ghConnectBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.trim() === 'OAuth 연결',
    ) as HTMLButtonElement
    ghConnectBtn.click()
    await flushUi(50)
    expect(githubStreamCalled).toBe(true)
    expect(container.querySelector('[data-testid="tools-oauth-device-code"]')!.textContent).toBe('GHAB-5678')

    // KeeperConfigTab also exposes guided OAuth App drawer + Disconnect
    render(null, container)
    render(html`<${KeeperConfigTab} keeperName="sangsu" onMutated=${vi.fn()} />`, container)
    await flushUi(40)
    expect(container.textContent).toContain('Slack')

    // Flow 3: AccountWorkspace sign-in link preserves ?return_to=%2Fdashboard%23account
    authSession.value = {
      kind: 'multi_account_signed_out',
      mode: 'multi_account',
      authMethods: { google: true, github: true, dev_token: false },
    }
    render(null, container)
    render(
      html`<${AccountWorkspace} subroute="profile" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(20)
    const signInLink = container.querySelector('[data-testid="multi-account-signin-link"]') as HTMLAnchorElement
    expect(signInLink.getAttribute('href')).toBe('/?return_to=%2Fdashboard%23account')
  })
})
