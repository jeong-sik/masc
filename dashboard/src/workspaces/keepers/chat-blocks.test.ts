import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { html } from 'htm/preact'
import { render, fireEvent, waitFor, cleanup } from '@testing-library/preact'
import { authSession, resetAuthStateForTests } from '../../core/auth'
import { resetObserverStateForTests } from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { releaseAllViewStreams } from '../../core/view-stream-slot'
import {
  DEFAULT_CHAT_BLOCK_PREFS,
  dedupeHistoryToolRows,
  findToolCallIndex,
  formatNativeCompletionSummary,
  formatNativeProgressLabel,
  parseChatMessageBlocks,
  shouldRenderChatEntry,
  upsertStreamToolCall,
} from './chat-blocks'
import {
  decodeHistoryRow,
  fetchKeeperChatHistoryPageApi,
  fetchKeeperToolResultApi,
  streamKeeperChat,
} from './keepers-api'
import { KeeperChatTab } from './keeper-chat-tab'
import type { KeeperRosterItem } from './types'

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

describe('Chat Blocks & History Decoding — Empty Tool Toggle & Blocks Wire Parity', () => {
  it('preserves raw argument JSON from persisted role=tool rows instead of rendering an empty toggle body', () => {
    const row = decodeHistoryRow({
      id: 'msg-tool-1',
      role: 'tool',
      content: JSON.stringify({ path: 'lib/keeper/keeper_chat_store.ml', start_line: 1 }),
      ts: 1_700_000_001,
      tool_call_name: 'Read',
      execution_id: 'exec-read-42',
    })
    expect(row).not.toBeNull()
    expect(row!.executionId).toBe('exec-read-42')

    const parsed = parseChatMessageBlocks(row!)
    expect(parsed.toolBlocks).toHaveLength(1)
    expect(parsed.toolBlocks[0]!.name).toBe('Read')
    expect(parsed.toolBlocks[0]!.executionId).toBe('exec-read-42')
    expect(parsed.toolBlocks[0]!.args).toContain('"path": "lib/keeper/keeper_chat_store.ml"')
    expect(parsed.bodyText).toBe('')
  })

  it('preserves full role=tool input parameters including input/output/status keys without hijacking result or status', () => {
    const row = decodeHistoryRow({
      id: 'msg-delegate-1',
      role: 'tool',
      content: JSON.stringify({
        command: 'cp a b',
        input: 'src.txt',
        output: 'dst.txt',
        status: 'draft',
      }),
      ts: 1_700_000_002,
      tool_call_name: 'Execute',
      execution_id: 'exec-exec-99',
    })
    const parsed = parseChatMessageBlocks(row!)
    expect(parsed.toolBlocks).toHaveLength(1)
    expect(parsed.toolBlocks[0]!.args).toContain('"command": "cp a b"')
    expect(parsed.toolBlocks[0]!.args).toContain('"input": "src.txt"')
    expect(parsed.toolBlocks[0]!.args).toContain('"output": "dst.txt"')
    // Must NOT mislabel input parameter `output` as `result` or `status` as tool execution status
    expect(parsed.toolBlocks[0]!.result).toBeUndefined()
    expect(parsed.toolBlocks[0]!.status).toBeUndefined()
    expect(parsed.toolBlocks[0]!.executionId).toBe('exec-exec-99')
  })

  it('decodes server blocks (thinking + trace think/reason/tool) and autonomous_turn markers from history rows', () => {
    const row = decodeHistoryRow({
      id: 'msg-asst-1',
      role: 'assistant',
      content: 'Checked the repo.',
      ts: 1_700_000_010,
      turn_ref: 'tr-1#7',
      blocks: [
        { t: 'thinking', content: 'First inspect README and status.' },
        {
          t: 'trace',
          trace: [
            { kind: 'think', text: 'Need exact line numbers.' },
            { kind: 'reason', text: 'Plan verified', detail: 'Two files to inspect.' },
            {
              kind: 'tool',
              name: 'Grep',
              tool_call_id: 'tc-grep-1',
              execution_id: 'exec-grep-1',
              status: 'ok',
              dur: '42ms',
              args: { pattern: 'TOOL_CALL_END' },
              result: { matches: 3 },
            },
          ],
        },
      ],
    })
    expect(row).not.toBeNull()
    expect(row!.thinking).toContain('First inspect README and status.')
    expect(row!.thinking).toContain('Need exact line numbers.')
    expect(row!.thinking).toContain('Plan verified')
    expect(row!.toolCalls).toHaveLength(1)
    expect(row!.toolCalls![0]).toMatchObject({
      id: 'tc-grep-1',
      executionId: 'exec-grep-1',
      name: 'Grep',
      status: 'completed',
      duration: '42ms',
    })
    expect(row!.toolCalls![0]!.args).toContain('"pattern": "TOOL_CALL_END"')
    expect(row!.toolCalls![0]!.result).toContain('"matches": 3')

    const autoRow = decodeHistoryRow({
      id: 'autonomous:turn-7',
      role: 'assistant',
      content: 'Completed scheduled audit.',
      ts: 1_700_000_020,
      autonomous_turn: { turn_id: 'turn-7' },
    })
    expect(autoRow!.autonomousTurn).toBe(true)
    expect(autoRow!.kind).toBe('autonomous')
  })

  it('matches parallel tool calls cleanly by (toolStreamScope, toolCallBlockIndex) without cross-contamination', () => {
    let list = upsertStreamToolCall(
      undefined,
      { streamKey: 'occ:0:0' },
      (c) => c,
      () => ({ streamKey: 'occ:0:0', name: 'Read', status: 'running' }),
    )
    list = upsertStreamToolCall(
      list,
      { streamKey: 'occ:0:1' },
      (c) => c,
      () => ({ streamKey: 'occ:0:1', name: 'Grep', status: 'running' }),
    )
    // Args arriving out of order for block 0 without toolCallId must NOT mutate block 1
    list = upsertStreamToolCall(
      list,
      { streamKey: 'occ:0:0' },
      (c) => ({ ...c, args: '{"path":"a.ml"}' }),
    )
    expect(findToolCallIndex(list, { streamKey: 'occ:0:0' })).toBe(0)
    expect(findToolCallIndex(list, { streamKey: 'occ:0:1' })).toBe(1)
    expect(list[0]!.args).toBe('{"path":"a.ml"}')
    expect(list[1]!.args).toBeUndefined()

    // Cross-scope collision guard: sequential provider toolCallId `call_0` in stream_scope 1 must NOT overwrite scope 0
    let scoped = upsertStreamToolCall(
      undefined,
      { toolCallId: 'call_0', streamKey: 'occ:0:0' },
      (c) => c,
      () => ({ id: 'call_0', streamKey: 'occ:0:0', name: 'Read', status: 'completed' }),
    )
    scoped = upsertStreamToolCall(
      scoped,
      { toolCallId: 'call_0', streamKey: 'occ:1:0' },
      (c) => ({ ...c, name: 'Grep', status: 'running' }),
      () => ({ id: 'call_0', streamKey: 'occ:1:0', name: 'Grep', status: 'running' }),
    )
    expect(scoped).toHaveLength(2)
    expect(scoped[0]!.name).toBe('Read')
    expect(scoped[1]!.name).toBe('Grep')
  })

  it('formats native tool progress and completion payloads cleanly', () => {
    expect(formatNativeProgressLabel({ kind: 'heartbeat_reported', elapsed_seconds: 12 })).toBe('실행 중 (12s)')
    expect(formatNativeProgressLabel({ kind: 'output_observed', byte_count: 2048 })).toBe('출력 2,048B')
    expect(formatNativeProgressLabel({ kind: 'message_reported', message: 'Searching docs' })).toBe('Searching docs')
    expect(
      formatNativeCompletionSummary({ kind: 'result_received', is_error: true, exit_code: 1 }),
    ).toEqual({ status: 'error', summary: 'exit 1' })
    expect(
      formatNativeCompletionSummary({ kind: 'completion_reported', exit_code: 0 }),
    ).toEqual({ status: 'completed', summary: 'exit 0' })
  })

  it('deduplicates cross-row role=tool entries against assistant blocks[].trace tool steps sharing execution_id', async () => {
    const toolRow = decodeHistoryRow({
      id: 'msg-tool-dup',
      role: 'tool',
      content: JSON.stringify({ path: 'lib/foo.ml', start_line: 10 }),
      ts: 1_700_000_050,
      tool_call_name: 'Read',
      execution_id: 'exec-shared-1',
    })!
    const assistantRow = decodeHistoryRow({
      id: 'msg-asst-dup',
      role: 'assistant',
      content: 'Read foo.ml and verified the guard.',
      ts: 1_700_000_051,
      blocks: [
        {
          t: 'trace',
          trace: [
            {
              kind: 'tool',
              name: 'Read',
              execution_id: 'exec-shared-1',
              status: 'ok',
              dur: '18ms',
            },
          ],
        },
      ],
    })!
    const standaloneToolRow = decodeHistoryRow({
      id: 'msg-tool-standalone',
      role: 'tool',
      content: JSON.stringify({ pattern: 'keep_me' }),
      ts: 1_700_000_052,
      tool_call_name: 'Grep',
      execution_id: 'exec-standalone-2',
    })!

    const deduped = dedupeHistoryToolRows([toolRow, assistantRow, standaloneToolRow])
    expect(deduped.map((e) => e.id)).toEqual(['msg-asst-dup', 'msg-tool-standalone'])
    expect(deduped[0]!.toolCalls).toHaveLength(1)
    expect(deduped[0]!.toolCalls![0]).toMatchObject({
      executionId: 'exec-shared-1',
      name: 'Read',
      status: 'completed',
      duration: '18ms',
    })
    // Args omitted from the trace step were enriched from the suppressed role=tool row
    expect(deduped[0]!.toolCalls![0]!.args).toContain('"path": "lib/foo.ml"')

    // Also verify fetchKeeperChatHistoryPageApi applies the same cross-row deduplication end-to-end
    const mockFetch = vi.fn(async () =>
      new Response(
        JSON.stringify({
          messages: [
            {
              id: 'msg-tool-dup',
              role: 'tool',
              content: JSON.stringify({ path: 'lib/foo.ml' }),
              ts: 1_700_000_050,
              tool_call_name: 'Read',
              execution_id: 'exec-shared-1',
            },
            {
              id: 'msg-asst-dup',
              role: 'assistant',
              content: 'Checked.',
              ts: 1_700_000_051,
              blocks: [
                {
                  t: 'trace',
                  trace: [
                    { kind: 'tool', name: 'Read', execution_id: 'exec-shared-1', status: 'ok' },
                  ],
                },
              ],
            },
          ],
          has_more: false,
          next_cursor: null,
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    )
    vi.stubGlobal('fetch', mockFetch)
    try {
      const pageRes = await fetchKeeperChatHistoryPageApi('code-reviewer-sister', undefined, 40)
      expect(pageRes.ok).toBe(true)
      if (pageRes.ok) {
        expect(pageRes.value.messages).toHaveLength(1)
        expect(pageRes.value.messages[0]!.id).toBe('msg-asst-dup')
        expect(pageRes.value.messages[0]!.toolCalls).toHaveLength(1)
        expect(pageRes.value.messages[0]!.toolCalls![0]!.args).toContain('"path": "lib/foo.ml"')
      }
    } finally {
      vi.restoreAllMocks()
    }
  })

  it('hides completely empty non-streaming entries without error detail via shouldRenderChatEntry', () => {
    const emptyRow = decodeHistoryRow({
      id: 'msg-empty',
      role: 'assistant',
      content: '   ',
      ts: 1_700_000_060,
    })!
    const parsed = parseChatMessageBlocks(emptyRow)
    expect(shouldRenderChatEntry(emptyRow, parsed, DEFAULT_CHAT_BLOCK_PREFS)).toBe(false)
    expect(
      shouldRenderChatEntry({ ...emptyRow, deliveryState: 'Streaming' }, parsed, DEFAULT_CHAT_BLOCK_PREFS),
    ).toBe(true)
    expect(
      shouldRenderChatEntry({ ...emptyRow, errorDetail: 'stream cut' }, parsed, DEFAULT_CHAT_BLOCK_PREFS),
    ).toBe(true)
  })
})

describe('Keepers AG-UI Live Stream & On-Demand Tool Result Hydration', () => {
  beforeEach(() => {
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
  })

  afterEach(() => {
    cleanup()
    releaseAllViewStreams()
    vi.restoreAllMocks()
  })

  it('parses thinking snapshot, parallel tool snapshots, tool end, result ready, and native tool events in streamKeeperChat', async () => {
    const frames = [
      { type: 'CUSTOM', name: 'KEEPER_MODEL_CONTENT_ACTIVITY', value: { channel: 'thinking' } },
      { type: 'CUSTOM', name: 'KEEPER_THINKING_SNAPSHOT', value: { index: 0, snapshot: 'Thinking via snapshot', response: { content_generation: 0, stream_scope: 1 } } },
      { type: 'TOOL_CALL_START', toolStreamScope: 0, toolCallBlockIndex: 0, toolCallName: 'Read' },
      { type: 'TOOL_CALL_START', toolStreamScope: 0, toolCallBlockIndex: 1, toolCallName: 'Grep' },
      { type: 'TOOL_CALL_ARGS', toolStreamScope: 0, toolCallBlockIndex: 0, snapshot: '{"path":"a.ts"}' },
      { type: 'TOOL_CALL_ARGS', toolStreamScope: 0, toolCallBlockIndex: 1, delta: '{"pattern":"foo"}' },
      { type: 'TOOL_CALL_END', toolStreamScope: 0, toolCallBlockIndex: 0 },
      { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY', value: { toolStreamScope: 0, toolCallBlockIndex: 0, executionId: 'exec-0' } },
      { type: 'CUSTOM', name: 'KEEPER_NATIVE_TOOL_START', value: { toolStreamScope: 0, toolCallBlockIndex: 2, toolCallName: 'web_search' } },
      { type: 'CUSTOM', name: 'KEEPER_NATIVE_TOOL_PROGRESS', value: { toolStreamScope: 0, toolCallBlockIndex: 2, toolCallName: 'web_search', progress: { kind: 'heartbeat_reported', elapsed_seconds: 5 } } },
      { type: 'CUSTOM', name: 'KEEPER_NATIVE_TOOL_END', value: { toolStreamScope: 0, toolCallBlockIndex: 2, toolCallName: 'web_search', completion: { kind: 'completion_reported', exit_code: 0 } } },
      { type: 'TEXT_MESSAGE_CONTENT', delta: 'Done.' },
      { type: 'RUN_FINISHED' },
    ]
    const sse = frames.map((f) => `data: ${JSON.stringify(f)}\n\n`).join('')
    const mockFetch = vi.fn(async () => new Response(sse, { status: 200, headers: { 'Content-Type': 'text/event-stream' } }))

    const seen: string[] = []
    const res = await streamKeeperChat({
      keeper: 'code-reviewer-sister',
      message: 'Check files',
      operationId: 'op-stream-1',
      mode: { kind: 'queue' },
      fetchImpl: mockFetch as unknown as typeof fetch,
      callbacks: {
        onModelActivity: (ch) => seen.push(`activity:${ch}`),
        onThinkingSnapshot: (snap, idx) => seen.push(`think-snap:${idx}:${snap}`),
        onToolStart: (name, _id, key) => seen.push(`tool-start:${name}:${key}`),
        onToolArgsSnapshot: (_id, snap, key) => seen.push(`args-snap:${key}:${snap}`),
        onToolArgsDelta: (_id, delta, key) => seen.push(`args-delta:${key}:${delta}`),
        onToolEnd: (_id, key) => seen.push(`tool-end:${key}`),
        onToolResultReady: (info) => seen.push(`result-ready:${info.streamKey}:${info.executionId}`),
        onNativeToolProgress: (info) => seen.push(`native-prog:${info.streamKey}:${info.progressLabel}`),
        onNativeToolEnd: (info) => seen.push(`native-end:${info.streamKey}:${info.status}`),
        onTextDelta: (d) => seen.push(`text:${d}`),
        onFinished: () => seen.push('finished'),
      },
    })

    expect(res).toEqual({ terminal: true, error: null })
    expect(seen).toEqual([
      'activity:thinking',
      'think-snap:0:1:0:Thinking via snapshot',
      'tool-start:Read:occ:0:0',
      'tool-start:Grep:occ:0:1',
      'args-snap:occ:0:0:{"path":"a.ts"}',
      'args-delta:occ:0:1:{"pattern":"foo"}',
      'tool-end:occ:0:0',
      'result-ready:occ:0:0:exec-0',
      'tool-start:web_search:occ:0:2',
      'native-prog:occ:0:2:실행 중 (5s)',
      'native-end:occ:0:2:completed',
      'text:Done.',
      'finished',
    ])
  })

  it('hydrates live KEEPER_TOOL_RESULT_READY and persisted role=tool cards on toggle via /tool-result', async () => {
    const requestedUrls: string[] = []
    const mockFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      requestedUrls.push(url)
      if (url.includes('/chat/history/page')) {
        return new Response(
          JSON.stringify({
            messages: [
              {
                id: 'hist-tool-1',
                role: 'tool',
                content: JSON.stringify({ path: 'README.md' }),
                ts: 1_700_000_000,
                tool_call_name: 'Read',
                execution_id: 'exec-hist-1',
              },
            ],
            has_more: false,
            next_cursor: null,
          }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        )
      }
      if (url.includes('/chat/operations')) {
        return new Response(JSON.stringify({ operations: [] }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.includes('/tool-result')) {
        const execId = new URL(url, 'http://localhost').searchParams.get('execution_id')
        return new Response(
          JSON.stringify({
            keeper: 'code-reviewer-sister',
            execution_id: execId,
            state: 'page',
            source_id: 'src-1',
            body_sha256: 'abc',
            recorded_bytes: 18,
            is_error: false,
            page: {
              offset: 0,
              next_offset: 18,
              total_bytes: 18,
              eof: true,
              content: execId === 'exec-hist-1' ? '{"lines": 120}' : 'live tool stdout',
              encoding: 'utf-8',
            },
          }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        )
      }
      if (url.includes('/api/v1/keepers/chat/stream')) {
        const frames = [
          { type: 'CUSTOM', name: 'KEEPER_THINKING_SNAPSHOT', value: { index: 0, snapshot: 'Inspecting live status' } },
          { type: 'TOOL_CALL_START', toolStreamScope: 0, toolCallBlockIndex: 0, toolCallName: 'Execute' },
          { type: 'TOOL_CALL_ARGS', toolStreamScope: 0, toolCallBlockIndex: 0, snapshot: '{"command":"git status"}' },
          { type: 'TOOL_CALL_END', toolStreamScope: 0, toolCallBlockIndex: 0 },
          { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY', value: { toolStreamScope: 0, toolCallBlockIndex: 0, executionId: 'exec-live-1' } },
          { type: 'TEXT_MESSAGE_CONTENT', delta: 'All clean.' },
          { type: 'RUN_FINISHED' },
        ]
        const sse = frames.map((f) => `data: ${JSON.stringify(f)}\n\n`).join('')
        return new Response(sse, { status: 200, headers: { 'Content-Type': 'text/event-stream' } })
      }
      return new Response(JSON.stringify({}), { status: 200, headers: { 'Content-Type': 'application/json' } })
    })
    vi.stubGlobal('fetch', mockFetch)

    // Verify direct tool-result decoder as well
    const directRes = await fetchKeeperToolResultApi('code-reviewer-sister', 'exec-hist-1')
    expect(directRes.ok).toBe(true)
    if (directRes.ok && directRes.value.state === 'page') {
      expect(directRes.value.content).toBe('{"lines": 120}')
    }

    const { container, getByLabelText } = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )

    // Wait for persisted role=tool card to appear with non-empty args
    await waitFor(() => {
      const card = container.querySelector('[data-testid="chat-tool-card"]')
      expect(card).not.toBeNull()
      expect(card!.textContent).toContain('README.md')
    })

    // Toggle persisted role=tool card open -> triggers on-demand /tool-result fetch
    const histCard = container.querySelector('[data-testid="chat-tool-card"]') as HTMLDetailsElement
    histCard.open = true
    fireEvent(histCard, new Event('toggle'))

    await waitFor(() => {
      expect(histCard.textContent).toContain('"lines": 120')
    })

    // Send a live message -> multi-step thinking snapshot + live tool snapshot + lazy KEEPER_TOOL_RESULT_READY on toggle
    const input = getByLabelText('Keeper 채팅 입력') as HTMLTextAreaElement
    fireEvent.input(input, { target: { value: 'Check git status' } })
    fireEvent.keyDown(input, { key: 'Enter' })

    await waitFor(() => {
      expect(container.textContent).toContain('Inspecting live status')
      expect(container.textContent).toContain('git status')
      expect(container.textContent).toContain('All clean.')
    })
    // No eager fetch storm before user opens the tool card
    expect(requestedUrls.some((u) => u.includes('/tool-result?execution_id=exec-live-1'))).toBe(false)

    // Toggling the live tool card open lazily fetches /tool-result
    const allCards = Array.from(container.querySelectorAll('[data-testid="chat-tool-card"]')) as HTMLDetailsElement[]
    const liveCard = allCards.find((el) => el.textContent?.includes('Execute'))!
    expect(liveCard).toBeDefined()
    liveCard.open = true
    fireEvent(liveCard, new Event('toggle'))

    await waitFor(() => {
      expect(liveCard.textContent).toContain('live tool stdout')
    })
    expect(requestedUrls.some((u) => u.includes('/tool-result?execution_id=exec-live-1'))).toBe(true)
  })
})
