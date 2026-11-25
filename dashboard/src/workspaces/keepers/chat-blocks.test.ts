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
  extractDelegateCardInfo,
  findToolCallIndex,
  formatNativeCompletionSummary,
  formatNativeProgressLabel,
  formatTurnActivityLabel,
  formatTurnLaneLabel,
  formatWaitingSourceLabel,
  groupTranscriptEntries,
  mergeLatestHistoryPage,
  parseChatMessageBlocks,
  shouldRenderChatEntry,
  summarizeToolHistogram,
  upsertStreamToolCall,
} from './chat-blocks'
import {
  decodeHistoryRow,
  fetchKeeperChatHistoryPageApi,
  fetchKeeperToolResultApi,
  fetchKeeperWaitingInventoryApi,
  parseKeeperLiveObserverEvent,
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

  it('extracts <think> blocks alongside <thinking>/<thought> into thinkingText so Thinking toggle controls them', () => {
    const parsed = parseChatMessageBlocks({
      id: 'msg-think-1',
      role: 'assistant',
      content: '<think>\nCheck the failing assertion first.\n</think>\n\nFixed the edge case.',
      ts: 1_700_000_003,
    })
    expect(parsed.thinkingText).toBe('Check the failing assertion first.')
    expect(parsed.bodyText).toBe('Fixed the edge case.')
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
        return new Response(JSON.stringify({
          schema: 'masc.keeper_chat_operations.list.v1', state: 'Queued', operations: [],
        }), {
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

describe('Chat Hierarchy Grouping, Delegate Cards, Live Autonomous Turn & Waiting Inventory', () => {
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

  it('extracts Keeper Delegate metadata (including status_many operations) and collapses consecutive tool-only rows with stable IDs', () => {
    const delInfo = extractDelegateCardInfo({
      name: 'masc_keeper_delegate',
      args: JSON.stringify({
        target: { kind: 'keeper', name: 'worker-alpha' },
        prompt: 'Verify PR #54678 diff and tests.',
        artifacts: ['sha256-a', 'sha256-b'],
      }),
      result: JSON.stringify({
        operation_id: 'op-del-7',
        state: 'Queued',
        target_turn_age_s: 14.4,
      }),
    })
    expect(delInfo).toEqual({
      kind: 'delegate',
      targetKeeper: 'worker-alpha',
      targetKeepers: ['worker-alpha'],
      operationCount: 1,
      prompt: 'Verify PR #54678 diff and tests.',
      operationId: 'op-del-7',
      artifactCount: 2,
      delegateState: 'Queued',
      targetTurnAgeSec: 14,
    })

    const statusManyInfo = extractDelegateCardInfo({
      name: 'masc_keeper_delegate_status_many',
      args: JSON.stringify({
        operations: [
          { target: { kind: 'keeper', name: 'worker-alpha' }, operation_id: 'op-1' },
          { target: { kind: 'keeper', name: 'worker-beta' }, operation_id: 'op-2' },
        ],
      }),
    })
    expect(statusManyInfo).toMatchObject({
      kind: 'delegate_status',
      targetKeeper: 'worker-alpha',
      targetKeepers: ['worker-alpha', 'worker-beta'],
      operationCount: 2,
      operationId: 'op-1',
    })

    const rows = [
      decodeHistoryRow({ id: 'u1', role: 'user', content: 'Review repo', ts: 1 })!,
      decodeHistoryRow({ id: 't1', role: 'tool', content: '{"path":"a.ts"}', ts: 2, tool_call_name: 'Read' })!,
      decodeHistoryRow({ id: 't2', role: 'tool', content: '{"path":"b.ts"}', ts: 3, tool_call_name: 'Read' })!,
      decodeHistoryRow({
        id: 't3',
        role: 'tool',
        content: JSON.stringify({ target: { kind: 'keeper', name: 'worker-alpha' }, prompt: 'Check CI' }),
        ts: 4,
        tool_call_name: 'masc_keeper_delegate',
      })!,
      decodeHistoryRow({ id: 'a1', role: 'assistant', content: 'Delegated and reviewed.', ts: 5 })!,
    ]
    const parsed = rows.map((msg) => ({ msg, blocks: parseChatMessageBlocks(msg) }))
    const grouped = groupTranscriptEntries(parsed)

    expect(grouped).toHaveLength(3)
    expect(grouped[0]!.kind).toBe('message')
    expect(grouped[1]!.kind).toBe('tool_group')
    expect(grouped[2]!.kind).toBe('message')
    if (grouped[1]!.kind === 'tool_group') {
      // Stable group ID anchored to first message ID (does not remount as run grows)
      expect(grouped[1]!.id).toBe('tool-group:t1')
      expect(grouped[1]!.toolBlocks).toHaveLength(3)
      expect(grouped[1]!.toolSummary).toBe('Read ×2 · 위임(@worker-alpha)')
      expect(grouped[1]!.delegateTargets).toEqual(['worker-alpha'])
      expect(summarizeToolHistogram(grouped[1]!.toolBlocks)).toBe('Read ×2 · 위임(@worker-alpha)')
    }

    // Verify canonical OCaml lane, activity, and waiting_source labels
    expect(formatTurnLaneLabel('chat_operation')).toBe('대화 턴')
    expect(formatTurnLaneLabel('board_attention')).toBe('보드 턴')
    expect(formatTurnLaneLabel('maintenance')).toBe('유지보수 턴')
    expect(formatTurnActivityLabel('tool')).toEqual({ label: '도구 실행 중', tone: 'info' })
    expect(formatWaitingSourceLabel('event_queue_pending')).toBe('이벤트 큐')
    expect(formatWaitingSourceLabel('hitl_pending')).toBe('승인 대기')
    expect(formatWaitingSourceLabel('chat_operation_queued')).toBe('대화 대기')
    expect(formatWaitingSourceLabel('runtime_quota_spent')).toBe('할당 소진')
  })

  it('keeps a response with retained media visible alongside its tool calls', () => {
    const msg = {
      ...decodeHistoryRow({
        id: 'generated-image',
        role: 'assistant',
        content: '',
        blocks: [{ t: 'image', src: '/api/v1/media/' + 'a'.repeat(64), cap: 'Results' }],
      })!,
      toolCalls: [{ name: 'generate_image', args: '{}' }],
    }
    const entry = { msg, blocks: parseChatMessageBlocks(msg) }
    expect(entry.blocks.isToolOnly).toBe(true)
    expect(groupTranscriptEntries([entry])).toEqual([{ kind: 'message', id: msg.id, entry }])
  })

  it('merges latest history head pages without scrambling same-second timestamps or dropping earlier paginated rows', () => {
    const earlier = [
      decodeHistoryRow({ id: 'm1', role: 'user', content: 'old 1', ts: 100 })!,
      decodeHistoryRow({ id: 'm2', role: 'assistant', content: 'old 2', ts: 100 })!,
      decodeHistoryRow({ id: 'm3', role: 'user', content: 'overlap', ts: 100 })!,
    ]
    const optimistic = {
      id: 'asst-op-live',
      role: 'assistant' as const,
      content: 'streaming...',
      ts: 100,
      deliveryState: 'Streaming' as const,
    }
    const incoming = [
      decodeHistoryRow({ id: 'm3', role: 'user', content: 'overlap', ts: 100 })!,
      decodeHistoryRow({ id: 'm4', role: 'assistant', content: 'newest', ts: 100 })!,
    ]
    const merged = mergeLatestHistoryPage([...earlier, optimistic], incoming)
    expect(merged.map((m) => m.id)).toEqual(['m1', 'm2', 'm3', 'm4', 'asst-op-live'])
  })

  it('parses real OCaml Observer SSE envelopes (observation.preview + owner_key + turn_complete) strictly scoped to active Keeper', () => {
    const previewSig = parseKeeperLiveObserverEvent(
      'message',
      {
        type: 'keeper_turn_preview_changed',
        name: 'code-reviewer-sister',
        ts_unix: 1_700_000_500,
        observation: {
          owner_key: 'a'.repeat(64),
          preview: {
            status_text: 'Running grep across workspace',
            activity: 'tool',
            text_tail: 'Found 3 candidate matches',
            last_tool: 'Grep',
            updated_at_unix: 1_700_000_500,
            revision: 3,
          },
        },
      },
      'code-reviewer-sister',
    )
    expect(previewSig?.kind).toBe('turn_preview')
    if (previewSig?.kind === 'turn_preview') {
      expect(previewSig.ownerKey).toBe('a'.repeat(64))
      expect(previewSig.preview.activity).toBe('tool')
      expect(previewSig.preview.text_tail).toBe('Found 3 candidate matches')
      expect(previewSig.preview.revision).toBe(3)
    }

    // Outer envelope missing `observation.preview` must NOT synthesize a blank ghost preview
    expect(
      parseKeeperLiveObserverEvent(
        'keeper_turn_preview_changed',
        { type: 'keeper_turn_preview_changed', name: 'code-reviewer-sister', ts_unix: 1_700_000_501 },
        'code-reviewer-sister',
      ),
    ).toBeNull()

    // Unscoped keeper events (missing keeper_name/name) must NOT bleed into an active keeper
    expect(
      parseKeeperLiveObserverEvent('keeper_chat_appended', { type: 'keeper_chat_appended' }, 'code-reviewer-sister'),
    ).toBeNull()

    // An agent-core iteration can finish before the Keeper's work settles.
    expect(
      parseKeeperLiveObserverEvent(
        'keeper_turn_complete',
        { type: 'keeper_turn_complete', name: 'code-reviewer-sister' },
        'code-reviewer-sister',
      ),
    ).toBeNull()

    const receipt = {
      type: 'keeper_turn_succeeded', name: 'code-reviewer-sister', elapsed_ms: 75_123, ts_unix: 1_700_000_502,
    }
    expect(parseKeeperLiveObserverEvent('message', receipt, 'code-reviewer-sister')).toEqual({
      kind: 'turn_succeeded', elapsedMs: 75_123, atUnix: 1_700_000_502,
    })
    expect(parseKeeperLiveObserverEvent('message', receipt, 'another-keeper')).toBeNull()
    expect(parseKeeperLiveObserverEvent('message', { ...receipt, elapsed_ms: -1 }, 'code-reviewer-sister')).toBeNull()

    const otherKeeperSig = parseKeeperLiveObserverEvent(
      'keeper_turn_preview_changed',
      {
        name: 'unrelated-keeper',
        observation: {
          owner_key: 'b'.repeat(64),
          preview: { status_text: 'noop', activity: 'waiting', text_tail: '', updated_at_unix: 1 },
        },
      },
      'code-reviewer-sister',
    )
    expect(otherKeeperSig).toBeNull()

    const pulseSig = parseKeeperLiveObserverEvent(
      'keeper_tool_call',
      {
        keeper_name: 'code-reviewer-sister',
        tool_name: 'Read',
        execution_mode: 'concurrent',
        batch_size: 4,
        disposition: 'completed',
      },
      'code-reviewer-sister',
    )
    expect(pulseSig?.kind).toBe('tool_pulse')
    if (pulseSig?.kind === 'tool_pulse') {
      expect(pulseSig.pulse.executionMode).toBe('concurrent')
      expect(pulseSig.pulse.batchSize).toBe(4)
    }

    expect(
      parseKeeperLiveObserverEvent('keeper_chat_appended', { keeper_name: 'code-reviewer-sister' }, 'code-reviewer-sister'),
    ).toEqual({ kind: 'chat_appended' })
    expect(
      parseKeeperLiveObserverEvent('keeper_waiting_inventory_changed', { queue_kind: 'event_queue' }, 'code-reviewer-sister'),
    ).toBeNull()
    expect(
      parseKeeperLiveObserverEvent('keeper_waiting_inventory_changed',
        { keeper_name: 'code-reviewer-sister', queue_kind: 'chat_operation' }, 'code-reviewer-sister'),
    ).toEqual({ kind: 'waiting_changed', queueChanged: true })
  })

  it('renders grouped tool activity, accessible delegate jump outside summary, live autonomous preview card, and waiting inventory strip', async () => {
    const mockFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/chat/history/page')) {
        return new Response(
          JSON.stringify({
            messages: [
              { id: 'u-1', role: 'user', content: 'Audit PR', ts: 10 },
              { id: 't-1', role: 'tool', content: '{"path":"a.ml"}', ts: 11, tool_call_name: 'Read' },
              {
                id: 't-2',
                role: 'tool',
                content: JSON.stringify({ target: { kind: 'keeper', name: 'worker-alpha' }, prompt: 'Run security check' }),
                ts: 12,
                tool_call_name: 'masc_keeper_delegate',
                execution_id: 'exec-del-pending',
              },
              {
                id: 'a-1',
                role: 'assistant',
                content: 'Done auditing.',
                ts: 13,
                blocks: [
                  { t: 'thinking', content: 'Combining findings from both tools.' },
                  {
                    t: 'trace',
                    trace: [
                      { kind: 'tool', name: 'Read', status: 'ok', args: { path: 'x.ts' } },
                      { kind: 'tool', name: 'Grep', status: 'ok', args: { pattern: 'foo' } },
                    ],
                  },
                ],
              },
            ],
            has_more: false,
            next_cursor: null,
          }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        )
      }
      if (url.includes('/tool-result')) {
        return new Response(
          JSON.stringify({
            keeper: 'code-reviewer-sister',
            execution_id: 'exec-del-pending',
            state: 'pending',
          }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        )
      }
      if (url.includes('/waiting-inventory')) {
        return new Response(
          JSON.stringify({
            schema: 'masc.keeper_waiting_inventory.v1',
            keeper_count: 1,
            waiting_keeper_count: 1,
            row_count: 1,
            total_row_count: 1,
            oldest_age_seconds: 22,
            rows: [
              {
                keeper_name: 'code-reviewer-sister',
                source: 'event_queue_pending',
                waiting_on: 'op-del-99',
                what: 'Waiting for security check reply',
                wake_producer: 'delegate_completion_wake',
                since: 1_700_000_000,
                due_at: null,
                next_action: 'Wake asker on completion',
              },
            ],
          }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        )
      }
      if (url.includes('/chat/operations')) {
        return Response.json({
          schema: 'masc.keeper_chat_operations.list.v1', state: 'Queued', operations: [],
        })
      }
      return new Response(JSON.stringify({}), { status: 200, headers: { 'Content-Type': 'application/json' } })
    })
    vi.stubGlobal('fetch', mockFetch)

    const waitRes = await fetchKeeperWaitingInventoryApi('code-reviewer-sister')
    expect(waitRes.ok).toBe(true)
    if (waitRes.ok) {
      expect(waitRes.value?.rows).toHaveLength(1)
    }

    const onSelectKeeper = vi.fn()
    const keeper = makeRosterKeeper({
      active_turn: {
        lane: 'autonomous',
        turn_ref: 'tr-9#4',
        started_at_unix: Math.floor(Date.now() / 1000) - 10,
        phase: 'tool',
        tool_in_flight: null,
        elapsed_ms: 10_000,
        preview: {
          status_text: 'Checking build output',
          activity: 'tool',
          text_tail: 'Evaluating diff hunks',
          last_tool: 'Execute',
          updated_at_unix: Math.floor(Date.now() / 1000),
          revision: 2,
        },
      },
    })

    const { container } = render(
      html`<${KeeperChatTab} keeper=${keeper} onInspect=${vi.fn()} onSelectKeeper=${onSelectKeeper} onMutated=${vi.fn()} />`,
    )

    await waitFor(() => {
      // Consecutive tool rows collapsed into a single hierarchical group
      const group = container.querySelector('[data-testid="chat-tool-group"]')
      expect(group).not.toBeNull()
      expect(group!.textContent).toContain('도구 활동 · 2건')
      expect(group!.textContent).toContain('Read · 위임(@worker-alpha)')

      // Assistant multi-tool trace wrapped inside turn trace rail
      const turnTrace = container.querySelector('[data-testid="chat-turn-trace"]')
      expect(turnTrace).not.toBeNull()
      expect(turnTrace!.querySelector('[data-testid="chat-turn-tool-group"]')).not.toBeNull()

      // The snapshot is retained without a live Observer in this fixture.
      const liveCard = container.querySelector('[data-testid="chat-live-turn-card"]')
      expect(liveCard).not.toBeNull()
      expect(liveCard!.getAttribute('aria-live')).toBeNull()
      expect(liveCard!.textContent).toContain('자율 턴')
      expect(container.querySelector('.kp-turn-progress-active')?.textContent).toContain('마지막 확인')
      expect(container.querySelector('.kp-turn-progress-active')?.textContent).toContain('도구 실행 중')
      expect(liveCard!.textContent).toContain('최근 도구 · Execute')
      expect(liveCard!.textContent).toContain('Evaluating diff hunks')

      // Waiting inventory strip rendered with canonical OCaml source label
      const waitStrip = container.querySelector('[data-testid="chat-waiting-strip"]')
      expect(waitStrip).not.toBeNull()
      expect(waitStrip!.textContent).toContain('대기 · 위임 현황 (1건)')
      expect(waitStrip!.textContent).toContain('이벤트 큐')
    })

    // Accessibility: zero <button> elements nested inside <summary>
    expect(container.querySelectorAll('summary button')).toHaveLength(0)

    // Clicking the delegate jump button navigates to the delegated target Keeper
    const jumpBtn = container.querySelector('.kp-delegate-jump') as HTMLButtonElement
    expect(jumpBtn).not.toBeNull()
    expect(jumpBtn.getAttribute('aria-label')).toContain('worker-alpha')
    fireEvent.click(jumpBtn)
    expect(onSelectKeeper).toHaveBeenCalledWith('worker-alpha')

    // Opening the delegate card triggers /tool-result and renders full pending + retry parity
    const delDetails = container.querySelector('[data-testid="chat-delegate-card"] details') as HTMLDetailsElement
    expect(delDetails).not.toBeNull()
    delDetails.open = true
    fireEvent(delDetails, new Event('toggle'))
    await waitFor(() => {
      expect(delDetails.textContent).toContain('도구 실행 중 — 결과 준비 대기 중…')
      expect(delDetails.textContent).toContain('다시 확인')
    })
  })
})
