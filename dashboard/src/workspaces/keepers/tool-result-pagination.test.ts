import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { html } from 'htm/preact'
import { render, fireEvent, waitFor, cleanup } from '@testing-library/preact'
import { authSession, resetAuthStateForTests, sessionEpoch } from '../../core/auth'
import { resetObserverStateForTests } from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { releaseAllViewStreams } from '../../core/view-stream-slot'
import type { WorkspaceInspectPayload } from '../types'
import { fetchKeeperToolResultApi } from './keepers-api'
import { KeeperChatTab } from './keeper-chat-tab'
import { KeeperWorkSandboxTab } from './keeper-work-sandbox-tab'
import { KeeperDebugCompanion } from './keeper-debug-companion'
import { KeeperToolCallInspector } from './keeper-tool-call-inspector'
import {
  TOOL_RESULT_MAX_PAGES_PER_BURST,
  applyToolResultPage,
  copyTextToClipboard,
  formatByteSize,
  formatToolResultProgress,
} from './tool-result-state'
import type { KeeperRosterItem, KeeperToolCallEntry } from './types'

function makeRosterKeeper(overrides: Partial<KeeperRosterItem> = {}): KeeperRosterItem {
  return {
    name: 'code-reviewer-sister',
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
    portrait_equipment: null,
    chat_control_token: 'ctrl-tok-1',
    active_turn: null,
    ...overrides,
  }
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function setupAuth() {
  window.localStorage.clear()
  resetAuthStateForTests()
  resetObserverStateForTests()
  resourceCache.clearAll()
  authSession.value = {
    kind: 'single_user_local',
    mode: 'single_user',
    tokenPresent: true,
    authMethods: { google: false, github: false, dev_token: false },
    workspaceId: 'default',
  }
}

describe('Multi-Page /tool-result Continuation, Pretty-Printing & 409 Recovery', () => {
  beforeEach(setupAuth)
  afterEach(() => {
    cleanup()
    releaseAllViewStreams()
    vi.restoreAllMocks()
  })

  it('sends offset & source_id on continuation and decodes full page metadata while remaining backward-compatible', async () => {
    const urls: string[] = []
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      urls.push(url)
      const sp = new URL(url, 'http://localhost').searchParams
      const offset = Number(sp.get('offset') ?? '0')
      if (offset === 0) {
        return jsonResponse({
          keeper: 'code-reviewer-sister',
          execution_id: 'exec-mp-1',
          state: 'page',
          source_id: 'a'.repeat(64),
          body_sha256: 'b'.repeat(64),
          recorded_bytes: 32,
          is_error: false,
          page: {
            ok: true,
            offset: 0,
            next_offset: 16,
            total_bytes: 32,
            eof: false,
            content: '{"summary":"ok",',
            encoding: 'utf-8',
          },
        })
      }
      return jsonResponse({
        keeper: 'code-reviewer-sister',
        execution_id: 'exec-mp-1',
        state: 'page',
        source_id: 'a'.repeat(64),
        body_sha256: 'b'.repeat(64),
        recorded_bytes: 32,
        is_error: false,
        page: {
          ok: true,
          offset: 16,
          next_offset: 32,
          total_bytes: 32,
          eof: true,
          content: '"items":[1,2,3]}',
          encoding: 'utf-8',
        },
      })
    }))

    // Backward-compatible 2-arg call (page 0)
    const p0 = await fetchKeeperToolResultApi('code-reviewer-sister', 'exec-mp-1')
    expect(p0.ok).toBe(true)
    if (!p0.ok || p0.value.state !== 'page') throw new Error('expected page 0')
    expect(p0.value.sourceId).toBe('a'.repeat(64))
    expect(p0.value.offset).toBe(0)
    expect(p0.value.nextOffset).toBe(16)
    expect(p0.value.eof).toBe(false)
    expect(p0.value.encoding).toBe('utf-8')
    expect(urls[0]).not.toContain('offset=')
    expect(urls[0]).not.toContain('source_id=')

    // Page 0 keeps raw incomplete JSON untouched without mangling
    const s0 = applyToolResultPage(undefined, p0.value)
    expect(s0.status).toBe('loaded')
    expect(s0.displayContent).toBe('{"summary":"ok",')
    expect(formatToolResultProgress(s0)).toBe('16 B / 32 B')

    // Continuation with offset + sourceId
    const p1 = await fetchKeeperToolResultApi(
      'code-reviewer-sister',
      'exec-mp-1',
      16_384,
      undefined,
      { offset: p0.value.nextOffset, sourceId: p0.value.sourceId },
    )
    expect(p1.ok).toBe(true)
    expect(urls[1]).toContain('offset=16')
    expect(urls[1]).toContain(`source_id=${'a'.repeat(64)}`)
    if (!p1.ok) throw new Error('expected page 1')

    // Once eof === true, accumulated raw JSON pretty-prints cleanly
    const s1 = applyToolResultPage(s0, p1.value, { append: true })
    expect(s1.eof).toBe(true)
    expect(s1.rawContent).toBe('{"summary":"ok","items":[1,2,3]}')
    expect(s1.displayContent).toBe(JSON.stringify({ summary: 'ok', items: [1, 2, 3] }, null, 2))
    expect(formatByteSize(14_540)).toBe('14.2 KB')
  })

  it('paginates eof:false pages in KeeperChatTab, supports bounded 끝까지 불러오기, height toggle, and recovers from 409 Conflict', async () => {
    const requestedToolUrls: string[] = []
    let execConflictAttempt = 0
    const srcA = '1'.repeat(64)
    const srcFresh = '2'.repeat(64)
    const srcBurst = '3'.repeat(64)

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/chat/history/page')) {
        return jsonResponse({
          messages: [
            {
              id: 'm-json',
              role: 'tool',
              content: '{"path":"big.json"}',
              ts: 100,
              tool_call_name: 'Read',
              execution_id: 'exec-json-2p',
            },
            {
              id: 'm-burst',
              role: 'tool',
              content: '{"path":"huge.log"}',
              ts: 101,
              tool_call_name: 'Read',
              execution_id: 'exec-burst-20p',
            },
            {
              id: 'm-conflict',
              role: 'tool',
              content: '{"path":"changing.txt"}',
              ts: 102,
              tool_call_name: 'Read',
              execution_id: 'exec-409',
            },
          ],
          has_more: false,
          next_cursor: null,
        })
      }
      if (url.includes('/chat/operations')) {
        return jsonResponse({ operations: [] })
      }
      if (url.includes('/tool-result')) {
        requestedToolUrls.push(url)
        const sp = new URL(url, 'http://localhost').searchParams
        const execId = sp.get('execution_id')
        const offset = Number(sp.get('offset') ?? '0')
        const sourceId = sp.get('source_id')

        if (execId === 'exec-json-2p') {
          if (offset === 0) {
            const longPad = 'x'.repeat(700)
            return jsonResponse({
              keeper: 'code-reviewer-sister',
              execution_id: execId,
              state: 'page',
              source_id: srcA,
              recorded_bytes: 49_152,
              is_error: false,
              page: {
                ok: true,
                offset: 0,
                next_offset: 14_540,
                total_bytes: 49_152,
                eof: false,
                content: `{"pad":"${longPad}","nested":`,
                encoding: 'utf-8',
              },
            })
          }
          expect(offset).toBe(14_540)
          expect(sourceId).toBe(srcA)
          return jsonResponse({
            keeper: 'code-reviewer-sister',
            execution_id: execId,
            state: 'page',
            source_id: srcA,
            recorded_bytes: 49_152,
            is_error: false,
            page: {
              ok: true,
              offset: 14_540,
              next_offset: 49_152,
              total_bytes: 49_152,
              eof: true,
              content: '{"done":true}}',
              encoding: 'utf-8',
            },
          })
        }

        if (execId === 'exec-burst-20p') {
          const chunkSize = 1000
          const totalBytes = 20_000
          const nextOffset = Math.min(totalBytes, offset + chunkSize)
          const pageNum = Math.floor(offset / chunkSize)
          return jsonResponse({
            keeper: 'code-reviewer-sister',
            execution_id: execId,
            state: 'page',
            source_id: srcBurst,
            recorded_bytes: totalBytes,
            is_error: false,
            page: {
              ok: true,
              offset,
              next_offset: nextOffset,
              total_bytes: totalBytes,
              eof: nextOffset >= totalBytes,
              content: `[page-${pageNum}]`,
              encoding: 'utf-8',
            },
          })
        }

        if (execId === 'exec-409') {
          if (offset > 0) {
            return jsonResponse(
              { error: 'Original result source changed; retry this execution' },
              409,
            )
          }
          execConflictAttempt += 1
          if (execConflictAttempt === 1) {
            return jsonResponse({
              keeper: 'code-reviewer-sister',
              execution_id: execId,
              state: 'page',
              source_id: srcA,
              recorded_bytes: 20_000,
              is_error: false,
              page: {
                ok: true,
                offset: 0,
                next_offset: 10_000,
                total_bytes: 20_000,
                eof: false,
                content: 'stale-page-0-content',
                encoding: 'utf-8',
              },
            })
          }
          return jsonResponse({
            keeper: 'code-reviewer-sister',
            execution_id: execId,
            state: 'page',
            source_id: srcFresh,
            recorded_bytes: 16,
            is_error: false,
            page: {
              ok: true,
              offset: 0,
              next_offset: 16,
              total_bytes: 16,
              eof: true,
              content: 'fresh-full-body!',
              encoding: 'utf-8',
            },
          })
        }
      }
      return jsonResponse({})
    }))

    const { container } = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )

    // Open outer tool group
    await waitFor(() => {
      expect(container.querySelector('[data-testid="chat-tool-group"]')).not.toBeNull()
    })
    const groupDetails = container.querySelector('[data-testid="chat-tool-group"] details') as HTMLDetailsElement
    groupDetails.open = true
    fireEvent(groupDetails, new Event('toggle'))

    const cards = Array.from(container.querySelectorAll('[data-testid="chat-tool-card"]')) as HTMLDetailsElement[]
    expect(cards).toHaveLength(3)

    // 1. Two-page JSON continuation + height toggle
    const jsonCard = cards[0]!
    jsonCard.open = true
    fireEvent(jsonCard, new Event('toggle'))

    await waitFor(() => {
      expect(jsonCard.textContent).toContain('14.2 KB / 48.0 KB')
      expect(jsonCard.textContent).toContain('더 불러오기 (+16KB)')
      expect(jsonCard.textContent).toContain('끝까지 불러오기')
    })

    // Toggle long-output height expansion
    const expandBtn = Array.from(jsonCard.querySelectorAll('button')).find((b) => b.textContent?.trim() === '전체 높이')!
    expect(expandBtn).toBeDefined()
    fireEvent.click(expandBtn)
    await waitFor(() => {
      expect(jsonCard.querySelector('.kp-block-pre--expanded')).not.toBeNull()
      expect(expandBtn.textContent?.trim()).toBe('축소')
    })

    // Click "더 불러오기 (+16KB)" -> appends page 1 and pretty-prints full JSON
    const loadMoreBtn = Array.from(jsonCard.querySelectorAll('button')).find((b) => b.textContent?.trim() === '더 불러오기 (+16KB)')!
    fireEvent.click(loadMoreBtn)

    await waitFor(() => {
      expect(jsonCard.textContent).toContain('"done": true')
      expect(jsonCard.querySelector('[data-testid="tool-result-pager"]')).toBeNull()
    })

    // 2. Bounded "끝까지 불러오기" loop stops at TOOL_RESULT_MAX_PAGES_PER_BURST (16 pages per click)
    const burstCard = cards[1]!
    burstCard.open = true
    fireEvent(burstCard, new Event('toggle'))

    await waitFor(() => {
      expect(burstCard.textContent).toContain('[page-0]')
      expect(burstCard.textContent).toContain('끝까지 불러오기')
    })

    const loadAllBtn = Array.from(burstCard.querySelectorAll('button')).find((b) => b.textContent?.trim() === '끝까지 불러오기')!
    fireEvent.click(loadAllBtn)

    await waitFor(() => {
      expect(burstCard.textContent).toContain(`[page-${TOOL_RESULT_MAX_PAGES_PER_BURST}]`)
      expect(loadAllBtn.disabled).toBe(false)
    })
    const burstCalls = requestedToolUrls.filter((u) => u.includes('execution_id=exec-burst-20p'))
    // 1 initial page + 16 continuation pages = 17 requests (did NOT fetch pages 17..19 automatically)
    expect(burstCalls).toHaveLength(1 + TOOL_RESULT_MAX_PAGES_PER_BURST)
    expect(burstCard.textContent).not.toContain('[page-17]')

    // 3. 409 Conflict source-changed recovery
    const conflictCard = cards[2]!
    conflictCard.open = true
    fireEvent(conflictCard, new Event('toggle'))

    await waitFor(() => {
      expect(conflictCard.textContent).toContain('stale-page-0-content')
    })
    const conflictMoreBtn = Array.from(conflictCard.querySelectorAll('button')).find((b) => b.textContent?.trim() === '더 불러오기 (+16KB)')!
    fireEvent.click(conflictMoreBtn)

    await waitFor(() => {
      // Preserves loaded content while showing conflict recovery button
      expect(conflictCard.textContent).toContain('stale-page-0-content')
      expect(conflictCard.textContent).toContain('처음부터 다시 불러오기')
    })

    const reloadBtn = Array.from(conflictCard.querySelectorAll('button')).find((b) => b.textContent?.trim() === '처음부터 다시 불러오기')!
    fireEvent.click(reloadBtn)

    await waitFor(() => {
      expect(conflictCard.textContent).toContain('fresh-full-body!')
      expect(conflictCard.querySelector('[data-testid="tool-result-load-more-error"]')).toBeNull()
    })
  })
})

describe('Streaming <details> Stability & Tools: full Bounded Auto-Hydration', () => {
  beforeEach(setupAuth)
  afterEach(() => {
    cleanup()
    releaseAllViewStreams()
    vi.restoreAllMocks()
  })

  it('keeps an already-opened tool card open across TOOL_CALL_ADMITTED, TOOL_CALL_ARGS, TOOL_CALL_END, KEEPER_TOOL_RESULT_READY, and multi-tool grouping, and auto-fetches /tool-result live', async () => {
    const encoder = new TextEncoder()
    let streamController: ReadableStreamDefaultController<Uint8Array> | null = null
    const pushFrame = (frame: Record<string, unknown>) => {
      streamController!.enqueue(encoder.encode(`data: ${JSON.stringify(frame)}\n\n`))
    }

    const toolResultCalls: string[] = []
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/chat/history/page')) {
        return jsonResponse({ messages: [], has_more: false, next_cursor: null })
      }
      if (url.includes('/chat/operations')) {
        return jsonResponse({ operations: [] })
      }
      if (url.includes('/api/v1/keepers/chat/stream')) {
        const body = new ReadableStream<Uint8Array>({
          start(controller) {
            streamController = controller
          },
        })
        return new Response(body, {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        })
      }
      if (url.includes('/tool-result')) {
        toolResultCalls.push(url)
        return jsonResponse({
          keeper: 'code-reviewer-sister',
          execution_id: 'exec-live-open-1',
          state: 'page',
          source_id: '9'.repeat(64),
          recorded_bytes: 28,
          is_error: false,
          page: {
            ok: true,
            offset: 0,
            next_offset: 28,
            total_bytes: 28,
            eof: true,
            content: 'live hydrated tool stdout ok',
            encoding: 'utf-8',
          },
        })
      }
      return jsonResponse({})
    }))

    const { container, getByLabelText } = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )

    const input = getByLabelText('Keeper 채팅 입력') as HTMLTextAreaElement
    fireEvent.input(input, { target: { value: 'Run command' } })
    fireEvent.keyDown(input, { key: 'Enter' })

    await waitFor(() => {
      expect(streamController).not.toBeNull()
    })

    // Emit TOOL_CALL_START without id or executionId (exact condition that previously remounted <details>)
    pushFrame({ type: 'TOOL_CALL_START', toolStreamScope: 0, toolCallBlockIndex: 0, toolCallName: 'Execute' })

    await waitFor(() => {
      expect(container.querySelector('[data-testid="chat-tool-card"]')).not.toBeNull()
    })

    // User opens the live tool card mid-stream
    const cardBefore = container.querySelector('[data-testid="chat-tool-card"]') as HTMLDetailsElement
    cardBefore.open = true
    fireEvent(cardBefore, new Event('toggle'))
    expect(cardBefore.open).toBe(true)

    // Stream ADMITTED (adds id), ARGS, END, RESULT_READY (adds executionId)
    pushFrame({
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_CALL_ADMITTED',
      value: { toolStreamScope: 0, toolCallBlockIndex: 0, toolCallId: 'call_late_id', toolCallName: 'Execute' },
    })
    pushFrame({
      type: 'TOOL_CALL_ARGS',
      toolStreamScope: 0,
      toolCallBlockIndex: 0,
      snapshot: '{"command":"git diff --stat"}',
    })
    pushFrame({ type: 'TOOL_CALL_END', toolStreamScope: 0, toolCallBlockIndex: 0 })
    pushFrame({
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { toolStreamScope: 0, toolCallBlockIndex: 0, executionId: 'exec-live-open-1' },
    })

    // Same <details> node stayed mounted, stayed open, AND auto-hydrated /tool-result immediately!
    await waitFor(() => {
      expect(cardBefore.isConnected).toBe(true)
      expect(cardBefore.open).toBe(true)
      expect(cardBefore.textContent).toContain('git diff --stat')
      expect(cardBefore.textContent).toContain('live hydrated tool stdout ok')
    })
    expect(toolResultCalls.filter((u) => u.includes('execution_id=exec-live-open-1'))).toHaveLength(1)

    // Now a 2nd tool call starts in the SAME turn -> switches from 1 tool to 2-tool subgroup;
    // tool 0 must STAY OPEN even across the 1 -> 2 wrapper transition and after RUN_FINISHED!
    pushFrame({ type: 'TOOL_CALL_START', toolStreamScope: 0, toolCallBlockIndex: 1, toolCallName: 'Grep' })
    pushFrame({ type: 'TEXT_MESSAGE_CONTENT', delta: 'Finished check.' })
    pushFrame({ type: 'RUN_FINISHED' })
    streamController!.close()

    await waitFor(() => {
      const turnGroup = container.querySelector('[data-testid="chat-turn-tool-group"]') as HTMLDetailsElement
      expect(turnGroup).not.toBeNull()
      expect(turnGroup.open).toBe(true)
      const cardsAfter = Array.from(turnGroup.querySelectorAll('[data-testid="chat-tool-card"]')) as HTMLDetailsElement[]
      expect(cardsAfter).toHaveLength(2)
      expect(cardsAfter[0]!.open).toBe(true)
      expect(cardsAfter[0]!.textContent).toContain('live hydrated tool stdout ok')
      expect(cardsAfter[1]!.open).toBe(false)
    })
  })

  it('auto-hydrates only the latest 8 visible cards when switching to Tools: full (bounded, no fetch storm)', async () => {
    const requestedExecIds: string[] = []
    const messages = Array.from({ length: 12 }, (_, idx) => {
      const n = String(idx + 1).padStart(2, '0')
      return {
        id: `tool-row-${n}`,
        role: 'tool',
        content: JSON.stringify({ step: idx + 1 }),
        ts: 1000 + idx,
        tool_call_name: 'Read',
        execution_id: `exec-full-${n}`,
      }
    })

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/chat/history/page')) {
        return jsonResponse({ messages, has_more: false, next_cursor: null })
      }
      if (url.includes('/chat/operations')) {
        return jsonResponse({ operations: [] })
      }
      if (url.includes('/tool-result')) {
        const execId = new URL(url, 'http://localhost').searchParams.get('execution_id') ?? ''
        requestedExecIds.push(execId)
        return jsonResponse({
          keeper: 'code-reviewer-sister',
          execution_id: execId,
          state: 'page',
          source_id: '5'.repeat(64),
          recorded_bytes: 24,
          is_error: false,
          page: {
            ok: true,
            offset: 0,
            next_offset: 24,
            total_bytes: 24,
            eof: true,
            content: `hydrated:${execId}`,
            encoding: 'utf-8',
          },
        })
      }
      return jsonResponse({})
    }))

    const { container } = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )

    await waitFor(() => {
      expect(container.querySelector('[data-testid="chat-tool-group"]')).not.toBeNull()
    })
    // Default Tools: summary -> zero eager /tool-result fetches
    expect(requestedExecIds).toHaveLength(0)

    // Open 표시 ▾ PopoverMenu and click Tools toggle: summary -> full
    fireEvent.click(container.querySelector('[data-testid="chat-display-menu"]') as HTMLButtonElement)
    const toggleBtn = container.querySelector('[data-testid="chat-toggle-tools"]') as HTMLButtonElement
    fireEvent.click(toggleBtn)
    expect(toggleBtn.textContent).toContain('전체')

    // Wait for latest 8 (exec-full-05 .. exec-full-12) to hydrate
    await waitFor(() => {
      expect(container.textContent).toContain('hydrated:exec-full-12')
      expect(container.textContent).toContain('hydrated:exec-full-05')
    })

    // Wait an extra tick to verify NO cascading fetch storm for older cards 01..04
    await new Promise((r) => setTimeout(r, 30))
    expect(requestedExecIds.sort()).toEqual([
      'exec-full-05',
      'exec-full-06',
      'exec-full-07',
      'exec-full-08',
      'exec-full-09',
      'exec-full-10',
      'exec-full-11',
      'exec-full-12',
    ])

    // Older card #1 still offers explicit "실행 결과 불러오기" button
    const cards = Array.from(container.querySelectorAll('[data-testid="chat-tool-card"]')) as HTMLDetailsElement[]
    expect(cards[0]!.textContent).toContain('실행 결과 불러오기')
    expect(cards[0]!.textContent).not.toContain('hydrated:exec-full-01')
  })

  it('does not flash previous keeper messages or issue cross-keeper /tool-result fetches on keeper switch in Tools: full mode', async () => {
    const toolResultUrls: string[] = []
    let resolveBetaHistory!: (res: Response) => void
    const betaHistoryPending = new Promise<Response>((resolve) => {
      resolveBetaHistory = resolve
    })

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/keepers/keeper-alpha/chat/history/page')) {
        return jsonResponse({
          messages: [
            {
              id: 'alpha-tool-1',
              role: 'tool',
              content: '{"path":"alpha.txt"}',
              ts: 1000,
              tool_call_name: 'Read',
              execution_id: 'exec-alpha-1',
            },
          ],
          has_more: false,
          next_cursor: null,
        })
      }
      if (url.includes('/keepers/keeper-beta/chat/history/page')) {
        return betaHistoryPending
      }
      if (url.includes('/chat/operations')) {
        return jsonResponse({ operations: [] })
      }
      if (url.includes('/tool-result')) {
        toolResultUrls.push(url)
        const parsed = new URL(url, 'http://localhost')
        const execId = parsed.searchParams.get('execution_id') ?? ''
        if (parsed.pathname.includes('/keepers/keeper-alpha/') && execId === 'exec-alpha-1') {
          return jsonResponse({
            keeper: 'keeper-alpha',
            execution_id: 'exec-alpha-1',
            state: 'page',
            source_id: 'a'.repeat(64),
            recorded_bytes: 17,
            is_error: false,
            page: {
              ok: true,
              offset: 0,
              next_offset: 17,
              total_bytes: 17,
              eof: true,
              content: 'alpha-tool-output',
              encoding: 'utf-8',
            },
          })
        }
        if (parsed.pathname.includes('/keepers/keeper-beta/') && execId === 'exec-beta-1') {
          return jsonResponse({
            keeper: 'keeper-beta',
            execution_id: 'exec-beta-1',
            state: 'page',
            source_id: 'b'.repeat(64),
            recorded_bytes: 16,
            is_error: false,
            page: {
              ok: true,
              offset: 0,
              next_offset: 16,
              total_bytes: 16,
              eof: true,
              content: 'beta-tool-output',
              encoding: 'utf-8',
            },
          })
        }
        return jsonResponse({ error: 'tool execution not found' }, 404)
      }
      return jsonResponse({})
    }))

    const onInspect = vi.fn()
    const onMutated = vi.fn()
    const view = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper({ name: 'keeper-alpha' })} onInspect=${onInspect} onMutated=${onMutated} />`,
    )

    await waitFor(() => {
      expect(view.container.querySelector('[data-testid="chat-tool-card"]')).not.toBeNull()
    })

    // Switch to Tools: full mode via 표시 ▾ PopoverMenu and confirm keeper-alpha hydrates its persisted tool card
    fireEvent.click(view.container.querySelector('[data-testid="chat-display-menu"]') as HTMLButtonElement)
    const toggleBtn = view.container.querySelector('[data-testid="chat-toggle-tools"]') as HTMLButtonElement
    fireEvent.click(toggleBtn)
    expect(toggleBtn.textContent).toContain('전체')

    await waitFor(() => {
      expect(view.container.textContent).toContain('alpha-tool-output')
    })
    expect(
      toolResultUrls.filter((u) => u.includes('/keepers/keeper-alpha/tool-result') && u.includes('execution_id=exec-alpha-1')),
    ).toHaveLength(1)

    // Rerender with keeper-beta while keeper-beta history is still in flight
    view.rerender(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper({ name: 'keeper-beta' })} onInspect=${onInspect} onMutated=${onMutated} />`,
    )

    // Previous keeper's messages must not flash and ZERO cross-keeper fetches may fire
    expect(view.container.querySelector('[data-testid="chat-tool-card"]')).toBeNull()
    expect(view.container.textContent).not.toContain('alpha-tool-output')
    expect(
      toolResultUrls.filter((u) => u.includes('/keepers/keeper-beta/tool-result') && u.includes('execution_id=exec-alpha-1')),
    ).toHaveLength(0)

    // Resolve keeper-beta history with its own persisted tool card
    resolveBetaHistory(jsonResponse({
      messages: [
        {
          id: 'beta-tool-1',
          role: 'tool',
          content: '{"path":"beta.txt"}',
          ts: 2000,
          tool_call_name: 'Read',
          execution_id: 'exec-beta-1',
        },
      ],
      has_more: false,
      next_cursor: null,
    }))

    await waitFor(() => {
      expect(view.container.textContent).toContain('beta-tool-output')
    })

    expect(view.container.textContent).not.toContain('alpha-tool-output')
    expect(
      toolResultUrls.filter((u) => u.includes('/keepers/keeper-beta/tool-result') && u.includes('execution_id=exec-alpha-1')),
    ).toHaveLength(0)
    expect(
      toolResultUrls.filter((u) => u.includes('/keepers/keeper-beta/tool-result') && u.includes('execution_id=exec-beta-1')),
    ).toHaveLength(1)
  })
})

describe('KeeperToolCallInspector & Work/Debug Companion QuickPeekDrawer Wiring', () => {
  beforeEach(setupAuth)
  afterEach(() => {
    cleanup()
    releaseAllViewStreams()
    vi.restoreAllMocks()
  })

  it('wires KeeperToolCallInspector from Work & Sandbox and Debug Companion, shows preview while loading, paginates /tool-result, and toggles raw JSON', async () => {
    const sampleRow: KeeperToolCallEntry = {
      ts: 1_700_000_200,
      record_kind: 'tool_call',
      keeper: 'code-reviewer-sister',
      tool: 'Read',
      duration_ms: 42,
      wire_outcome: 'ok',
      disposition: 'completed',
      execution_id: 'exec-inspect-1',
      turn: 7,
      result_bytes: 32_768,
      truncated_to: 4000,
      input: { path: 'lib/keeper/keeper_agent_run.ml', start_line: 1 },
      output: 'truncated preview head...',
    }

    let resolvePage0!: (res: Response) => void
    const page0Pending = new Promise<Response>((resolve) => {
      resolvePage0 = resolve
    })
    const srcInspector = '7'.repeat(64)
    const toolResultUrls: string[] = []

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/tool-calls')) {
        return jsonResponse({
          keeper: 'code-reviewer-sister',
          count: 1,
          health: 'ok',
          entries: [sampleRow],
        })
      }
      if (url.includes('/tool-stats')) {
        return jsonResponse({ keeper: 'code-reviewer-sister', window_hours: 24, total_entries: 1, tools: [] })
      }
      if (url.includes('/operator-note')) {
        return jsonResponse({ keeper: 'code-reviewer-sister', pending: false, note: { text: '' } })
      }
      if (url.includes('/infra/sandboxes')) {
        return jsonResponse({ data: { keeper: 'code-reviewer-sister', probe_state: { kind: 'ready' }, sandbox: { backend: 'microvm' } } })
      }
      if (url.includes('/dashboard/execution')) {
        return jsonResponse({ tasks: [] })
      }
      if (url.includes('/turn-records')) {
        return jsonResponse({ keeper: 'code-reviewer-sister', count: 0, live_turn_in_progress: false, health: 'ok', entries: [] })
      }
      if (url.includes('/raw-traces')) {
        return jsonResponse({ turns: [] })
      }
      if (url.includes('/tool-result')) {
        toolResultUrls.push(url)
        const sp = new URL(url, 'http://localhost').searchParams
        const offset = Number(sp.get('offset') ?? '0')
        if (offset === 0) return page0Pending
        expect(sp.get('source_id')).toBe(srcInspector)
        return jsonResponse({
          keeper: 'code-reviewer-sister',
          execution_id: 'exec-inspect-1',
          state: 'page',
          source_id: srcInspector,
          recorded_bytes: 32_768,
          is_error: false,
          page: {
            ok: true,
            offset: 16_384,
            next_offset: 32_768,
            total_bytes: 32_768,
            eof: true,
            content: '"tail":"complete"}',
            encoding: 'utf-8',
          },
        })
      }
      return jsonResponse({})
    }))

    // 1. Verify Work & Sandbox wires render() -> KeeperToolCallInspector
    const workInspected: WorkspaceInspectPayload[] = []
    const ws = render(
      html`<${KeeperWorkSandboxTab} keeperName="code-reviewer-sister" onNavigate=${vi.fn()} onInspect=${(p: WorkspaceInspectPayload) => workInspected.push(p)} />`,
    )
    await waitFor(() => {
      expect(ws.container.textContent).toContain('Read')
    })
    const rowEl = ws.container.querySelector('tbody tr') as HTMLElement
    expect(rowEl).not.toBeNull()
    fireEvent.click(rowEl)
    expect(workInspected).toHaveLength(1)
    expect(workInspected[0]!.kind).toBe('tool_call')
    expect(workInspected[0]!.render).toBeTypeOf('function')

    // 2. Verify Debug Companion Trace tab ALSO wires render() -> KeeperToolCallInspector
    const dbgInspected: WorkspaceInspectPayload[] = []
    const dbg = render(
      html`<${KeeperDebugCompanion} keeperName="code-reviewer-sister" onClose=${vi.fn()} onInspect=${(p: WorkspaceInspectPayload) => dbgInspected.push(p)} />`,
    )
    await waitFor(() => {
      expect(dbg.container.textContent).toContain('Recent Tool Calls (1)')
    })
    const dbgBtn = Array.from(dbg.container.querySelectorAll('button.kp-kv-box')).find((b) => b.textContent?.includes('Read'))!
    fireEvent.click(dbgBtn)
    expect(dbgInspected).toHaveLength(1)
    expect(dbgInspected[0]!.render).toBeTypeOf('function')

    cleanup()

    // 3. Render the inspector payload and verify primary meta inline + secondary meta collapsed + preview-while-loading -> page 0 -> page 1 -> raw JSON toggle
    const insp = render(html`${workInspected[0]!.render!()}`)
    expect(insp.container.querySelector('[data-testid="tool-call-inspector-meta"]')?.textContent).toContain('Read')
    expect(insp.container.querySelector('[data-testid="tool-call-inspector-meta"]')?.textContent).toContain('42ms')
    const secondaryMeta = insp.container.querySelector('[data-testid="tool-call-inspector-secondary-meta"]') as HTMLDetailsElement | null
    expect(secondaryMeta).not.toBeNull()
    expect(secondaryMeta?.open).toBe(false)
    expect(secondaryMeta?.textContent).toContain('exec: exec-inspect-1')
    expect(secondaryMeta?.textContent).toContain('Turn #7')
    expect(insp.container.querySelector('[data-testid="tool-call-inspector-input"]')?.textContent).toContain('lib/keeper/keeper_agent_run.ml')
    // Preview shows immediately while page 0 is still loading
    expect(insp.container.querySelector('[data-testid="tool-call-inspector-loading"]')).not.toBeNull()
    expect(insp.container.querySelector('[data-testid="tool-call-inspector-output"]')?.textContent).toContain('truncated preview head...')

    // Resolve page 0 (eof: false)
    resolvePage0(jsonResponse({
      keeper: 'code-reviewer-sister',
      execution_id: 'exec-inspect-1',
      state: 'page',
      source_id: srcInspector,
      recorded_bytes: 32_768,
      is_error: false,
      page: {
        ok: true,
        offset: 0,
        next_offset: 16_384,
        total_bytes: 32_768,
        eof: false,
        content: '{"head":"part0",',
        encoding: 'utf-8',
      },
    }))

    await waitFor(() => {
      expect(insp.container.querySelector('[data-testid="tool-call-inspector-pager"]')).not.toBeNull()
      expect(insp.container.textContent).toContain('16.0 KB / 32.0 KB')
    })

    // Click "더 불러오기 (+16KB)" -> appends page 1 and pretty-prints complete JSON
    const moreBtn = Array.from(insp.container.querySelectorAll('button')).find((b) => b.textContent?.trim() === '더 불러오기 (+16KB)')!
    fireEvent.click(moreBtn)

    await waitFor(() => {
      const out = insp.container.querySelector('[data-testid="tool-call-inspector-output"]')?.textContent ?? ''
      expect(out).toContain('"head": "part0"')
      expect(out).toContain('"tail": "complete"')
      expect(insp.container.querySelector('[data-testid="tool-call-inspector-pager"]')).toBeNull()
    })
    expect(toolResultUrls).toHaveLength(2)

    // Raw JSON toggle
    const rawToggle = insp.container.querySelector('[data-testid="tool-call-raw-toggle"]') as HTMLButtonElement
    expect(insp.container.querySelector('[data-testid="tool-call-inspector-raw"]')).toBeNull()
    fireEvent.click(rawToggle)
    expect(insp.container.querySelector('[data-testid="tool-call-inspector-raw"]')?.textContent).toContain('"execution_id": "exec-inspect-1"')
  })

  it('handles 409 Conflict recovery and clean abort on unmount inside KeeperToolCallInspector', async () => {
    const srcOld = 'a'.repeat(64)
    const srcNew = 'b'.repeat(64)
    let page0Count = 0
    let capturedSignal: AbortSignal | undefined

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      capturedSignal = init?.signal ?? undefined
      const sp = new URL(url, 'http://localhost').searchParams
      const offset = Number(sp.get('offset') ?? '0')
      if (offset > 0) {
        return jsonResponse({ error: 'Original result source changed; retry this execution' }, 409)
      }
      page0Count += 1
      if (page0Count === 1) {
        return jsonResponse({
          keeper: 'code-reviewer-sister',
          execution_id: 'exec-insp-409',
          state: 'page',
          source_id: srcOld,
          recorded_bytes: 20_000,
          is_error: false,
          page: {
            ok: true,
            offset: 0,
            next_offset: 10_000,
            total_bytes: 20_000,
            eof: false,
            content: 'initial-chunk-before-409',
            encoding: 'utf-8',
          },
        })
      }
      return jsonResponse({
        keeper: 'code-reviewer-sister',
        execution_id: 'exec-insp-409',
        state: 'page',
        source_id: srcNew,
        recorded_bytes: 18,
        is_error: false,
        page: {
          ok: true,
          offset: 0,
          next_offset: 18,
          total_bytes: 18,
          eof: true,
          content: page0Count === 2 ? 'reloaded-after-409' : 'reloaded-after-epoch',
          encoding: 'utf-8',
        },
      })
    }))

    const entry: KeeperToolCallEntry = {
      ts: 1_700_000_300,
      record_kind: 'tool_call',
      keeper: 'code-reviewer-sister',
      tool: 'Execute',
      duration_ms: 88,
      wire_outcome: 'ok',
      disposition: 'completed',
      execution_id: 'exec-insp-409',
      input: { command: 'echo hi' },
      output: 'preview',
    }

    const view = render(html`<${KeeperToolCallInspector} keeperName="code-reviewer-sister" entry=${entry} />`)
    await waitFor(() => {
      expect(view.container.textContent).toContain('initial-chunk-before-409')
    })

    const moreBtn = Array.from(view.container.querySelectorAll('button')).find((b) => b.textContent?.trim() === '더 불러오기 (+16KB)')!
    fireEvent.click(moreBtn)

    await waitFor(() => {
      expect(view.container.querySelector('[data-testid="tool-call-inspector-load-more-error"]')).not.toBeNull()
      expect(view.container.textContent).toContain('처음부터 다시 불러오기')
    })

    const resetBtn = Array.from(view.container.querySelectorAll('button')).find((b) => b.textContent?.trim() === '처음부터 다시 불러오기')!
    fireEvent.click(resetBtn)

    await waitFor(() => {
      expect(view.container.textContent).toContain('reloaded-after-409')
    })

    sessionEpoch.value = sessionEpoch.peek() + 1
    await waitFor(() => {
      expect(view.container.textContent).toContain('reloaded-after-epoch')
      expect(view.container.textContent).not.toContain('reloaded-after-409')
    })

    // Unmount aborts any new pending fetch cleanly
    vi.stubGlobal('fetch', vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      capturedSignal = init?.signal ?? undefined
      return new Promise<Response>(() => {})
    }))
    const view2 = render(html`<${KeeperToolCallInspector} keeperName="code-reviewer-sister" entry=${{ ...entry, execution_id: 'exec-abort-test' }} />`)
    await waitFor(() => {
      expect(capturedSignal).toBeDefined()
    })
    view2.unmount()
    expect(capturedSignal?.aborted).toBe(true)
  })

  it('preserves prior UTF-8 content on mixed utf-8 -> base64 continuation and falls back to execCommand copy cleanly', async () => {
    const srcMix = 'c'.repeat(64)
    const s0 = applyToolResultPage(undefined, {
      state: 'page',
      executionId: 'exec-mixed-bin',
      sourceId: srcMix,
      offset: 0,
      nextOffset: 12,
      totalBytes: 64,
      recordedBytes: 64,
      eof: false,
      encoding: 'utf-8',
      content: 'utf8-prefix!',
      isError: false,
    })
    expect(s0.rawContent).toBe('utf8-prefix!')
    expect(s0.displayContent).toBe('utf8-prefix!')
    expect(s0.isBinary).toBe(false)

    const s1 = applyToolResultPage(
      s0,
      {
        state: 'page',
        executionId: 'exec-mixed-bin',
        sourceId: srcMix,
        offset: 12,
        nextOffset: 44,
        totalBytes: 64,
        recordedBytes: 64,
        eof: false,
        encoding: 'base64',
        content: '[binary/base64 · 64B]',
        isError: false,
      },
      { append: true },
    )
    expect(s1.status).toBe('loaded')
    expect(s1.rawContent).toBe('utf8-prefix!')
    expect(s1.displayContent).toBe('utf8-prefix!\n\n[binary/base64 · 64B]')
    expect(s1.eof).toBe(false)
    expect(s1.isBinary).toBe(true)
    expect(formatToolResultProgress(s1)).toBe('44 B / 64 B')

    // Verify throw-safe execCommand('copy') fallback when navigator.clipboard is unavailable
    const origClipboard = Object.getOwnPropertyDescriptor(navigator, 'clipboard')
    const origExecCommand = document.execCommand
    const execMock = vi.fn(() => true)
    Object.defineProperty(navigator, 'clipboard', { value: undefined, configurable: true })
    document.execCommand = execMock
    try {
      const copied = await copyTextToClipboard('fallback-copy-payload')
      expect(copied).toBe(true)
      expect(execMock).toHaveBeenCalledWith('copy')
      expect(document.querySelector('.kp-sr-copy-buffer')).toBeNull()
    } finally {
      if (origClipboard) {
        Object.defineProperty(navigator, 'clipboard', origClipboard)
      }
      document.execCommand = origExecCommand
    }
  })

  it('aborts prior fetch and hydrates the new execution when entry prop changes in-place, and uses UTF-8 byte length for truncation badge', async () => {
    const signalsByExec = new Map<string, AbortSignal>()
    const koreanPreview = '한글출력확인' // 6 UTF-16 code units, 18 UTF-8 bytes
    const entryA: KeeperToolCallEntry = {
      ts: 1_700_000_400,
      record_kind: 'tool_call',
      keeper: 'code-reviewer-sister',
      tool: 'Read',
      duration_ms: 15,
      wire_outcome: 'ok',
      disposition: 'completed',
      execution_id: 'exec-switch-a',
      result_bytes: 18,
      input: { path: 'a.txt' },
      output: koreanPreview,
    }
    const entryB: KeeperToolCallEntry = {
      ts: 1_700_000_401,
      record_kind: 'tool_call',
      keeper: 'code-reviewer-sister',
      tool: 'Grep',
      duration_ms: 21,
      wire_outcome: 'ok',
      disposition: 'completed',
      execution_id: 'exec-switch-b',
      result_bytes: 20,
      input: { pattern: 'foo' },
      output: 'preview-b',
    }

    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const execId = new URL(url, 'http://localhost').searchParams.get('execution_id') ?? ''
      if (init?.signal) signalsByExec.set(execId, init.signal)
      if (execId === 'exec-switch-a') {
        // Keep A pending until entry switches to B
        return new Promise<Response>(() => {})
      }
      return Promise.resolve(jsonResponse({
        keeper: 'code-reviewer-sister',
        execution_id: 'exec-switch-b',
        state: 'page',
        source_id: 'd'.repeat(64),
        recorded_bytes: 20,
        is_error: false,
        page: {
          ok: true,
          offset: 0,
          next_offset: 20,
          total_bytes: 20,
          eof: true,
          content: 'hydrated-entry-b-ok!',
          encoding: 'utf-8',
        },
      }))
    }))

    const view = render(html`<${KeeperToolCallInspector} keeperName="code-reviewer-sister" entry=${entryA} />`)
    await waitFor(() => {
      expect(signalsByExec.has('exec-switch-a')).toBe(true)
    })
    // Non-ASCII preview with exact UTF-8 byte match must NOT falsely show "잘림"
    expect(view.container.querySelector('[data-testid="tool-call-inspector-meta"]')?.textContent).not.toContain('잘림')

    // Rerender in-place with entryB while drawer stays mounted
    view.rerender(html`<${KeeperToolCallInspector} keeperName="code-reviewer-sister" entry=${entryB} />`)

    await waitFor(() => {
      expect(signalsByExec.get('exec-switch-a')?.aborted).toBe(true)
      expect(view.container.querySelector('[data-testid="tool-call-inspector-output"]')?.textContent).toContain('hydrated-entry-b-ok!')
    })
  })

  it('resets expand & full-height state on sessionEpoch change and supports post-eviction manual reload past MAX_TOOL_RESULT_CACHE', async () => {
    const fetchCounts = new Map<string, number>()
    const longBody = 'L'.repeat(700)
    const messages = Array.from({ length: 51 }, (_, idx) => {
      const n = String(idx + 1).padStart(2, '0')
      return {
        id: `evict-row-${n}`,
        role: 'tool',
        content: JSON.stringify({ n: idx + 1 }),
        ts: 2000 + idx,
        tool_call_name: 'Read',
        execution_id: `exec-evict-${n}`,
      }
    })

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/chat/history/page')) {
        return jsonResponse({ messages, has_more: false, next_cursor: null })
      }
      if (url.includes('/chat/operations')) {
        return jsonResponse({ operations: [] })
      }
      if (url.includes('/tool-result')) {
        const execId = new URL(url, 'http://localhost').searchParams.get('execution_id') ?? ''
        fetchCounts.set(execId, (fetchCounts.get(execId) ?? 0) + 1)
        return jsonResponse({
          keeper: 'code-reviewer-sister',
          execution_id: execId,
          state: 'page',
          source_id: 'e'.repeat(64),
          recorded_bytes: longBody.length,
          is_error: false,
          page: {
            ok: true,
            offset: 0,
            next_offset: longBody.length,
            total_bytes: longBody.length,
            eof: true,
            content: `${execId}:${longBody}`,
            encoding: 'utf-8',
          },
        })
      }
      return jsonResponse({})
    }))

    const { container } = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )

    await waitFor(() => {
      expect(container.querySelector('[data-testid="chat-tool-group"]')).not.toBeNull()
    })
    const groupDetails = container.querySelector('[data-testid="chat-tool-group"] details') as HTMLDetailsElement
    groupDetails.open = true
    fireEvent(groupDetails, new Event('toggle'))

    const cards = Array.from(container.querySelectorAll('[data-testid="chat-tool-card"]')) as HTMLDetailsElement[]
    expect(cards).toHaveLength(51)

    // Open card #1 and expand its full-height toggle
    cards[0]!.open = true
    fireEvent(cards[0]!, new Event('toggle'))
    await waitFor(() => {
      expect(cards[0]!.textContent).toContain('exec-evict-01:')
    })
    const fullHeightBtn = Array.from(cards[0]!.querySelectorAll('button')).find((b) => b.textContent?.trim() === '전체 높이')!
    fireEvent.click(fullHeightBtn)
    await waitFor(() => {
      expect(cards[0]!.querySelector('.kp-block-pre--expanded')).not.toBeNull()
    })

    // Open cards #2..#51 (50 more entries) to evict exec-evict-01 from MAX_TOOL_RESULT_CACHE (50)
    for (let i = 1; i < 51; i += 1) {
      cards[i]!.open = true
      fireEvent(cards[i]!, new Event('toggle'))
    }
    await waitFor(() => {
      expect(cards[50]!.textContent).toContain('exec-evict-51:')
      expect(cards[0]!.textContent).toContain('실행 결과 불러오기')
    })
    expect(fetchCounts.get('exec-evict-01')).toBe(1)

    // Clicking "실행 결과 불러오기" on evicted card #1 must re-fetch instead of no-oping
    const reloadEvictedBtn = Array.from(cards[0]!.querySelectorAll('button')).find((b) => b.textContent?.trim() === '실행 결과 불러오기')!
    fireEvent.click(reloadEvictedBtn)
    await waitFor(() => {
      expect(fetchCounts.get('exec-evict-01')).toBe(2)
      expect(cards[0]!.textContent).toContain('exec-evict-01:')
    })

    // Triggering a sessionEpoch change must reset expand & full-height state cleanly
    sessionEpoch.value = sessionEpoch.peek() + 1
    await waitFor(() => {
      const groupAfter = container.querySelector('[data-testid="chat-tool-group"] details') as HTMLDetailsElement | null
      expect(groupAfter).not.toBeNull()
      expect(groupAfter!.open).toBe(false)
      const firstCardAfter = container.querySelector('[data-testid="chat-tool-card"]') as HTMLDetailsElement
      expect(firstCardAfter.open).toBe(false)
      expect(container.querySelector('.kp-block-pre--expanded')).toBeNull()
    })
  })
})
