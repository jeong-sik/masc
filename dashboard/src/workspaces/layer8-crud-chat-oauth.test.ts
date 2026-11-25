// @vitest-environment jsdom
import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  authSession,
  bumpSessionEpoch,
  extractDeviceCode,
  extractOAuthUrl,
  releaseAllViewStreams,
  resetAuthStateForTests,
  resetObserverStateForTests,
  resourceCache,
  startKeeperGithubDeviceFlow,
  startKeeperOAuthPopupFlow,
  streamSetupAccountLogin,
  stripAnsi,
  type ActiveKeeperOAuthFlow,
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

async function waitFor(predicate: () => boolean, timeoutMs = 800, stepMs = 15): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await flushUi(stepMs)
  }
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
max_output_tokens = +8192 # retain the deployed cap when reordering slots
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

    const exactEdit = await vi.waitFor(() => {
      const button = container.querySelector<HTMLButtonElement>('[data-lane-row="exact_output:verifier_exact"] button')
      expect(button?.disabled).toBe(false)
      return button!
    })
    exactEdit.click()
    await flushUi()
    expect(container.querySelector<HTMLInputElement>('input[aria-label="max_output_tokens"]')?.value).toBe('8192')
    container.querySelector<HTMLButtonElement>('button[aria-label="ollama_cloud.deepseek-flash 위로 이동"]')!.click()
    await flushUi()
    const exactPreview = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('Diff 미리보기'),
    )!
    exactPreview.click()
    await vi.waitFor(() => expect(previewBodies).toHaveLength(2))
    const exactSave = await vi.waitFor(() => {
      const button = [...container.querySelectorAll('[data-testid="lane-diff-preview"] button')].find((b) =>
        b.textContent?.includes('변경 적용 (CAS Save)'),
      ) as HTMLButtonElement | undefined
      expect(button?.disabled).toBe(false)
      return button!
    })
    exactSave.click()
    await vi.waitFor(() => expect(saveBodies).toHaveLength(2))
    const savedExactToml = String((saveBodies[1] as { source_text: string }).source_text)
    expect(savedExactToml).toContain('max_output_tokens = +8192 # retain the deployed cap when reordering slots')
    expect(parseLanesFromToml(savedExactToml).find((lane) => lane.kind === 'exact_output')?.candidates).toEqual([
      'ollama_cloud.deepseek-flash',
      'glm-coding.glm-5',
    ])
  })

  it('(A-2) Quote-aware TOML scanner handles # and ] inside strings/comments and preview fails closed on validation.issues', async () => {
    const trickyToml = `[runtime]
default = "coding"

[runtime.lanes.coding] # keep ] comment [safe]
candidates = [
  "provider#alpha.model-1", # inline comment with ] bracket
  'provider.model]beta',
]

[runtime.lanes.other]
candidates = ["safe.model"]
`
    const parsed = parseLanesFromToml(trickyToml)
    expect(parsed).toEqual([
      { kind: 'failover', id: 'coding', candidates: ['provider#alpha.model-1', 'provider.model]beta'] },
      { kind: 'failover', id: 'other', candidates: ['safe.model'] },
    ])

    const updated = upsertLaneInToml(trickyToml, {
      kind: 'failover',
      id: 'coding',
      candidates: ['provider.model]beta', 'provider#alpha.model-1'],
    })
    expect(updated.ok).toBe(true)
    if (updated.ok) {
      expect(parseLanesFromToml(updated.value)).toEqual([
        { kind: 'failover', id: 'coding', candidates: ['provider.model]beta', 'provider#alpha.model-1'] },
        { kind: 'failover', id: 'other', candidates: ['safe.model'] },
      ])
    }

    // Fail-closed preview when can_save is false (or omitted) and validation.issues is present
    const shaRev = 'c'.repeat(64)
    let rawSaveCalls = 0
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url === '/api/v1/runtime/resolved') {
        return jsonResponse({ default_route: 'coding', lanes: [], runtimes: [], assignments: [] })
      }
      if (url.startsWith('/api/v1/dashboard/runtime-probe')) {
        return jsonResponse({ refresh_state: 'fresh', cache_hit: true, probe: { providers: [] } })
      }
      if (url === '/api/v1/runtime/config/raw' && (!init?.method || init.method === 'GET')) {
        return jsonResponse({ ok: true, source_revision: shaRev, path: '/ws/runtime.toml', source_text: SAMPLE_RUNTIME_TOML })
      }
      if (url === '/api/v1/runtime/config/raw/preview' && init?.method === 'POST') {
        return jsonResponse({
          ok: true,
          can_save: false,
          runtime_validation: null,
          validation: {
            issues: [{ severity: 'error', key: 'runtime.lanes.coding', detail: 'unknown runtime id' }],
          },
        })
      }
      if (url === '/api/v1/runtime/config/raw' && init?.method === 'POST') {
        rawSaveCalls += 1
        return jsonResponse({ ok: true })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${RuntimeWorkspace} subroute="lanes" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(50)

    const editBtn = container.querySelector('[data-lane-row="failover:coding"] button') as HTMLButtonElement
    editBtn.click()
    await flushUi(20)

    const previewBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('Diff 미리보기'),
    ) as HTMLButtonElement
    previewBtn.click()
    await flushUi(40)

    const diffBox = container.querySelector('[data-testid="lane-diff-preview"]')!
    expect(diffBox.querySelector('[data-testid="lane-validation-issues"]')!.textContent).toContain(
      '[error] runtime.lanes.coding: unknown runtime id',
    )
    const applyBtn = [...diffBox.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('변경 적용 (CAS Save)'),
    ) as HTMLButtonElement
    expect(applyBtn.disabled).toBe(true)
    applyBtn.click()
    await flushUi(20)
    expect(rawSaveCalls).toBe(0)
  })

  it('saves only the lane source previewed in this session after refreshes and late responses', async () => {
    let source = { path: '/first/runtime.toml', source_revision: 'a'.repeat(64), source_text: SAMPLE_RUNTIME_TOML }
    const saves: unknown[] = []
    const previewResponses: ((response: Response) => void)[] = []
    const pendingReads: ((response: Response) => void)[] = []
    let delayRead = false
    let readUnavailable = false
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url === '/api/v1/runtime/config/raw/preview') {
        return new Promise<Response>((resolve) => { previewResponses.push(resolve) })
      }
      if (url === '/api/v1/runtime/config/raw') {
        if (init?.method === 'POST') {
          saves.push(JSON.parse(String(init.body)))
          return jsonResponse({ ok: true })
        }
        if (readUnavailable) return jsonResponse({ error: 'fixture source offline' }, 503)
        if (delayRead) return new Promise<Response>((resolve) => { pendingReads.push(resolve) })
        return jsonResponse(source)
      }
      if (url === '/api/v1/runtime/resolved') {
        return jsonResponse({ default_route: 'coding', lanes: [], runtimes: [], assignments: [] })
      }
      if (url.startsWith('/api/v1/dashboard/runtime-probe')) {
        return jsonResponse({ probe: { providers: [] } })
      }
      return jsonResponse({})
    }) as typeof fetch

    const button = (text: string) => {
      const found = [...container.querySelectorAll('button')].find((item) => item.textContent?.includes(text))
      if (!found) throw new Error(`Missing button: ${text}`)
      return found
    }
    const editor = () => {
      const edit = container.querySelector<HTMLButtonElement>('[data-lane-row="failover:coding"] button')
      if (!edit || edit.disabled) throw new Error('Lane editor is not ready')
      edit.click()
    }
    const requestPreview = async () => {
      button('Diff 미리보기').click()
      await vi.waitFor(() => expect(previewResponses).toHaveLength(1))
      return previewResponses.shift()!
    }
    const diff = () => container.querySelector('[data-testid="lane-diff-preview"]')
    const valid = () => jsonResponse({ can_save: true })
    const finishCurrentPreview = async () => {
      const respond = await requestPreview()
      respond(valid())
      await vi.waitFor(() => expect(diff()).not.toBeNull())
    }
    render(html`<${RuntimeWorkspace} subroute="lanes" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await vi.waitFor(editor)
    await vi.waitFor(() => expect(button('Diff 미리보기')).toBeTruthy())
    await finishCurrentPreview()
    const oldApply = button('변경 적용')
    const old = source
    source = { path: '/next/runtime.toml', source_revision: 'b'.repeat(64), source_text: SAMPLE_RUNTIME_TOML + '# independent edit\n' }
    button('강제 프로브').click()
    await vi.waitFor(() => expect(container.textContent).toContain(source.source_revision.slice(0, 12)))
    oldApply.click()
    await flushUi()
    expect(saves).toEqual([])
    expect(diff()).toBeNull()

    // A preview started before a new read, and a slower superseded read, both finish last.
    const finishPreview = await requestPreview()
    delayRead = true
    button('강제 프로브').click()
    await vi.waitFor(() => expect(pendingReads).toHaveLength(1))
    delayRead = false
    button('강제 프로브').click()
    await vi.waitFor(() => expect(container.textContent).toContain(source.source_revision.slice(0, 12)))
    pendingReads.shift()!(jsonResponse(old))
    finishPreview(valid())
    await flushUi()
    expect(diff()).toBeNull()
    expect(container.textContent).toContain(source.source_revision.slice(0, 12))

    await finishCurrentPreview()
    const oldSessionApply = button('변경 적용')
    bumpSessionEpoch()
    oldSessionApply.click()
    expect(saves).toEqual([])
    await vi.waitFor(() => expect(diff()).toBeNull())
    await vi.waitFor(editor)
    await vi.waitFor(() => expect(button('Diff 미리보기')).toBeTruthy())
    await finishCurrentPreview()
    button('변경 적용').click()
    await vi.waitFor(() => expect(saves).toEqual([{
      source_text: expect.stringContaining('# independent edit'),
      expected_source_path: source.path,
      expected_source_revision: source.source_revision,
    }]))

    readUnavailable = true
    button('강제 프로브').click()
    await vi.waitFor(() => expect(container.textContent).toContain('runtime.toml 원본 조회 실패'))
    expect(diff()).toBeNull()
    readUnavailable = false
    button('강제 프로브').click()
    await vi.waitFor(() => expect(container.textContent).not.toContain('runtime.toml 원본 조회 실패'))
    expect(container.textContent).toContain(source.source_revision.slice(0, 12))
  })

  it.each([
    '  <memory>Use this format in your reply.</memory>  ',
    '<thinking>Copy these tags verbatim.</thinking>',
    '{"tool_name":"example","args":{"query":"editor text"}}',
  ])('preserves literal user messages containing block syntax %s', (content) => {
    const message: ChatTranscriptEntry = { id: 'operator', role: 'user', content, ts: 100 }
    const blocks = parseChatMessageBlocks(message)
    expect(blocks.bodyText).toBe(content)
    expect(blocks.thinkingText).toBeNull()
    expect(blocks.memoryItems).toEqual([])
    expect(blocks.toolBlocks).toEqual([])
    expect(shouldRenderChatEntry(message, blocks, {
      thinking: 'hidden',
      tools: 'hidden',
      internal: 'hidden',
    })).toBe(true)
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
              content: [
                '<thinking>Checking **OAuth** routes carefully</thinking>',
                '**점검 완료** · `oauth` · [검토 링크](https://example.test/review)',
                '',
                '> *검토 근거*',
                '',
                '```json',
                '{"ok":true}',
                '```',
                '',
                '![결과 이미지](https://example.test/result.png)',
              ].join('\n'),
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
      if (url.includes('/chat/operations')) {
        return jsonResponse({
          schema: 'masc.keeper_chat_operations.list.v1', state: 'Queued', operations: [],
        })
      }
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
    expect(thinkingCard.querySelector('strong')?.textContent).toBe('OAuth')
    const body = container.querySelector('.kp-msg-body')!
    expect(body.querySelector('strong')?.textContent).toBe('점검 완료')
    expect(body.querySelector('a')?.getAttribute('href')).toBe('https://example.test/review')
    expect(body.querySelector('blockquote em')?.textContent).toBe('검토 근거')
    expect(body.querySelector('pre code')?.textContent).toContain('{"ok":true}')
    expect(body.querySelector('img')?.getAttribute('alt')).toBe('결과 이미지')
    expect(container.querySelector('[data-testid="chat-tool-card"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="chat-memory-card"]')).toBeNull()
    expect(container.querySelector('[data-testid="chat-autonomous-card"]')).toBeNull()
    // Toolbar shows hidden internal count (2)
    expect(container.querySelector('[data-testid="chat-toggle-internal"]')!.textContent).toContain('(2)')

    // Manually opening a collapsed <details> card persists across unrelated re-renders (never snapped shut)
    thinkingCard.open = true
    const btwToggleBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('/btw 사이드 질의'),
    ) as HTMLButtonElement
    btwToggleBtn.click()
    await flushUi(20)
    expect((container.querySelector('[data-testid="chat-thinking-card"]') as HTMLDetailsElement).open).toBe(true)

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

  it('(C-1) Provider CLI OAuth reads SSE stream, auto-opens URL, surfaces /input, skips /verify in single-user mode, and auto-verifies in multi-account mode', async () => {
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
    let streamGate = new Promise<void>((r) => { releaseStream = r })

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
      if (url === '/api/v1/auth/provider-accounts') {
        return jsonResponse({
          provider_accounts: [{ provider_account_id: 'acct-ref-77', integration_id: 'codex_subscription', display_name: 'Codex Personal' }],
        })
      }
      if (url === '/api/v1/runtime/config/raw') {
        return jsonResponse({ source_revision: 'b'.repeat(64) })
      }
      if (url === '/api/v1/setup/accounts/login?auth_hints=1' && init?.method === 'POST') {
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

    // 1) Single-user mode: NO "검증" button & NO /api/v1/setup/accounts/verify 404 on complete!
    render(
      html`<${RuntimeWorkspace} subroute="quotas" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(50)

    expect([...container.querySelectorAll('button')].some((b) => b.textContent?.trim() === '검증')).toBe(false)

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
    expect(verifyBodies).toEqual([])
    expect([...container.querySelectorAll('button')].some((b) => b.textContent?.trim() === '계정 검증')).toBe(false)

    // 2) Multi-account mode: auto-verifies via POST /api/v1/setup/accounts/verify on complete
    render(null, container)
    resourceCache.clearAll()
    streamGate = Promise.resolve()
    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'u1',
      email: 'op@masc.dev',
      displayName: 'Operator',
      role: 'admin',
      csrfToken: 'csrf-123',
      authMethods: { google: true, github: true, dev_token: false },
      workspaceId: 'ws-default',
    }
    render(
      html`<${RuntimeWorkspace} subroute="quotas" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(50)

    const reAuthBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.trim() === 'Re-auth',
    ) as HTMLButtonElement
    expect(reAuthBtn).toBeDefined()
    reAuthBtn.click()
    await flushUi(60)
    expect(verifyBodies).toEqual([{ provider_account_id: 'acct-ref-77', model: 'gpt-5-codex' }])

    // 3) Premature EOF on setup login SSE invokes onError instead of silently stopping,
    //    and typed `auth_url`/`device_code` hints opt in via `?auth_hints=1`.
    const requestedHintUrls: string[] = []
    const hintUrls: string[] = []
    const hintCodes: string[] = []
    const hintRes = await streamSetupAccountLogin({
      integrationId: 'codex_subscription',
      fetchImpl: (async (input: RequestInfo | URL) => {
        requestedHintUrls.push(String(input))
        return sseResponse([
          { event: 'started', data: { login_id: 'login-hint', integration_id: 'codex_subscription', status: 'running' } },
          { event: 'auth_url', data: { url: 'https://auth.openai.com/authorize?state=h1' } },
          { event: 'device_code', data: { user_code: 'HINT-4321', verification_uri: 'https://auth.openai.com/device' } },
          { event: 'complete', data: { login_id: 'login-hint', integration_id: 'codex_subscription', status: 'complete' } },
        ])
      }) as unknown as typeof fetch,
      callbacks: {
        onAuthUrl: (u) => hintUrls.push(u),
        onDeviceCode: (c) => hintCodes.push(c),
      },
    })
    expect(requestedHintUrls).toEqual(['/api/v1/setup/accounts/login?auth_hints=1'])
    expect(hintUrls).toEqual(['https://auth.openai.com/authorize?state=h1', 'https://auth.openai.com/device'])
    expect(hintCodes).toEqual(['HINT-4321'])
    expect(hintRes.completed).toBe(true)

    const eofErrors: string[] = []
    const eofResult = await streamSetupAccountLogin({
      integrationId: 'codex_subscription',
      fetchImpl: (async () => sseResponse([
        { event: 'started', data: { login_id: 'login-cut', integration_id: 'codex_subscription', status: 'running' } },
        { event: 'output', data: { stream: 'stdout', text: 'Waiting…\n' } },
      ])) as unknown as typeof fetch,
      callbacks: {
        onError: (msg) => eofErrors.push(msg),
      },
    })
    expect(eofResult.completed).toBe(false)
    expect(eofResult.error).toContain('완료 확인 없이 종료')
    expect(eofErrors).toHaveLength(1)
  })

  it.each([
    ['output followed by EOF', [], false],
    ['an explicit error', [{ event: 'error', data: { message: 'login refused' } }], false],
    ['a complete frame for a different Keeper', [
      { event: 'complete', data: { observation: { ok: true, keeper: 'other', stored: { authenticated: true } } } },
    ], false],
    ['an effective credential without a stored login', [
      { event: 'complete', data: { observation: { ok: true, keeper: 'sangsu', stored: { authenticated: false }, effective: { authenticated: true } } } },
    ], false],
    ['a confirmed stored login', [
      { event: 'complete', data: { observation: { ok: true, keeper: 'sangsu', stored: { authenticated: true } } } },
    ], true],
  ] as const)('settles Keeper GitHub login once after %s', async (_label, terminal, succeeded) => {
    const settled = vi.fn()
    const update = vi.fn()
    const attach = vi.fn(async () => jsonResponse({ keeper: 'sangsu', provider: 'github', attached: true }))
    globalThis.fetch = attach
    startKeeperGithubDeviceFlow({
      keeper: 'sangsu',
      fetchImpl: async () => sseResponse([{ event: 'output', data: { stream: 'stdout', text: 'Waiting for login' } }, ...terminal]),
      onUpdate: update,
      onSettled: settled,
    })
    await vi.waitFor(() => expect(settled.mock.calls).toEqual([[succeeded]]))
    expect(attach).toHaveBeenCalledTimes(succeeded ? 1 : 0)
    expect(update).toHaveBeenLastCalledWith(expect.objectContaining({
      phase: succeeded ? 'completed' : 'failed',
    }))
  })

  it('refuses a mismatched attachment receipt after the CLI confirms this Keeper’s login', async () => {
    globalThis.fetch = vi.fn(async () => jsonResponse({ attached: true, keeper: 'other', provider: 'github' }))
    const settled = vi.fn()
    const update = vi.fn()
    startKeeperGithubDeviceFlow({
      keeper: 'sangsu',
      fetchImpl: async () => sseResponse([{
        event: 'complete', data: { observation: { ok: true, keeper: 'sangsu', stored: { authenticated: true } } },
      }]),
      onUpdate: update, onSettled: settled,
    })
    await vi.waitFor(() => expect(settled.mock.calls).toEqual([[false]]))
    expect(globalThis.fetch).toHaveBeenCalledOnce()
    expect(update).toHaveBeenLastCalledWith(expect.objectContaining({ phase: 'failed' }))
  })

  it('closes a still-open GitHub login stream on a session change without settling the new session', async () => {
    const cancelled = vi.fn()
    const settled = vi.fn()
    const update = vi.fn()
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode('event: output\ndata: {"stream":"stdout","text":"waiting"}\n\n'))
      },
      cancel: cancelled,
    })
    startKeeperGithubDeviceFlow({
      keeper: 'sangsu',
      fetchImpl: async () => new Response(body),
      onUpdate: update,
      onSettled: settled,
    })
    await vi.waitFor(() => expect(update).toHaveBeenLastCalledWith(expect.objectContaining({ phase: 'awaiting_user' })))
    bumpSessionEpoch()
    await vi.waitFor(() => expect(cancelled).toHaveBeenCalledOnce())
    expect(settled).not.toHaveBeenCalled()
  })

  it('keeps a newer login running when an older attempt finishes cancelling', async () => {
    let finishCancellation!: () => void
    const pendingCancellation = new Promise<void>((resolve) => { finishCancellation = resolve })
    const cancels = vi.fn()
    const streams: AbortSignal[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url === '/api/v1/dashboard/provider-usage') return jsonResponse({ scopes: [] })
      if (url.startsWith('/api/v1/dashboard/provider-usage-history')) {
        return jsonResponse({ state: 'unavailable', reason: 'none' })
      }
      if (url === '/api/v1/runtime/resolved') {
        return jsonResponse({ default_route: 'default', runtimes: [], lanes: [], assignments: [] })
      }
      if (url === '/api/v1/setup/inventory') {
        return jsonResponse({
          integrations: [{
            id: 'codex_subscription', display_name: 'Codex', enabled: true, credential_kind: 'login',
          }],
        })
      }
      if (url === '/api/v1/setup/accounts/login?auth_hints=1') {
        const signal = init!.signal!
        streams.push(signal)
        const receipt = {
          login_id: `login-${streams.length}`,
          integration_id: 'codex_subscription',
          status: 'running',
        }
        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new TextEncoder().encode(`event: started\ndata: ${JSON.stringify(receipt)}\n\n`))
            signal.addEventListener('abort', () => controller.close(), { once: true })
          },
        })
        return new Response(stream, { headers: { 'Content-Type': 'text/event-stream' } })
      }
      if (url === '/api/v1/setup/accounts/login/login-1/cancel') {
        cancels()
        await pendingCancellation
        return jsonResponse({ accepted: true }, 202)
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${RuntimeWorkspace} subroute="quotas" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    const button = (label: string) =>
      [...container.querySelectorAll('button')].find((node) => node.textContent?.trim() === label)
    const panel = () => container.querySelector('[data-testid="setup-login-panel"]')?.textContent
    await vi.waitFor(() => expect(button('CLI OAuth')).toBeDefined())
    button('CLI OAuth')!.click()
    await vi.waitFor(() => expect(panel()).toContain('login-1'))
    button('로그인 취소')!.click()
    await vi.waitFor(() => expect(cancels).toHaveBeenCalledOnce())
    button('CLI OAuth')!.click()
    await vi.waitFor(() => expect(panel()).toContain('login-2'))
    finishCancellation()
    await flushUi()
    expect(streams[1]?.aborted).toBe(false)
    expect(panel()).toContain('running')
  })

  it('(C-2 & C-3) Keeper OAuth loads keepers via /gate/keepers & shell groups fallback, strict postMessage, GitHub complete+attach, Config callback URL, and Account return_to', async () => {
    const popupMock = { closed: false, close: vi.fn(), location: { href: '' } }
    vi.spyOn(window, 'open').mockImplementation(() => popupMock as unknown as Window)

    const clientBodies: unknown[] = []
    const oauthLoginBodies: unknown[] = []
    let attachedSlack = false
    let attachedGithub = false
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
      if (url === '/api/v1/gate/keepers') {
        return jsonResponse({ keepers: [{ name: 'sangsu' }, { name: 'code-reviewer-sister' }] })
      }
      if (url.startsWith('/api/v1/keepers/oauth/attached-tools')) {
        return jsonResponse({
          keeper: 'sangsu',
          callback: { url: 'http://127.0.0.1:8935/oauth/callback' },
          providers: [
            { provider: 'slack', provider_label: 'Slack', attached: attachedSlack, enabled: true, tools: attachedSlack ? ['slack_post'] : [] },
            { provider: 'github', provider_label: 'GitHub', attached: attachedGithub, enabled: true, tools: attachedGithub ? ['gh_pr_view'] : [] },
          ],
        })
      }
      if (url === '/api/v1/keepers/sangsu/oauth-login' && init?.method === 'POST') {
        const body = JSON.parse(String(init.body)) as { provider?: string }
        oauthLoginBodies.push(body)
        if (body.provider === 'github') {
          attachedGithub = true
          return jsonResponse({
            keeper: 'sangsu',
            provider: 'github',
            attached: true,
            message: 'GitHub MCP 도구 1개 연결 완료',
          })
        }
        return jsonResponse({
          keeper: 'sangsu',
          provider: 'slack',
          provider_label: 'Slack',
          authorize_url: 'https://slack.com/oauth/v2/authorize?state=st-1',
          attempt_id: 'att-1',
        })
      }
      if (url === '/api/v1/keepers/oauth/attempt-status?keeper=sangsu&provider=slack&attempt_id=att-1') {
        return jsonResponse({
          kind: attachedSlack ? 'completed' : 'awaiting_consent',
          tool_discovery: { kind: 'discovered', count: 1 },
        })
      }
      if (url === '/api/v1/keepers/sangsu/github-login' && init?.method === 'POST') {
        githubStreamCalled = true
        return sseResponse([
          { event: 'output', data: { stream: 'stdout', text: 'Open https://github.com/login/device and enter code GHAB-5678\n' } },
          { event: 'complete', data: { observation: { ok: true, keeper: 'sangsu', stored: { authenticated: true } } } },
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

    // Real keeper selector populated via /api/v1/gate/keepers with 'sangsu' (NEVER hardcoded 'default'!)
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

    // Open the Slack popup and wait for the current server attempt to complete.
    const connectButtons = [...container.querySelectorAll('button')].filter((b) =>
      b.textContent?.trim() === 'OAuth 연결',
    ) as HTMLButtonElement[]
    connectButtons[0]!.click()
    await flushUi(40)
    expect(popupMock.location.href).toBe('https://slack.com/oauth/v2/authorize?state=st-1')

    // Ignored: missing keeper/provider
    window.dispatchEvent(new MessageEvent('message', {
      origin: window.location.origin,
      source: popupMock as unknown as Window,
      data: { type: 'masc:oauth-complete', ok: true },
    }))
    await flushUi(20)
    expect(popupMock.close).not.toHaveBeenCalled()

    // The popup signal wakes the status read for att-1.
    attachedSlack = true
    window.dispatchEvent(new MessageEvent('message', {
      origin: window.location.origin,
      source: popupMock as unknown as Window,
      data: { type: 'masc:oauth-complete', ok: true, keeper: 'sangsu', provider: 'slack' },
    }))
    await flushUi(50)
    expect(popupMock.close).toHaveBeenCalled()
    expect(container.textContent).toContain('연결됨 · 도구 1개')

    // Click GitHub OAuth Connect -> streams /github-login SSE + waits for event:complete + chains /oauth-login {provider:'github'}!
    const ghConnectBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.trim() === 'OAuth 연결',
    ) as HTMLButtonElement
    ghConnectBtn.click()
    await flushUi(60)
    expect(githubStreamCalled).toBe(true)
    expect(oauthLoginBodies).toContainEqual({ provider: 'github' })
    expect(container.querySelector('[data-testid="tools-oauth-device-code"]')!.textContent).toBe('GHAB-5678')

    // KeeperConfigTab also exposes guided OAuth App drawer WITH copyable Callback URL
    render(null, container)
    render(html`<${KeeperConfigTab} keeperName="sangsu" onMutated=${vi.fn()} />`, container)
    await waitFor(() => (container.textContent ?? '').includes('Slack'))
    expect(container.textContent).toContain('Slack')
    const cfgAppBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.trim() === '앱 설정',
    ) as HTMLButtonElement
    cfgAppBtn.click()
    await waitFor(() => container.querySelector('[data-testid="keeper-oauth-callback-url"]') !== null)
    expect(container.querySelector('[data-testid="keeper-oauth-callback-url"]')!.textContent).toContain(
      'http://127.0.0.1:8935/oauth/callback',
    )

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

  it('switching Keepers cancels the old OAuth flow and ignores a late attached-tools read', async () => {
    const popup = { closed: false, location: { href: '' }, close: vi.fn() }
    vi.spyOn(window, 'open').mockReturnValue(popup as unknown as Window)
    let delayAlpha = false
    let finishAlpha: ((response: Response) => void) | undefined
    const reads: string[] = []
    const provider = (name: string) => ({ provider: 'slack', provider_label: name, attached: false, enabled: true })
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/api/v1/gate/keepers') return jsonResponse({ keepers: [{ name: 'alpha' }, { name: 'beta' }] })
      if (url.startsWith('/api/v1/keepers/oauth/attached-tools?')) {
        const keeper = new URL(url, window.location.origin).searchParams.get('keeper')!
        reads.push(keeper)
        if (keeper === 'alpha' && delayAlpha) return new Promise<Response>((resolve) => { finishAlpha = resolve })
        return jsonResponse({ providers: [provider(`provider-${keeper}`)] })
      }
      if (url === '/api/v1/keepers/alpha/oauth-login') {
        return jsonResponse({ authorize_url: 'https://example.invalid/authorize', attempt_id: 'attempt-alpha' })
      }
      if (url.startsWith('/api/v1/tool-metrics/series')) return jsonResponse({ buckets: [], total: {} })
      return jsonResponse({})
    }) as typeof fetch
    const click = (text: string) => {
      const found = [...container.querySelectorAll('button')].find((b) => b.textContent?.trim() === text)
      if (!found) throw new Error(`Missing button: ${text}`)
      found.click()
    }
    render(html`<${RuntimeWorkspace} subroute="tools" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await vi.waitFor(() => {
      const tab = [...container.querySelectorAll('button')].find((b) => b.textContent?.includes('Keeper OAuth'))
      if (!tab) throw new Error('OAuth tab not ready')
      tab.click()
    })
    await vi.waitFor(() => expect(container.textContent).toContain('provider-alpha'))
    click('OAuth 연결')
    await vi.waitFor(() => expect(container.querySelector('[data-testid="tools-oauth-active-flow"]')).not.toBeNull())
    delayAlpha = true
    click('조회')
    await vi.waitFor(() => expect(finishAlpha).toBeDefined())

    const select = container.querySelector<HTMLSelectElement>('select[aria-label="OAuth 대상 Keeper"]')!
    select.value = 'beta'
    select.dispatchEvent(new Event('change', { bubbles: true }))
    await vi.waitFor(() => expect(container.textContent).toContain('provider-beta'))
    finishAlpha!(jsonResponse({ providers: [provider('stale-provider-alpha')] }))
    window.dispatchEvent(new MessageEvent('message', {
      origin: window.location.origin,
      source: popup as unknown as Window,
      data: { type: 'masc:oauth-complete', ok: true, keeper: 'alpha', provider: 'slack' },
    }))
    await flushUi()
    expect(popup.close).toHaveBeenCalledOnce()
    expect(container.querySelector('[data-testid="tools-oauth-active-flow"]')).toBeNull()
    expect(container.textContent).toContain('provider-beta')
    expect(container.textContent).not.toContain('stale-provider-alpha')
    expect(reads).toEqual(['alpha', 'alpha', 'beta'])
  })

  it('(C-4) Keeper OAuth edge cases: shell groups fallback, current attempt status, and incomplete GitHub SSE', async () => {
    const popupMock = { closed: false, close: vi.fn(), location: { href: '' } }
    vi.spyOn(window, 'open').mockImplementation(() => popupMock as unknown as Window)
    let popupStatus: 'callback_admitted' | 'failed' = 'callback_admitted'
    let popupStatusReads = 0

    // 1) /api/v1/dashboard/shell groups[].keepers fallback when /api/v1/gate/keepers returns empty
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.startsWith('/api/v1/tool-metrics/series')) {
        return jsonResponse({ buckets: [], total: { call_count: 0, failure_count: 0, failure_rate: 0, p95_ms: null } })
      }
      if (url === '/api/v1/dashboard/tools') return jsonResponse({ tools: [] })
      if (url === '/api/v1/gate/keepers') return jsonResponse({ keepers: [] })
      if (url === '/api/v1/dashboard/shell') {
        return jsonResponse({
          groups: [
            { group: 'core', keeper_count: 2, keepers: ['e-masc-the-leader', 'sangsu'] },
            { group: 'review', keeper_count: 1, keepers: ['sangsu', 'code-reviewer-sister'] },
          ],
        })
      }
      if (url.startsWith('/api/v1/keepers/oauth/attached-tools')) {
        return jsonResponse({ keeper: 'e-masc-the-leader', providers: [] })
      }
      if (url === '/api/v1/keepers/sangsu/oauth-login') {
        return jsonResponse({
          authorize_url: 'https://slack.com/oauth/v2/authorize?state=st-2',
          attempt_id: 'att-2',
        })
      }
      if (url === '/api/v1/keepers/oauth/attempt-status?keeper=sangsu&provider=slack&attempt_id=att-2') {
        popupStatusReads++
        return jsonResponse({ kind: popupStatus })
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
    const keeperSelect = container.querySelector('select[aria-label="OAuth 대상 Keeper"]') as HTMLSelectElement
    expect(keeperSelect.value).toBe('e-masc-the-leader')
    expect([...keeperSelect.options].map((o) => o.value)).toEqual([
      'e-masc-the-leader',
      'sangsu',
      'code-reviewer-sister',
    ])

    // 2) A popup signal waits for the current attempt's terminal server response.
    const popupStates: ActiveKeeperOAuthFlow[] = []
    let popupSettled: boolean | null = null
    const popupHandle = startKeeperOAuthPopupFlow({
      keeper: 'sangsu',
      provider: 'slack',
      providerLabel: 'Slack',
      pollIntervalMs: 60_000,
      onUpdate: (st) => popupStates.push(st),
      onSettled: (ok) => { popupSettled = ok },
    })
    const notifyPopup = (ok: boolean) => window.dispatchEvent(new MessageEvent('message', {
      origin: window.location.origin,
      source: popupMock as unknown as Window,
      data: { type: 'masc:oauth-complete', ok, keeper: 'sangsu', provider: 'slack' },
    }))
    try {
      notifyPopup(true)
      expect(popupSettled).toBeNull()
      expect(popupStatusReads).toBe(0)
      await vi.waitFor(() => expect(popupStates.at(-1)).toMatchObject({ phase: 'awaiting_user', attemptId: 'att-2' }))
      notifyPopup(true)
      await vi.waitFor(() => expect(popupStates.at(-1)).toMatchObject({ phase: 'completing', attemptId: 'att-2' }))
      expect(popupSettled).toBeNull()
      popupStatus = 'failed'
      notifyPopup(false)
      await vi.waitFor(() => expect(popupSettled).toBe(false))
      expect(popupStates.at(-1)).toMatchObject({ phase: 'failed', attemptId: 'att-2' })
    } finally {
      popupHandle.cancel()
    }

    // 3) GitHub SSE EOF without event: complete fails cleanly and does NOT chain /oauth-login
    let attachCalled = false
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      if (String(input).includes('/oauth-login')) attachCalled = true
      return jsonResponse({})
    }) as typeof fetch
    const ghStates: ActiveKeeperOAuthFlow[] = []
    let ghSettled: boolean | null = null
    startKeeperGithubDeviceFlow({
      keeper: 'sangsu',
      fetchImpl: (async () => sseResponse([
        { event: 'output', data: { stream: 'stdout', text: 'Open https://github.com/login/device\n' } },
      ])) as unknown as typeof fetch,
      onUpdate: (st) => ghStates.push(st),
      onSettled: (ok) => { ghSettled = ok },
    })
    await flushUi(50)
    expect(ghSettled).toBe(false)
    expect(attachCalled).toBe(false)
    expect(ghStates[ghStates.length - 1]!.phase).toBe('failed')
    expect(ghStates[ghStates.length - 1]!.message).toContain('완료 확인 없이 종료')
  })
})
