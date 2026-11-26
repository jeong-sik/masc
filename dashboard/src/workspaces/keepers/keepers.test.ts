// @vitest-environment jsdom

import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { html } from 'htm/preact'
import { act, render, fireEvent, waitFor, cleanup } from '@testing-library/preact'
import { formatObserved, observedFailed, observedValue, resourceCache } from '../../core/resource-cache'
import { authSession, bumpSessionEpoch, currentSessionEpoch, resetAuthStateForTests } from '../../core/auth'
import { observerConnected, resetObserverStateForTests, startObserverStream } from '../../core/observer'
import { setStoredToken } from '../../lib/dashboard-bearer'
import { resetPortraitCacheForTests } from '../../lib/portrait-cache'
import {
  buildChatStreamRequestBody,
  buildPortraitPreviewUrl,
  decodeChatJournalPage,
  decodeKeeperMemoryFacts,
  decodeKeeperRoster,
  fetchKeeperChatHistoryPageApi,
  fetchKeeperTurnRecordsApi,
  filterAndSortRoster,
  formatCandleMilli,
  formatContextDetail,
  isKeeperPathResting,
  loadKeeperRoster,
  readKeeperRosterSources,
  observeRosterContextPct,
  parseOrdinaryMemoryBranch,
  parseSourceBoundMemoryBranch,
  reconstructJournalReply,
  streamKeeperChat,
  transcribeVoiceAudio,
} from './keepers-api'
import {
  buildContextFillSeries,
  computePromptCacheSegments,
  KeeperDebugCompanion,
} from './keeper-debug-companion'
import { releaseAllViewStreams, getActiveViewStreamKey } from '../../core/view-stream-slot'
import { KeeperChatTab } from './keeper-chat-tab'
import { KeeperToolCallInspector } from './keeper-tool-call-inspector'
import { toolResultMarkdownPreview } from './chat-blocks'
import { KeeperHeader, isKeeperBooted } from './keeper-header'
import { KeeperMemoryTab } from './keeper-memory-tab'
import { KeeperPortraitCandleTab } from './keeper-portrait-candle-tab'
import { KeeperWorkSandboxTab } from './keeper-work-sandbox-tab'
import { KeeperConfigTab } from './keeper-config-tab'
import { KeepersWorkspace } from './index'
import type { KeeperRosterItem, KeeperToolCallEntry } from './types'
import type { TurnRecordEntry } from '../../api/dashboard-turn-records'

const queuedOperations = (
  sequences: readonly number[] = [],
  messageFor = (sequence: number) => `Pending request ${sequence}`,
) => ({
  schema: 'masc.keeper_chat_operations.list.v1',
  state: 'Queued',
  operations: sequences.map((sequence) => ({
    schema: 'masc.keeper_chat_operation.v1',
    operation_id: `queued-${sequence}`,
    sequence: String(sequence),
    created_at: sequence,
    state: 'Queued',
    input: {
      schema: 'masc.keeper_chat_operation.input.v1',
      message: messageFor(sequence),
      user_blocks: [{ type: 'text', text: messageFor(sequence) }],
      turn_instructions: null,
      surface_context: null,
      attachments: [],
    },
  })),
})

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
    context_ratio: 0.54,
    context_tokens: 108_000,
    context_max: 200_000,
    context_unavailable_reason: null,
    runtime_blocker_summary: null,
    last_failure: null,
    directory_issue: null,
    turns_24h: 42,
    candle_balance_milli: '12500',
    portrait_equipment: {
      face: 'glasses',
      neck: 'bare_neck',
      head: 'crown',
      hand: 'empty_hand',
      base: 'no_dish',
    },
    chat_control_token: 'ctrl-tok-1',
    active_turn: null,
    ...overrides,
  }
}

describe('Keepers Workspace — Pure Contracts & Parsers', () => {
  it('sorts and filters Keeper Roster across Companies, Attention, and 24h Wall modes', () => {
    const items = [
      makeRosterKeeper({ name: 'zeta-worker', company: 'zeta', turns_24h: 10, health: 'healthy' }),
      makeRosterKeeper({ name: 'alpha-reviewer', company: 'alpha', turns_24h: 95, health: 'healthy' }),
      makeRosterKeeper({ name: 'beta-fault', company: 'beta', turns_24h: 3, health: 'failing', runtime_blocker_summary: '429' }),
    ]

    expect(filterAndSortRoster(items, 'companies', '').map((k) => k.name)).toEqual([
      'alpha-reviewer',
      'beta-fault',
      'zeta-worker',
    ])
    expect(filterAndSortRoster(items, 'attention', '')[0]!.name).toBe('beta-fault')
    expect(filterAndSortRoster(items, 'wall24h', '')[0]!.name).toBe('alpha-reviewer')
    expect(filterAndSortRoster(items, 'companies', 'fault').map((k) => k.name)).toEqual(['beta-fault'])

    expect(formatObserved(observeRosterContextPct(makeRosterKeeper({ context_ratio: 0 })), (v) => `${v}%`)).toBe('0%')
    expect(formatObserved(observeRosterContextPct(makeRosterKeeper({ context_ratio: null })), (v) => `${v}%`)).toBe('없음')
  })

  it('builds Origin_bare Queue vs Steer (own operation_id) vs /btw payloads accurately', () => {
    const queued = buildChatStreamRequestBody({
      keeper: 'code-reviewer-sister',
      message: 'Check PR #5',
      operationId: 'op-queue-1',
      mode: { kind: 'queue' },
    })
    expect(queued).toEqual({
      request_id: 'op-queue-1',
      name: 'code-reviewer-sister',
      message: 'Check PR #5',
    })
    expect('channel' in queued).toBe(false)
    expect('admission_intent' in queued).toBe(false)

    const steered = buildChatStreamRequestBody({
      keeper: 'code-reviewer-sister',
      message: 'Pivot to tests',
      operationId: 'op-steer-9',
      mode: { kind: 'steer', controlToken: 'tok-xyz' },
    })
    expect('channel' in steered).toBe(false)
    expect(steered.admission_intent).toEqual({
      kind: 'interactive',
      control_token: 'tok-xyz',
      interrupt_token: null,
      operation_id: 'op-steer-9',
    })

    const btw = buildChatStreamRequestBody({
      keeper: 'code-reviewer-sister',
      message: 'Which commit?',
      operationId: 'op-btw-2',
      mode: { kind: 'btw' },
    })
    expect(btw.turn_instructions).toContain('/btw')
  })

  it('reconstructs cut-reply chat events respecting Cut_reply monotonic ownership & event_error', () => {
    const recovered = reconstructJournalReply([
      { kind: 'run_started' },
      { kind: 'text_delta', text: 'stale attempt ', owner: { kind: 'observed_response', contentGeneration: 0, streamScope: 1 } },
      { kind: 'runtime_attempt_started' },
      // Late superseded chunk from closed (0, 1) must be dropped without wiping attempt 2
      { kind: 'text_delta', text: 'late stale', owner: { kind: 'observed_response', contentGeneration: 0, streamScope: 1 } },
      { kind: 'text_delta', text: 'final ', owner: { kind: 'observed_response', contentGeneration: 1, streamScope: 0 } },
      // Older generation chunk arriving after (1, 0) must be dropped without wiping 'final '
      { kind: 'text_delta', text: 'out-of-order', owner: { kind: 'observed_response', contentGeneration: 0, streamScope: 2 } },
      { kind: 'text_delta', text: 'answer', owner: { kind: 'observed_response', contentGeneration: 1, streamScope: 0 } },
      { kind: 'run_finished' },
    ])
    expect(recovered).toEqual({ text: 'final answer', finished: true, error: null, executionId: null })

    // Server journal tag `event_error` must decode as error and fail recovery
    const errPage = decodeChatJournalPage(
      {
        has_more: false,
        events: [
          { event: { type: 'run_started' } },
          { event: { type: 'batch_bound', operation_id: 'op-err-1', execution_id: 'op-batch-leader' } },
          { event: { type: 'batch_bound', operation_id: 'other-op', execution_id: 'other-batch' } },
          { event: { type: 'event_error', detail: 'provider_timeout' } },
        ],
      },
      'op-err-1',
    )
    expect(reconstructJournalReply(errPage.events)).toEqual({
      text: '',
      finished: false,
      error: 'provider_timeout',
      executionId: 'op-batch-leader',
    })
  })

  it('parses 3-way discriminated memory-facts (present:false / read_error / present:true)', () => {
    expect(parseOrdinaryMemoryBranch({ present: false })).toEqual({ state: 'absent' })
    expect(parseOrdinaryMemoryBranch({ read_error: 'corrupt jsonl' })).toEqual({
      state: 'read_error',
      read_error: 'corrupt jsonl',
    })
    const okOrd = parseOrdinaryMemoryBranch({
      present: true,
      revision: 7,
      snapshot_sha256: 'abc',
      updated_at: 100,
      facts: [{ memory_id: 'm1', claim: 'Uses OKLCH', category: 'ui', first_seen: 1, last_seen: 2 }],
      support_invalidations: [],
    })
    expect(okOrd.state).toBe('present')
    if (okOrd.state === 'present') {
      expect(okOrd.facts).toHaveLength(1)
      expect(okOrd.revision).toBe(7)
    }

    expect(parseSourceBoundMemoryBranch({ present: false })).toEqual({ state: 'absent' })
    expect(parseSourceBoundMemoryBranch({ read_error: 'io_err' })).toEqual({ state: 'read_error', read_error: 'io_err' })
    const decoded = decodeKeeperMemoryFacts(
      {
        keeper: 'k1',
        ordinary: { present: false },
        source_bound: {
          present: true,
          revision: 3,
          updated_at: 200,
          facts: [{ claim: 'README states MIT', first_seen: 10, path: 'README.md', sha256: 'deadbeef' }],
          invalidations: [{ source_path: 'OLD.md', invalidated_at: 15, reason: 'source_changed' }],
        },
        events_unreadable_lines: 0,
        events_read_error: null,
      },
      'k1',
    )
    expect(decoded.ordinary.state).toBe('absent')
    expect(decoded.source_bound.state).toBe('present')
  })

  it('computes a 4-segment cache bar and detects compaction across 60 turns', () => {
    const sampleRecord: TurnRecordEntry = {
      request_observations: [],
      execution_ids: [],
      keeper: 'code-reviewer-sister',
      agent_name: 'keeper-code-reviewer-sister-agent',
      trace_id: 'tr1',
      absolute_turn: 10,
      turn_ref: 'tr1#10',
      turn_kind: 'direct',
      runtime_profile: 'default',
      usage_scope: 'per_request',
      input_provenance: 'measured_request',
      input_components: [],
      request_runtime_profile: null,
      request_body_bytes: null,
      response_observed_model_input: null,
      input_tokens: 100_000,
      cache_read_input_tokens: 70_000,
      cache_creation_input_tokens: 10_000,
      output_tokens: 5_000,
      context_window: 200_000,
      ts: 1_700_000_000,
      blocks: [],
      raw_trace_run_ref: null,
    }
    const segs = computePromptCacheSegments(sampleRecord)
    expect(segs.cacheRead).toBe(70_000)
    expect(segs.cacheCreate).toBe(10_000)
    expect(segs.uncachedInput).toBe(20_000)
    expect(segs.output).toBe(5_000)
    expect(segs.cacheHitPct).toBe(70)

    // input_tokens (100k) already includes cached tokens (70k + 10k) — must NOT double-count to 180k (90%)!
    const series = buildContextFillSeries([
      { ...sampleRecord, absolute_turn: 1, ts: 100, input_tokens: 100_000, cache_read_input_tokens: 70_000, cache_creation_input_tokens: 10_000 },
      { ...sampleRecord, absolute_turn: 2, ts: 200, input_tokens: 40_000, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
    ])
    expect(series.data[1]).toEqual([50, 20])
    expect(series.compactionTurns).toEqual([2])

    // A turn total sums every request of its turn (an ACP turn written before
    // #54872), and an input above its window is no fill either. Both are gaps,
    // not points at 100% that read the next turn as a compaction.
    const gaps = buildContextFillSeries([
      { ...sampleRecord, absolute_turn: 1, ts: 100, input_tokens: 100_000 },
      { ...sampleRecord, absolute_turn: 2, ts: 200, usage_scope: 'turn_total', input_tokens: 900_000 },
      { ...sampleRecord, absolute_turn: 3, ts: 300, input_tokens: 300_000 },
      { ...sampleRecord, absolute_turn: 4, ts: 400, input_tokens: 90_000 },
    ])
    expect(gaps.data[1]).toEqual([50, null, null, 45])
    expect(gaps.compactionTurns).toEqual([])

    // An ACP Keeper on a build before #54872 writes only turn totals: no turn
    // is a fill, so the chart gets no points and shows its empty label.
    const totals = buildContextFillSeries([
      { ...sampleRecord, absolute_turn: 1, ts: 100, usage_scope: 'turn_total', input_tokens: 1_897_206 },
      { ...sampleRecord, absolute_turn: 2, ts: 200, usage_scope: 'turn_total', input_tokens: 7_520_731 },
    ])
    expect(totals.data).toEqual([[], []])
    expect(totals.compactionTurns).toEqual([])

    // Rows with invalid/zero ts must be excluded instead of plotting absolute_turn onto the Unix time axis
    const filteredTs = buildContextFillSeries([
      { ...sampleRecord, absolute_turn: 1, ts: 0, input_tokens: 100_000 },
      { ...sampleRecord, absolute_turn: 2, ts: 1_700_000_000, input_tokens: 80_000 },
    ])
    expect(filteredTs.data).toEqual([[1_700_000_000], [40]])
  })

  it('builds Portrait preview URLs (bare item id + 5-key object) and decimal-string Candle values', () => {
    const url = buildPortraitPreviewUrl('code-reviewer-sister', 256, 'crown', {
      face: 'glasses',
      neck: 'bare_neck',
      head: 'bare_head',
      hand: 'empty_hand',
      base: 'no_dish',
    })
    const parsed = new URL(url, 'http://localhost')
    expect(parsed.pathname).toBe('/api/v1/keepers/code-reviewer-sister/portrait.png')
    expect(parsed.searchParams.get('size')).toBe('256')
    expect(parsed.searchParams.get('preview')).toBe('crown')
    expect(JSON.parse(parsed.searchParams.get('expected_equipment') ?? '{}')).toEqual({
      face: 'glasses',
      neck: 'bare_neck',
      head: 'bare_head',
      hand: 'empty_hand',
      base: 'no_dish',
    })

    expect(formatObserved(formatCandleMilli('987654321000'))).toBe('987,654,321.000')
  })

  it('uses zero raw hex colors and zero off-grid px spacing literals in keepers.css', () => {
    const cssPath = resolve(process.cwd(), 'src/workspaces/keepers/keepers.css')
    const css = readFileSync(cssPath, 'utf8')
    expect(css).not.toMatch(/#[0-9a-fA-F]{3,8}\b/)
    expect(css).not.toMatch(/\b(?:padding|margin|gap):\s*[^;]*\b(?:1|2|3|5|6|10)px\b/)
  })
})

describe('Keepers Workspace — Interactive DOM & API Flows', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    resetObserverStateForTests()
    resetPortraitCacheForTests()
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
    resetPortraitCacheForTests()
    vi.restoreAllMocks()
  })

  it('renders an explicit Markdown preview in the tool inspector and preserves literal logs', async () => {
    const source = `[masc:blob sha256=${'a'.repeat(64)} bytes=64 mime=text/markdown preview="**Report**"]`
    const entry: KeeperToolCallEntry = {
      ts: 100,
      record_kind: 'tool_call',
      keeper: 'code-reviewer-sister',
      tool: 'publish_artifact',
      duration_ms: 1,
      wire_outcome: 'ok',
      input: null,
      output: source,
    }
    const view = render(html`<${KeeperToolCallInspector} keeperName=${entry.keeper} entry=${entry} />`)
    expect(view.container.querySelector('.markdown-content strong')?.textContent).toBe('Report')
    expect(view.getByTestId('tool-call-inspector-output').textContent).toBe(source)

    const log = '[WARN]: phase\n  * worker[2]\n'
    view.rerender(html`<${KeeperToolCallInspector} keeperName=${entry.keeper} entry=${{ ...entry, output: log }} />`)
    expect(view.container.querySelector('.markdown-content')).toBeNull()
    expect(view.getByTestId('tool-call-inspector-output').textContent).toBe(log)
  })

  it('preserves literal tool output and honors stored Markdown in history and live events', async () => {
    const log = '[WARN]: phase\n  * worker[2]\n\n<log>\n'
    const marker = `[masc:blob sha256=${'a'.repeat(64)} bytes=64 mime=text/markdown preview="**report**"]`
    const results = [log, marker, '{\n  "ok": true\n}']
    const toolCalls = [
      { id: 'log', name: 'shell', result: log },
      { id: 'report', name: 'artifact', result: marker },
      { id: 'json', name: 'status', result: { ok: true } },
    ]
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      messages: [{ id: 'saved', role: 'assistant', content: 'History', tool_calls: toolCalls }],
      has_more: false,
    }), { headers: { 'Content-Type': 'application/json' } })))

    const history = await fetchKeeperChatHistoryPageApi('code-reviewer-sister')
    expect(history.ok && history.value.messages[0]?.toolCalls?.map((tool) => tool.result))
      .toEqual(results)
    expect(results.map(toolResultMarkdownPreview)).toEqual([null, '**report**', null])

    const events = [
      { type: 'TOOL_CALL_RESULT', toolCallId: 'log', content: log },
      { type: 'TOOL_CALL_RESULT', toolCallId: 'report', content: marker },
      { type: 'TOOL_CALL_RESULT', toolCallId: 'json', result: { ok: true } },
      { type: 'RUN_FINISHED' },
    ]
    const onToolResult = vi.fn()
    const live = await streamKeeperChat({
      keeper: 'code-reviewer-sister',
      message: 'Run the tools',
      operationId: 'op-tool-results',
      mode: { kind: 'queue' },
      fetchImpl: vi.fn(async () => new Response(
        events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join(''),
        { headers: { 'Content-Type': 'text/event-stream' } },
      )),
      callbacks: { onToolResult },
    })
    expect(live).toEqual({ terminal: true, error: null })
    expect(onToolResult.mock.calls.map(([id, content]) => [id, content]))
      .toEqual(toolCalls.map((tool, index) => [tool.id, results[index]]))
  })

  it('keeps stored and completed images while rejecting late response frames', async () => {
    const before = `/api/v1/media/${'a'.repeat(64)}`
    const after = `/api/v1/media/${'b'.repeat(64)}`
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      messages: [{
        id: 'saved', role: 'assistant', content: '',
        blocks: [
          { t: 'image', src: after, cap: '보고서' },
          { t: 'image', src: `//example.com${before}` },
        ],
      }],
    }), { headers: { 'Content-Type': 'application/json' } })))
    const history = await fetchKeeperChatHistoryPageApi('code-reviewer-sister')
    const workspaceEpoch = currentSessionEpoch()
    expect(history.ok && history.value.messages[0]?.retainedImages)
      .toEqual([{ path: after, caption: '보고서', workspaceEpoch }])

    const media = (contentGeneration: number, path: string) => ({
      type: 'CUSTOM', name: 'KEEPER_MEDIA_DELTA',
      value: {
        index: 0, media_type: 'image/png', source_type: 'base64', media_ref: path,
        response: { content_generation: contentGeneration, stream_scope: 1 },
      },
    })
    const events = [
      media(1, before),
      { type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED', value: {} },
      media(2, after),
      media(1, before),
      { type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_START', value: { content_generation: 3, stream_scope: 2 } },
      media(2, before),
      { type: 'RUN_FINISHED' },
    ]
    const onRetainedImages = vi.fn()
    await streamKeeperChat({
      keeper: 'code-reviewer-sister', message: 'Draw', operationId: 'op-images', mode: { kind: 'queue' },
      fetchImpl: vi.fn(async () => new Response(
        events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join(''),
        { headers: { 'Content-Type': 'text/event-stream' } },
      )),
      callbacks: { onRetainedImages },
    })
    expect(onRetainedImages.mock.calls).toEqual([
      [[{ path: before, workspaceEpoch }]],
      [[{ path: before, workspaceEpoch }, { path: after, workspaceEpoch }]],
    ])
  })

  it('attributes saved user messages to their recorded speakers', async () => {
    const messages = [
      { id: 'external', role: 'user', content: 'External message', ts: 1, speaker_name: ' Minsu ', speaker_id: 'U123', speaker_authority: 'external' },
      { id: 'peer', role: 'user', content: 'Keeper request', ts: 2, speaker_id: 'peer-keeper', speaker_authority: 'keeper' },
      { id: 'owner', role: 'user', content: 'Operator message', ts: 3, speaker_authority: 'owner' },
      { id: 'named', role: 'user', content: 'Named legacy message', ts: 4, speaker_name: 'Mina', speaker_id: 'stable-id' },
      { id: 'unattributed', role: 'user', content: 'Older message', ts: 5 },
    ]
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const payload = String(input).includes('/chat/history/page')
        ? { messages, has_more: false, next_cursor: null }
        : queuedOperations()
      return new Response(JSON.stringify(payload), {
        headers: { 'Content-Type': 'application/json' },
      })
    }))

    const { container } = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )
    await waitFor(() => {
      const speakers = Array.from(
        container.querySelectorAll('.kp-msg[data-role="user"] .kp-msg-head > span'),
        (heading) => heading.textContent?.trim(),
      )
      expect(speakers).toEqual(['Minsu (외부)', 'Keeper · peer-keeper', 'Operator', 'Mina', '사용자'])
    })
  })

  it('authorizes native Discord reply in the active Keeper chat from the authenticated shell', async () => {
    setStoredToken('fixture-admin')
    const keeper = makeRosterKeeper()
    const history = [
      {
        id: 'discord-row', role: 'user', content: 'Discord source', ts: 1,
        speaker_authority: 'external', external_message_id: '301',
        surface: { kind: 'discord', guild_id: '100', channel_id: '200', parent_channel_id: '199', thread_id: '200' },
      },
      { id: 'legacy-row', role: 'user', content: 'Legacy Discord source', ts: 2,
        speaker_authority: 'external', surface: 'discord' },
    ]
    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input), 'http://localhost')
      if (url.pathname === '/api/v1/dashboard/shell') {
        return Response.json({
          paths: { effective_base_path: '/work', effective_masc_root: '/work/.masc' },
          auth: {
            enabled: true, require_token: true, token_present: true, token_valid: true,
            token_agent: 'local-admin', effective_role: 'admin', can_keeper_msg: true,
          },
        })
      }
      if (url.pathname === '/api/v1/keepers/discord/reply') {
        const body = JSON.parse(init?.body as string)
        return Response.json({
          operation_id: body.operation_id, keeper_name: keeper.name, chat_id: 'discord-row',
          channel_id: '200', original_message_id: '301', state: 'delivered', message_id: '302',
        })
      }
      if (url.pathname.endsWith('/chat/history/page')) {
        return Response.json({ messages: history, has_more: false, next_cursor: null })
      }
      return Response.json(queuedOperations())
    })
    vi.stubGlobal('fetch', mockFetch)
    const chat = render(html`<${KeeperChatTab} keeper=${keeper} onInspect=${vi.fn()} onMutated=${vi.fn()} />`)
    fireEvent.click(await chat.findByRole('button', { name: 'Discord 답장' }))
    fireEvent.input(await chat.findByRole('textbox', { name: 'Discord 답장 내용' }), { target: { value: '답장' } })
    await waitFor(() => expect(chat.getByRole('button', { name: 'Discord로 보내기' }).hasAttribute('disabled')).toBe(false))
    fireEvent.click(chat.getByRole('button', { name: 'Discord로 보내기' }))
    expect((await chat.findByRole('link', { name: '전송한 메시지 열기' })).getAttribute('href'))
      .toBe('https://discord.com/channels/100/200/302')
    expect(mockFetch.mock.calls.filter(([input]) => String(input).startsWith('/api/v1/dashboard/shell'))).toHaveLength(1)
    const request = mockFetch.mock.calls.find(([input]) => String(input) === '/api/v1/keepers/discord/reply')?.[1]
    expect(new Headers(request?.headers).get('authorization')).toBe('Bearer fixture-admin')
    expect(mockFetch.mock.calls.some(([input]) => String(input).includes('/health?full=1'))).toBe(false)
    expect(JSON.parse(request?.body as string)).toMatchObject({
      chat_id: 'discord-row', keeper_name: keeper.name, content: '답장',
      expected_workspace: { base_path: '/work', masc_root: '/work/.masc' },
    })
    sessionStorage.clear()
  })

  it('shows requests beyond the first queue page and keeps the previous rows when refresh fails', async () => {
    let queueUnavailable = false
    const mockFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(String(input), 'http://localhost')
      if (url.pathname.endsWith('/chat/operations')) {
        const cursor = url.searchParams.get('after_sequence')
        if (queueUnavailable && cursor === '100') return Response.json({ error: 'queue unavailable' }, { status: 503 })
        if (cursor === '101') return Response.json(queuedOperations())
        if (cursor === '100') return Response.json(queuedOperations([101]))
        return Response.json(queuedOperations(Array.from({ length: 100 }, (_, index) => index + 1)))
      }
      return Response.json({ messages: [], has_more: false, next_cursor: null })
    })
    vi.stubGlobal('fetch', mockFetch)
    const chat = render(html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`)

    await chat.findByText('Pending request 101')
    expect(mockFetch.mock.calls.map(([input]) => String(input))).toContain(
      '/api/v1/keepers/code-reviewer-sister/chat/operations?state=queued&after_sequence=100',
    )

    queueUnavailable = true
    fireEvent.click(chat.getByRole('button', { name: '대기열 새로고침' }))
    await chat.findByText('이전에 조회한 대기열입니다.')
    expect(chat.getByText('Pending request 101')).toBeTruthy()
    expect(chat.getAllByRole('button', { name: '취소' }).every(button => button.hasAttribute('disabled'))).toBe(true)

    queueUnavailable = false
    fireEvent.click(chat.getByRole('button', { name: '대기열 새로고침' }))
    await waitFor(() => {
      expect(chat.getAllByRole('button', { name: '취소' }).every(button => !button.hasAttribute('disabled'))).toBe(true)
    })
    expect(chat.getByText('Pending request 101')).toBeTruthy()
  })

  it('offers a queue retry after an initial read fails without hiding chat history', async () => {
    let queueUnavailable = true
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(String(input), 'http://localhost')
      if (url.pathname.endsWith('/chat/operations')) {
        return queueUnavailable
          ? Response.json({ error: 'queue unavailable' }, { status: 503 })
          : Response.json(queuedOperations(url.searchParams.has('after_sequence') ? [] : [7]))
      }
      return Response.json({
        messages: [{ id: 'history', role: 'user', content: 'Saved chat history', ts: 1 }],
        has_more: false,
        next_cursor: null,
      })
    }))
    const chat = render(html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`)
    await chat.findByText('Saved chat history')
    await chat.findByText('대기열을 불러오지 못했습니다.')

    queueUnavailable = false
    fireEvent.click(chat.getByRole('button', { name: '대기열 새로고침' }))
    await chat.findByText('Pending request 7')
    expect(chat.getByText('Saved chat history')).toBeTruthy()
  })

  it('discards queue rows when the workspace session changes with the same Keeper name', async () => {
    let respondToNewWorkspace!: (response: Response) => void
    const nextWorkspace = new Promise<Response>((resolve) => {
      respondToNewWorkspace = resolve
    })
    let changed = false
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(String(input), 'http://localhost')
      if (url.pathname.endsWith('/chat/operations')) {
        if (url.searchParams.has('after_sequence')) return Response.json(queuedOperations())
        return changed ? nextWorkspace : Response.json(queuedOperations([1]))
      }
      return Response.json({ messages: [], has_more: false, next_cursor: null })
    }))
    const chat = render(html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`)
    await chat.findByText('Pending request 1')

    act(() => {
      changed = true
      bumpSessionEpoch()
    })
    await waitFor(() => expect(chat.queryByText('Pending request 1')).toBeNull())
    expect(chat.queryByRole('button', { name: '취소' })).toBeNull()
    respondToNewWorkspace(Response.json(queuedOperations([2])))
    await chat.findByText('Pending request 2')
  })

  it('keeps the previous Keeper queue hidden if the next Keeper read fails in the same session', async () => {
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(String(input), 'http://localhost')
      if (url.pathname.endsWith('/next-keeper/chat/operations')) {
        return Response.json({ error: 'queue unavailable' }, { status: 503 })
      }
      if (url.pathname.endsWith('/chat/operations')) {
        return Response.json(queuedOperations(url.searchParams.has('after_sequence') ? [] : [1]))
      }
      return Response.json({ messages: [], rows: [] })
    }))
    const onInspect = vi.fn()
    const onMutated = vi.fn()
    const chat = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${onInspect} onMutated=${onMutated} />`,
    )
    await chat.findByText('Pending request 1')

    const keeper = makeRosterKeeper({ name: 'next-keeper' })
    chat.rerender(html`<${KeeperChatTab} keeper=${keeper} onInspect=${onInspect} onMutated=${onMutated} />`)
    expect(chat.queryByText('Pending request 1')).toBeNull()
    await chat.findByText('대기열을 불러오지 못했습니다.')
    expect(chat.queryByText('Pending request 1')).toBeNull()
    expect(chat.queryByRole('button', { name: '취소' })).toBeNull()
  })

  it('replaces a pending queue read while leaving the concurrent history read in flight', async () => {
    const held = new Map<string, {
      signal: AbortSignal | null | undefined
      respond: (response: Response) => void
    }>()
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input), 'http://localhost')
      if (url.pathname.endsWith('/chat/operations')) {
        if (url.searchParams.has('after_sequence')) return Response.json(queuedOperations())
        if (held.has('queue')) return Response.json(queuedOperations([7]))
        return new Promise<Response>((respond) => held.set('queue', { signal: init?.signal, respond }))
      }
      if (url.pathname.endsWith('/chat/history/page')) {
        return new Promise<Response>((respond) => held.set('history', { signal: init?.signal, respond }))
      }
      return Response.json({ rows: [] })
    }))
    const chat = render(html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`)
    await waitFor(() => expect(held.size).toBe(2))

    fireEvent.click(chat.getByRole('button', { name: '대기열 새로고침' }))
    await chat.findByText('Pending request 7')
    expect(held.get('queue')?.signal?.aborted).toBe(true)
    expect(held.get('history')?.signal?.aborted).toBe(false)

    await act(async () => {
      held.get('queue')?.respond(Response.json(queuedOperations([5])))
      held.get('history')?.respond(Response.json({
        messages: [{ id: 'history', role: 'user', content: 'Saved chat history', ts: 1 }],
      }))
    })
    await chat.findByText('Saved chat history')
    expect(chat.queryByText('Pending request 5')).toBeNull()
    expect(chat.getByText('Pending request 7')).toBeTruthy()
  })

  it('follows an external chat through queue, live preview, and stored replies across observer reconnect', async () => {
    const keeper = makeRosterKeeper()
    const encoder = new TextEncoder()
    let observer: ReadableStreamDefaultController<Uint8Array> | undefined
    let browserSend: ReadableStreamDefaultController<Uint8Array> | undefined
    let browserOperationId: string | undefined
    let holdHistory = false
    const heldHistoryReads: { signal?: AbortSignal | null; release: () => void }[] = []
    const frame = (event: object) => encoder.encode(`data: ${JSON.stringify(event)}\n\n`)
    const json = (data: unknown) => new Response(JSON.stringify(data), {
      headers: { 'Content-Type': 'application/json' },
    })
    const stream = (ready: (controller: ReadableStreamDefaultController<Uint8Array>) => void) =>
      new Response(new ReadableStream({ start: ready }), {
        headers: { 'Content-Type': 'text/event-stream' },
      })
    let queue = queuedOperations()
    const messages: object[] = [{ id: 'before', role: 'assistant', content: 'Stored before opening', ts: 1 }]
    let queueReads = 0
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url === '/mcp?sse_kind=observer') return stream((c) => { observer = c })
      if (url.includes('/chat/history/page')) {
        const response = json({ messages })
        if (holdHistory) return new Promise<Response>((resolve) => {
          heldHistoryReads.push({ signal: init?.signal, release: () => resolve(response) })
        })
        return response
      }
      if (url.includes('/chat/operations')) {
        queueReads++
        return json(url.includes('after_sequence=') ? queuedOperations() : queue)
      }
      if (url.includes('/api/v1/keepers/chat/stream')) {
        browserOperationId = JSON.parse(String(init?.body)).request_id
        return stream((c) => { browserSend = c })
      }
      return json({ rows: [] })
    }))

    const initialObserver = startObserverStream()
    await waitFor(() => expect(observerConnected.value).toBe(true))
    const view = render(html`<${KeeperChatTab} keeper=${keeper} onInspect=${vi.fn()} onMutated=${vi.fn()} />`)
    await waitFor(() => expect(view.queryByText('Stored before opening')).toBeTruthy())
    const waitingChange = (keeperName: string) => frame({
      type: 'keeper_waiting_inventory_changed', keeper_name: keeperName, queue_kind: 'chat_operation',
    })
    queue = queuedOperations([2], () => 'TUI request')
    observer!.enqueue(waitingChange('other-keeper'))
    observer!.enqueue(frame({ type: 'keeper_turn_preview_changed', name: keeper.name,
      observation: { owner_key: 'owner', preview: {
        status_text: 'Processing request', activity: 'tool', text_tail: '', updated_at_unix: 2, revision: 1,
      } },
    }))
    await waitFor(() => expect(view.queryByTestId('chat-live-turn-card')).toBeTruthy())
    expect(view.queryByText('TUI request')).toBeNull()

    observer!.enqueue(waitingChange(keeper.name))
    await waitFor(() => expect(view.queryByText('TUI request')).toBeTruthy())

    const input = view.getByLabelText('Keeper 채팅 입력')
    fireEvent.input(input, { target: { value: 'Browser request' } })
    fireEvent.keyDown(input, { key: 'Enter' })
    await waitFor(() => expect(browserSend).toBeDefined())
    const beforeQueueChange = queueReads
    queue = queuedOperations()
    messages.push({ id: 'external-reply', role: 'assistant', content: 'Reply from the TUI turn', ts: 4 })
    observer!.enqueue(frame({ type: 'keeper_chat_appended', name: keeper.name }))
    observer!.enqueue(waitingChange(keeper.name))
    await waitFor(() => {
      expect(queueReads).toBeGreaterThan(beforeQueueChange)
      expect(view.queryByText('TUI request')).toBeNull()
      expect(view.queryByText('Reply from the TUI turn')).toBeTruthy()
    })

    const executionId = 'op-batch-leader'
    browserSend!.enqueue(frame({ type: 'CUSTOM', name: 'KEEPER_CHAT_BATCH_BOUND',
      value: { operation_id: browserOperationId, execution_id: executionId },
    }))
    browserSend!.enqueue(frame({ type: 'TEXT_MESSAGE_CONTENT', delta: 'Shared batch reply' }))
    await waitFor(() => expect(view.queryByText('Shared batch reply')).toBeTruthy())
    messages.push(
      { id: 'browser-user', role: 'user', content: 'Browser request', ts: 5,
        delivery_key: { kind: 'operation', operation_id: browserOperationId },
        transcript_slot: { kind: 'accepted_user' } },
      { id: 'batch-assistant', role: 'assistant', content: 'Shared batch reply', ts: 6,
        delivery_key: { kind: 'operation', operation_id: executionId },
        transcript_slot: { kind: 'terminal_result' } },
      { id: 'another-external', role: 'assistant', content: 'New external reply during batch', ts: 7 },
    )
    observer!.enqueue(frame({ type: 'keeper_chat_appended', name: keeper.name }))
    await waitFor(() => {
      expect(view.queryByText('New external reply during batch')).toBeTruthy()
      expect(view.queryAllByText('Shared batch reply')).toHaveLength(1)
      const replies = Array.from(view.container.querySelectorAll('.kp-msg-body'), (body) => body.textContent?.trim())
      expect(replies).toContain('Shared batch reply')
      expect(replies.indexOf('Shared batch reply')).toBeLessThan(replies.indexOf('New external reply during batch'))
    })

    browserSend!.enqueue(frame({ type: 'RUN_FINISHED' }))
    browserSend!.close()
    await waitFor(() => {
      expect(getActiveViewStreamKey()).toBeNull()
      expect(view.queryAllByText('Shared batch reply')).toHaveLength(1)
      expect(view.queryAllByText('Browser request')).toHaveLength(1)
      const replies = Array.from(view.container.querySelectorAll('.kp-msg-body'), (body) => body.textContent?.trim())
      expect(replies).toContain('Shared batch reply')
      expect(replies.indexOf('Shared batch reply')).toBeLessThan(replies.indexOf('New external reply during batch'))
    })

    holdHistory = true
    const historyAppend = frame({ type: 'keeper_chat_appended', name: keeper.name })
    observer!.enqueue(historyAppend)
    await waitFor(() => expect(heldHistoryReads).toHaveLength(1))
    const queueReadsBeforeGap = queueReads
    observer!.enqueue(historyAppend)
    observer!.enqueue(waitingChange(keeper.name))
    await waitFor(() => expect(queueReads).toBeGreaterThan(queueReadsBeforeGap))
    expect(heldHistoryReads).toHaveLength(1)

    holdHistory = false
    observer!.close()
    await initialObserver
    await waitFor(() => expect(observerConnected.value).toBe(false))
    messages.push({ id: 'missed-failure', role: 'request_failure', content: 'External request failed while disconnected', ts: 8 })
    const recoveredObserver = startObserverStream()
    await waitFor(() => expect(view.queryByText('External request failed while disconnected')).toBeTruthy())
    expect(heldHistoryReads[0]?.signal?.aborted).toBe(true)
    await act(async () => heldHistoryReads[0]?.release())
    expect(view.queryByText('External request failed while disconnected')).toBeTruthy()
    view.unmount()
    observer!.close()
    await recoveredObserver
  })

  it('retains an owner preview as historical after a lifecycle edge, failed read and stream gap', async () => {
    const keeper = makeRosterKeeper()
    let observer!: ReadableStreamDefaultController<Uint8Array>
    let rows: readonly object[] = []
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      if (String(input) === '/mcp?sse_kind=observer') {
        return new Response(new ReadableStream({ start: (controller) => { observer = controller } }),
          { headers: { 'Content-Type': 'text/event-stream' } })
      }
      if (String(input).endsWith('/api/v1/keepers/turns')) return Response.json({ keepers: rows })
      return Response.json({ operations: [], messages: [], rows: [] })
    }))
    const stream = startObserverStream({ autoReconnect: false })
    await waitFor(() => expect(observerConnected.value).toBe(true))
    const read = observedValue(new Map(), Date.now() - 1000)
    const props = { keeper, onInspect: vi.fn(), onMutated: vi.fn() }
    const view = render(html`<${KeeperChatTab} ...${props} turnSnapshot=${read} />`)
    const readRows = async (next: readonly object[]) => {
      rows = next
      await loadKeeperRoster('manual')
      view.rerender(html`<${KeeperChatTab} ...${props} turnSnapshot=${readKeeperRosterSources().turns} />`)
    }
    const send = (event: object) =>
      observer.enqueue(new TextEncoder().encode(`data: ${JSON.stringify({ name: keeper.name, ...event })}\n\n`))
    const preview = (revision: number) => ({
      type: 'keeper_turn_preview_changed', observation: {
        owner_key: 'A', preview: { revision, status_text: 'seen ' + revision, activity: 'waiting', updated_at_unix: 123 },
      },
    })
    const live = () => view.container.querySelector('.kp-turn-progress-active')?.getAttribute('data-live')
    const receipt = () => view.container.querySelector('.kp-turn-worked time')?.getAttribute('datetime')
    send(preview(1))
    await waitFor(() => expect(live()).toBe('true'))
    const atUnix = 1_700_000_502
    send({ type: 'keeper_turn_succeeded', elapsed_ms: 3000, ts_unix: atUnix })
    await waitFor(() => expect(receipt()).toBe(new Date(atUnix * 1000).toISOString()))
    send({ type: 'keeper_turn_changed' })
    await waitFor(() => expect(live()).toBe('false'))
    const failed = observedFailed({ kind: 'server', status: 503, code: 'read_unavailable', message: 'unavailable', retryable: true })
    view.rerender(html`<${KeeperChatTab} ...${props} turnSnapshot=${failed} />`)
    expect(view.queryByText('seen 1')).toBeTruthy()
    send(preview(1))
    send({ type: 'keeper_turn_succeeded', elapsed_ms: 1000, ts_unix: atUnix - 30 })
    send(preview(2))
    await waitFor(() => expect(live()).toBe('true'))
    await readRows([{ keeper_name: keeper.name, status: 'ok', turn: {
      owner_key: 'A', lane: 'chat', started_at_unix: Date.now() / 1000 - 15, preview_observed_through: 1,
    } }])
    expect(view.getByRole('timer')).toBeTruthy()
    await readRows([{ keeper_name: keeper.name, status: 'unavailable', turn: null }])
    expect(live()).toBe('false')
    expect(view.queryByText('seen 2')).toBeTruthy()
    await readRows([])
    expect(view.getByRole('timer')).toBeTruthy()
    expect(live()).toBe('false')
    observer.close()
    await stream
    await waitFor(() => expect(live()).toBe('false'))
    expect(view.queryByText('seen 2')).toBeTruthy()
    await readRows([{ keeper_name: keeper.name, status: 'ok', turn: null }])
    expect(live()).toBeUndefined()
    expect(receipt()).toBe(new Date(atUnix * 1000).toISOString())
  })

  it('invalidates in-flight earlier-page prepend and resets pagination when reconnect observes an authoritative empty history', async () => {
    const keeper = makeRosterKeeper()
    let observer: ReadableStreamDefaultController<Uint8Array> | undefined
    let cleared = false
    const heldEarlierReads: { signal?: AbortSignal | null; release: () => void }[] = []
    const json = (data: unknown) =>
      new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
    const stream = (onStart: (controller: ReadableStreamDefaultController<Uint8Array>) => void) =>
      new Response(new ReadableStream<Uint8Array>({ start: onStart }), {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      })

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url === '/mcp?sse_kind=observer') return stream((c) => { observer = c })
      if (url.includes('/chat/history/page')) {
        if (url.includes('cursor=cur-1')) {
          return json({
            messages: [{ id: 'old-1', role: 'assistant', content: 'Loaded earlier page 1', ts: 2 }],
            has_more: true,
            next_cursor: 'cur-2',
          })
        }
        if (url.includes('cursor=cur-2')) {
          const response = json({
            messages: [{ id: 'old-0', role: 'assistant', content: 'Stale delayed earlier row', ts: 1 }],
            has_more: true,
            next_cursor: 'cur-3',
          })
          return new Promise<Response>((resolve) => {
            heldEarlierReads.push({ signal: init?.signal, release: () => resolve(response) })
          })
        }
        if (cleared) {
          return json({ messages: [], has_more: false, next_cursor: null })
        }
        return json({
          messages: [{ id: 'head-1', role: 'assistant', content: 'Latest before clear', ts: 3 }],
          has_more: true,
          next_cursor: 'cur-1',
        })
      }
      if (url.includes('/chat/operations')) return json(queuedOperations())
      return json({ rows: [] })
    }))

    const initialObserver = startObserverStream()
    await waitFor(() => expect(observerConnected.value).toBe(true))
    const view = render(html`<${KeeperChatTab} keeper=${keeper} onInspect=${vi.fn()} onMutated=${vi.fn()} />`)
    await waitFor(() => expect(view.queryByText('Latest before clear')).toBeTruthy())

    // 1. Load one earlier page so hasLoadedEarlierRef becomes true and nextCursor advances to cur-2
    fireEvent.click(view.getByRole('button', { name: '이전 대화 불러오기' }))
    await waitFor(() => expect(view.queryByText('Loaded earlier page 1')).toBeTruthy())

    // 2. Start loading cur-2 and hold it in flight across disconnect + authoritative empty reconnect
    fireEvent.click(view.getByRole('button', { name: '이전 대화 불러오기' }))
    await waitFor(() => expect(heldEarlierReads).toHaveLength(1))

    cleared = true
    observer!.close()
    await initialObserver
    await waitFor(() => expect(observerConnected.value).toBe(false))

    const recoveredObserver = startObserverStream()
    await waitFor(() => {
      expect(view.queryByText('Latest before clear')).toBeNull()
      expect(view.queryByText('Loaded earlier page 1')).toBeNull()
      expect(view.queryByRole('button', { name: '이전 대화 불러오기' })).toBeNull()
    })
    expect(heldEarlierReads[0]?.signal?.aborted).toBe(true)

    // 3. Even if the delayed earlier-page response settles after abort, stale rows and old cursor stay dropped
    await act(async () => heldEarlierReads[0]?.release())
    await new Promise((r) => setTimeout(r, 30))
    expect(view.queryByText('Stale delayed earlier row')).toBeNull()
    expect(view.queryByRole('button', { name: '이전 대화 불러오기' })).toBeNull()

    view.unmount()
    observer!.close()
    await recoveredObserver
  })

  it('dispatches Queue (Enter) vs Steer (⌘↵) with separate operation IDs', async () => {
    const streamBodies: Record<string, unknown>[] = []
    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.includes('/chat/history/page')) {
        return new Response(JSON.stringify({ messages: [], has_more: false, next_cursor: null }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.includes('/chat/operations')) {
        return new Response(JSON.stringify(queuedOperations()), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.includes('/api/v1/keepers/chat/stream')) {
        const parsed = JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>
        streamBodies.push(parsed)
        const sse = `data: ${JSON.stringify({ type: 'TEXT_MESSAGE_CONTENT', delta: 'Ack!' })}\n\ndata: ${JSON.stringify({ type: 'RUN_FINISHED' })}\n\n`
        return new Response(sse, {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        })
      }
      return new Response(JSON.stringify({ entries: [], turns: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    })
    vi.stubGlobal('fetch', mockFetch)

    const { container, getByLabelText } = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )

    const input = getByLabelText('Keeper 채팅 입력') as HTMLTextAreaElement
    // Hangul IME composition Enter must NOT submit mid-composition (P1-6)
    fireEvent.input(input, { target: { value: '한글 조합중' } })
    fireEvent.keyDown(input, { key: 'Enter', isComposing: true })
    expect(streamBodies.length).toBe(0)

    fireEvent.input(input, { target: { value: 'Normal follow-up' } })
    fireEvent.keyDown(input, { key: 'Enter' })
    // Rapid duplicate Enter while in-flight must be ignored (P1-6 double-submit guard)
    fireEvent.keyDown(input, { key: 'Enter' })

    await waitFor(() => expect(streamBodies.length).toBe(1))
    expect(streamBodies[0]!.admission_intent).toBeUndefined()
    expect('channel' in streamBodies[0]!).toBe(false)
    // Wait for first reply to finish and composer to re-enable
    await waitFor(() => {
      expect(container.textContent).toContain('Ack!')
      expect(getActiveViewStreamKey()).toBeNull()
    })

    fireEvent.input(input, { target: { value: 'Urgent steer' } })
    fireEvent.keyDown(input, { key: 'Enter', metaKey: true })

    await waitFor(() => expect(streamBodies.length).toBe(2))
    const steerBody = streamBodies[1]!
    expect(steerBody.admission_intent).toMatchObject({
      kind: 'interactive',
      control_token: 'ctrl-tok-1',
      operation_id: steerBody.request_id,
    })
  })

  it('loads Debug Companion traces only when opened, even in a wide chat', async ({ onTestFinished }) => {
    const originalWidth = window.innerWidth
    vi.stubGlobal('innerWidth', 1365)
    onTestFinished(() => { vi.stubGlobal('innerWidth', originalWidth) })
    const traceReads: string[] = []
    const mockFetch = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input), window.location.href).pathname
      const endpoint = path.split('/').at(-1)
      if (endpoint === 'turn-records' || endpoint === 'tool-calls' || endpoint === 'raw-traces') {
        traceReads.push(endpoint)
      }
      const body = path.endsWith('/chat/history/page')
        ? { messages: [], has_more: false, next_cursor: null }
        : {}
      return Response.json(body)
    })
    vi.stubGlobal('fetch', mockFetch)
    const view = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )

    await waitFor(() => {
      expect(mockFetch.mock.calls.some(([url]) => String(url).includes('/chat/history/page'))).toBe(true)
    })
    expect(view.getByRole('button', { name: /Debug 열기/ })).toBeTruthy()
    expect(traceReads).toEqual([])

    fireEvent.keyDown(window, { key: '.', metaKey: true })
    expect(await view.findByRole('tab', { name: 'Trace' })).toBeTruthy()
    await waitFor(() => expect([...traceReads].sort()).toEqual(['raw-traces', 'tool-calls', 'turn-records']))

    fireEvent.click(view.getByRole('button', { name: '닫기' }))
    expect(view.queryByRole('tab', { name: 'Trace' })).toBeNull()
  })

  it('renders 3-way discriminated Memory tab states and Config CAS 409 conflict_cas alert', async () => {
    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const json = (data: unknown, status = 200) =>
        new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })
      if (url.includes('/memory-facts')) {
        return json({
          keeper: 'code-reviewer-sister',
          ordinary: { read_error: 'corrupted ordinary snapshot' },
          source_bound: { present: false },
          events_unreadable_lines: 0,
          events_read_error: null,
        })
      }
      if (url.includes('/memory-os-internals')) {
        return json({
          keeper: 'code-reviewer-sister',
          compaction: { present: true, epoch_count: 3, archived_turns_count: 45, anchor_bytes: 2048, latest_epoch_id: 3, verified_facts_count: 12, decisions_count: 4, open_threads_count: 1, read_error: null },
          canonical_turns: { present: true, turn_count: 60, latest_turn_id: 't60', compaction_watermark_seq: 45, compaction_watermark_epoch: 3, history_resets_count: 0, read_error: null },
          memory_digest: { present: true, revision: 9, digest_sha256: 'abc', bytes: 1024, fact_count: 12, derived_count: 2 },
          librarian_molt: { writer_kind: 'llm', writer_state: null, pending_molt: null, available_acts: ['resume'] },
        })
      }
      if (url.includes('/memory-journal')) {
        return json({ keeper: 'code-reviewer-sister', returned: 0, undecodable_lines: 0, entries: [], activity: { events: [], notes: [] } })
      }
      if (url.includes('/api/v1/config/schema')) {
        return json({
          schema_version: 1,
          instance_id: 'i1',
          generated_at_unix: 1,
          data: {
            target: 'keeper:code-reviewer-sister',
            keeper: 'code-reviewer-sister',
            file_exists: true,
            file_sha256: 'deadbeef1234',
            categories: [
              {
                id: 'autonomy',
                title: 'Autonomy',
                field_count: 1,
                fields: [
                  {
                    table: 'keeper',
                    key: 'activation_mode',
                    full_key: 'keeper.activation_mode',
                    type: 'string',
                    current_value: 'manual',
                    default_value: 'manual',
                    provenance: 'toml',
                    reload_scope: 'next_turn',
                    secret: false,
                    writable: true,
                    description: 'Activation mode',
                    enum_values: ['manual', 'autonomous'],
                  },
                ],
              },
            ],
          },
        })
      }
      if (url.includes('/api/v1/config/patch')) {
        const body = JSON.parse(String(init?.body ?? '{}')) as { dry_run?: boolean }
        if (body.dry_run) {
          return json({
            schema_version: 1,
            instance_id: 'i1',
            generated_at_unix: 1,
            data: {
              applied: false,
              dry_run: true,
              target: 'keeper:code-reviewer-sister',
              changed: true,
              before_sha256: 'deadbeef1234',
              new_sha256: 'cafebabe5678',
              snapshot_id: null,
              reload_scope: 'next_turn',
              unified_diff: '-activation_mode = "manual"\n+activation_mode = "autonomous"',
              validation_warnings: [],
            },
          })
        }
        return json({ error: { code: 'conflict_cas', message: 'sha mismatch' } }, 409)
      }
      if (url.includes('/api/v1/keepers/oauth/attached-tools')) {
        return json({ providers: [] })
      }
      return json({})
    })
    vi.stubGlobal('fetch', mockFetch)

    const mem = render(html`<${KeeperMemoryTab} keeperName="code-reviewer-sister" />`)
    await waitFor(() => {
      expect(mem.container.querySelector('[data-branch="read_error"]')?.textContent).toContain('corrupted ordinary snapshot')
      expect(mem.container.querySelector('[data-branch="absent"]')?.textContent).toContain('present: false')
    })
    mem.unmount()

    const cfg = render(html`<${KeeperConfigTab} keeperName="code-reviewer-sister" onMutated=${vi.fn()} />`)
    await waitFor(() => expect(cfg.getByLabelText('keeper.activation_mode')).toBeTruthy())

    const select = cfg.getByLabelText('keeper.activation_mode') as HTMLSelectElement
    // The Preact test helper maps change to input in compat mode, even for selects.
    select.value = 'autonomous'
    fireEvent(select, new Event('change', { bubbles: true }))

    fireEvent.click(cfg.getByRole('button', { name: 'Dry-Run Unified Diff 미리보기' }))
    await waitFor(() => {
      expect(cfg.container.textContent).toContain('reload_scope: next_turn')
      expect(cfg.container.textContent).toContain('+activation_mode = "autonomous"')
    })

    fireEvent.click(cfg.getByRole('button', { name: 'CAS 설정 적용 (expected_sha256)' }))
    await waitFor(() => {
      expect(cfg.container.querySelector('[data-cas-conflict="true"]')).toBeTruthy()
    })
  })

  it('renders honest Portrait try-on preview (single bare item id) and KeepersWorkspace 2-pane shell', async () => {
    let releaseTurns!: () => void
    const waitForTurns = new Promise<void>((resolve) => { releaseTurns = resolve })
    const requestedUrls: string[] = []
    const mockFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      requestedUrls.push(url)
      const json = (data: unknown) =>
        new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
      if (url.includes('/api/v1/candle/ledger')) {
        return json({
          schema_version: 1,
          instance_id: 'i1',
          generated_at_unix: 1,
          data: {
            ledger_state: 'present',
            total_events: 1,
            policy: { configuration: 'enabled', disabled_reason: null, pricing_mode: 'fixed', half_life: { mode: 'decay', half_life_hours: 168 } },
            supply: { issued_milli: '50000', burned_milli: '5000', circulating_milli: '45000' },
            balances: [{ keeper: 'code-reviewer-sister', balance_milli: 12500, decayed_milli: '1250', last_event_unix: 100, owned_items: ['glasses'], equipped: { face: 'glasses', neck: null, head: null, hand: null, base: null } }],
            recent_events: [{ seq: 1, at_unix: 100, at_rfc3339: '2026-11-24T00:00:00Z', kind: 'awarded', amount_milli: '12500' }],
          },
        })
      }
      if (url.includes('/api/v1/keepers/code-reviewer-sister/items')) {
        return json({
          status: 'ready',
          keeper: 'code-reviewer-sister',
          account_revision: '1',
          balance_milli: '12500',
          owned_items: ['glasses'],
          catalog: [
            { id: 'glasses', slot: 'face', price_status: 'priced', price_milli: '5000' },
            { id: 'crown', slot: 'head', price_status: 'priced', price_milli: '9000' },
          ],
        })
      }
      if (url.includes('/api/v1/gate/keepers')) {
        return json({
          keepers: [
            { name: 'code-reviewer-sister', status: 'running', phase: 'idle', health: 'healthy', paused: false, keepalive_running: true, runtime_id: 'claude-code', context_ratio: 0.4 },
          ],
        })
      }
      if (url.includes('/api/v1/keepers/turns')) {
        await waitForTurns
        return json({ keepers: [{ keeper_name: 'code-reviewer-sister', status: 'ok', turn: { lane: 'chat_operation' } }] })
      }
      if (url.includes('/portrait.png')) {
        return new Response(new Uint8Array([0x89, 0x50, 0x4e, 0x47]), {
          status: 200,
          headers: { 'Content-Type': 'image/png' },
        })
      }
      if (url.includes('/chat/history/page')) return json({ messages: [], has_more: false, next_cursor: null })
      if (url.includes('/chat/operations')) return json(queuedOperations())
      return json({})
    })
    vi.spyOn(URL, 'createObjectURL').mockImplementation(() => `blob:portrait-${requestedUrls.length}`)
    vi.stubGlobal('fetch', mockFetch)

    const pc = render(html`<${KeeperPortraitCandleTab} keeper=${makeRosterKeeper()} onMutated=${vi.fn()} />`)
    await waitFor(() => expect(pc.container.textContent).toContain('12.500 C'))
    const policyNote = pc.container.querySelector('[role="note"]')
    expect(policyNote?.classList.contains('kp-notice')).toBe(true)
    expect(policyNote?.classList.contains('kp-pill')).toBe(false)
    // Must NOT spoof /mcp purchase; clicking preview updates portrait img to bare `?preview=crown` via authenticated blob fetch
    const previewBtns = pc.getAllByRole('button', { name: '미리보기' })
    fireEvent.click(previewBtns[1]!)
    await waitFor(() => {
      const img = pc.container.querySelector('img.kp-portrait-preview') as HTMLImageElement | null
      expect(img).not.toBeNull()
      expect(img?.getAttribute('data-portrait-url')).toContain('preview=crown')
      expect(img?.getAttribute('src')).toMatch(/^blob:/)
    })
    expect(requestedUrls.some((u) => u.includes('preview=crown'))).toBe(true)
    expect(requestedUrls.some((u) => u === '/mcp')).toBe(false)
    pc.unmount()

    const onNavigate = vi.fn()
    const ws = render(
      html`<${KeepersWorkspace} subroute="" entityId="code-reviewer-sister" entityTab="chat" onNavigate=${onNavigate} onInspect=${vi.fn()} />`,
    )
    await waitFor(() => expect(ws.getByRole('heading', { name: 'code-reviewer-sister' })).toBeTruthy())
    expect(ws.queryByText('턴 상태 조회 중…')).toBeTruthy()
    expect(ws.container.querySelectorAll('*').length).toBeLessThan(1200)
    fireEvent.click(ws.getByRole('tab', { name: 'Memory' }))
    expect(onNavigate).toHaveBeenCalledWith('/keepers/code-reviewer-sister/memory')

    releaseTurns()
    await waitFor(() => expect(ws.queryByText('● Turn (chat_operation)')).toBeTruthy())
  })

  it('does not send a pending Steer after leaving the Keeper chat', async () => {
    let releaseTurns!: () => void
    const waitForTurns = new Promise<void>((resolve) => { releaseTurns = resolve })
    const mockFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.endsWith('/api/v1/keepers/turns')) await waitForTurns
      return new Response(JSON.stringify({ keepers: [], messages: [], operations: [] }), {
        headers: { 'Content-Type': 'application/json' },
      })
    })
    vi.stubGlobal('fetch', mockFetch)
    const view = render(html`<${KeeperChatTab}
      keeper=${makeRosterKeeper({ chat_control_token: null })} onInspect=${vi.fn()} onMutated=${vi.fn()}
    />`)
    const input = view.getByLabelText('Keeper 채팅 입력')
    fireEvent.input(input, { target: { value: 'Steer current Keeper' } })
    fireEvent.keyDown(input, { key: 'Enter', metaKey: true })
    await waitFor(() => expect(mockFetch.mock.calls.some(([url]) => String(url).endsWith('/api/v1/keepers/turns'))).toBe(true))
    view.unmount()
    await act(async () => releaseTurns())
    expect(mockFetch.mock.calls.some(([url]) => String(url).includes('/api/v1/keepers/chat/stream'))).toBe(false)
  })

  it('reads debug companion turn records with the turn inspector decoder', async () => {
    // Unmodified writer output; the OCaml codec suite reads the same file.
    const record = JSON.parse(readFileSync(
      resolve(__dirname, '../../api/fixtures/turn-record-writer.jsonl'), 'utf8',
    ).split('\n')[0]!) as Record<string, unknown>
    const keeper = String(record.keeper)
    const ts = Number(record.ts)
    const canonical = {
      keeper, count: 1, skipped_rows: 0, source: 'turn_record',
      producer: 'keeper_agent_run.run_turn|keeper_turn_record_writer',
      durable_store: `.masc/keepers/${keeper}/turn-records`,
      dashboard_surface: '/api/v1/keepers/:name/turn-records',
      freshness_slo_s: 300, live_turn_in_progress: false,
      live_turn_started_at_unix: null, live_turn_last_progress_at_unix: null,
      latest_ts_unix: ts, latest_ts_iso: new Date(Math.floor(ts) * 1000).toISOString().replace('.000Z', 'Z'),
      latest_age_s: 10, health: 'ok', stale_reason: null,
      memory_os: {
        keeper, snapshot_store: `.masc/keepers/${keeper}.memory-current.json`, recall_enabled: true,
        revision: 0, updated_at: null, update_source: null, read_errors: [],
        facts: { shown: 0, current: 0, items: [] },
        change: { added: [], removed: [], retained: 0, invalidated: [] },
      },
      entries: [{ record, diff_vs_prev: null }],
    }
    // The shape the companion's own decoder used to accept: no usage scope,
    // no provenance, and unknown values filled in.
    const lenient = {
      keeper, count: 1, live_turn_in_progress: false, health: 'ok',
      entries: [{
        record: { trace_id: 'tr1', absolute_turn: 2, turn_ref: 'tr1#2', turn_kind: 'direct', runtime_profile: 'default', ts: 100, blocks: [], raw_trace_run_ref: null },
        diff_vs_prev: null,
      }],
    }
    let body: unknown = canonical
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } })))

    const read = await fetchKeeperTurnRecordsApi(keeper, 60)
    expect(read.ok).toBe(true)
    if (read.ok) {
      expect(read.value.entries[0]?.record.usage_scope).toBe('per_request')
      expect(read.value.entries[0]?.record.input_tokens).toBe(18000)
    }

    body = lenient
    const drift = await fetchKeeperTurnRecordsApi(keeper, 60)
    expect(drift.ok).toBe(false)
    if (!drift.ok) expect(drift.error).toMatchObject({ kind: 'decode', code: 'schema_drift' })
  })

  it('sends raw binary audio for Voice STT, guards Clear/Reset with TargetLockedAction, and preserves Config drafts on OAuth toggle', async () => {
    let voiceContentType: string | null = null
    let voiceBodyWasBinary = false
    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const json = (data: unknown) =>
        new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
      if (url === '/api/v1/voice/transcribe') {
        const hdrs = init?.headers as Record<string, string> | undefined
        voiceContentType = hdrs?.['Content-Type'] ?? null
        voiceBodyWasBinary = init?.body instanceof ArrayBuffer || init?.body instanceof Uint8Array
        return json({ text: 'hello world' })
      }
      if (url.includes('/checkpoints')) {
        return json({ keeper: 'code-reviewer-sister', trace_id: 'tr1', current_status: 'available', current: { snapshot_id: 'snap-1', message_count: 4, created_at: 100, latest_preview: null }, history: [] })
      }
      if (url.includes('/api/v1/config/schema')) {
        return json({
          schema_version: 1,
          instance_id: 'i1',
          generated_at_unix: 1,
          data: {
            target: 'keeper:code-reviewer-sister',
            keeper: 'code-reviewer-sister',
            file_exists: true,
            file_sha256: 'deadbeef1234',
            categories: [{ id: 'autonomy', title: 'Autonomy', field_count: 1, fields: [{ table: 'keeper', key: 'activation_mode', full_key: 'keeper.activation_mode', type: 'string', current_value: 'manual', default_value: 'manual', provenance: 'toml', reload_scope: 'next_turn', secret: false, writable: true, description: 'mode', enum_values: ['manual', 'autonomous'] }] }],
          },
        })
      }
      if (url.includes('/api/v1/keepers/oauth/attached-tools')) {
        return json({
          providers: [
            { provider: 'github', provider_label: 'GitHub', attached: true, enabled: true, tools: ['gh_pr'] },
            { provider: 'slack', provider_label: 'Slack', attached: false },
          ],
        })
      }
      if (url.includes('/identity-switch')) return json({ ok: true })
      if (url.includes('/oauth-login')) return json({ authorize_url: 'https://slack.com/oauth/v2/authorize?client_id=123' })
      return json({ entries: [], turns: [] })
    })
    vi.stubGlobal('fetch', mockFetch)

    // P1-2: Voice STT sends raw binary with audio/webm
    const sttRes = await transcribeVoiceAudio(new Uint8Array([1, 2, 3, 4]).buffer, 'audio/webm')
    expect(sttRes.ok).toBe(true)
    if (sttRes.ok) expect(sttRes.value).toBe('hello world')
    expect(voiceContentType).toBe('audio/webm')
    expect(voiceBodyWasBinary).toBe(true)

    // P2-2: Clear/Reset require confirmation inside TargetLockedAction
    const cmp = render(html`<${KeeperDebugCompanion} keeperName="code-reviewer-sister" onClose=${vi.fn()} onInspect=${vi.fn()} />`)
    fireEvent.click(cmp.getByRole('tab', { name: 'Context' }))
    await waitFor(() => expect(cmp.getByRole('button', { name: 'Clear Context…' })).toBeTruthy())
    fireEvent.click(cmp.getByRole('button', { name: 'Clear Context…' }))
    await waitFor(() => {
      expect(cmp.container.querySelector('.tla')).toBeTruthy()
      expect(cmp.getByRole('button', { name: 'Clear Context 실행 확인' })).toBeTruthy()
    })
    cmp.unmount()

    // P2-4: OAuth switch preserves unsaved TOML drafts & authorize_url renders clickable https link
    const cfg = render(html`<${KeeperConfigTab} keeperName="code-reviewer-sister" onMutated=${vi.fn()} />`)
    await waitFor(() => expect(cfg.getByLabelText('keeper.activation_mode')).toBeTruthy())
    const select = cfg.getByLabelText('keeper.activation_mode') as HTMLSelectElement
    select.value = 'autonomous'
    fireEvent(select, new Event('change', { bubbles: true }))
    expect(cfg.container.textContent).toContain('변경 1건')

    fireEvent.click(cfg.getByRole('button', { name: '끄기' }))
    await waitFor(() => expect(cfg.container.textContent).toContain('GitHub 비활성화'))
    // Draft change must still be preserved!
    expect(cfg.container.textContent).toContain('변경 1건')

    fireEvent.click(cfg.getByRole('button', { name: '연결' }))
    await waitFor(() => {
      const link = cfg.getByRole('link', { name: 'OAuth 인증 페이지 열기 ↗' }) as HTMLAnchorElement
      expect(link.href).toBe('https://slack.com/oauth/v2/authorize?client_id=123')
      expect(link.rel).toBe('noopener noreferrer')
    })
  })

  it('recovers cut-reply stream via /chat/events journal and renders Work & Sandbox tab', async () => {
    let savedNoteBody: Record<string, unknown> | null = null
    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const json = (data: unknown) =>
        new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
      if (url.includes('/chat/history/page')) return json({ messages: [], has_more: false, next_cursor: null })
      if (url.includes('/chat/operations')) return json(queuedOperations())
      if (url.includes('/api/v1/keepers/chat/stream')) {
        // Cut mid-stream without RUN_FINISHED!
        const sse = `data: ${JSON.stringify({ type: 'TEXT_MESSAGE_CONTENT', delta: 'Partial' })}\n\n`
        return new Response(sse, { status: 200, headers: { 'Content-Type': 'text/event-stream' } })
      }
      if (url.includes('/chat/events')) {
        return json({
          schema: 'masc.keeper_chat_events.v2',
          has_more: false,
          events: [
            { event: { type: 'RUN_STARTED' } },
            { event: { type: 'TEXT_MESSAGE_CONTENT', delta: 'Full recovered reply', response: { content_generation: 0, stream_scope: 0 } } },
            { event: { type: 'RUN_FINISHED' } },
          ],
        })
      }
      if (url.includes('/api/v1/dashboard/execution')) {
        return json({ tasks: [{ id: 't-1', title: 'Audit sandbox', status: 'InProgress', priority: 1, assignee: 'code-reviewer-sister', goal_id: 'g-1' }] })
      }
      if (url.includes('/tool-calls')) {
        return json({ keeper: 'code-reviewer-sister', count: 1, health: 'ok', entries: [{ ts: 100, record_kind: 'tool_call', keeper: 'code-reviewer-sister', tool: 'rg', duration_ms: 18, wire_outcome: 'ok', disposition: 'completed', input: {}, output: {} }] })
      }
      if (url.includes('/tool-stats')) {
        return json({ keeper: 'code-reviewer-sister', window_hours: 24, total_entries: 1, tools: [{ name: 'rg', call_count: 1, success_count: 1, failure_count: 0, avg_duration_ms: 18, p95_duration_ms: 18 }] })
      }
      if (url.includes('/operator-note')) {
        if (init?.method === 'POST') {
          savedNoteBody = JSON.parse(String(init.body ?? '{}')) as Record<string, unknown>
          return json({ keeper: 'code-reviewer-sister', pending: true, note: { text: savedNoteBody.text, created_by: 'op', created_at: 200, consumed_turn: null } })
        }
        return json({ keeper: 'code-reviewer-sister', pending: false, note: { text: 'Initial note', created_by: 'op', created_at: 100, consumed_turn: 5 } })
      }
      if (url.includes('/api/v1/infra/sandboxes/code-reviewer-sister')) {
        return json({
          schema_version: 1,
          instance_id: 'i1',
          generated_at_unix: 1,
          data: { keeper: 'code-reviewer-sister', probe_state: { kind: 'fresh' }, sandbox: { backend: 'microvm', running: true } },
        })
      }
      return json({ entries: [], turns: [] })
    })
    vi.stubGlobal('fetch', mockFetch)

    const chat = render(html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`)
    const input = chat.getByLabelText('Keeper 채팅 입력') as HTMLTextAreaElement
    fireEvent.input(input, { target: { value: 'Trigger cut stream' } })
    fireEvent.keyDown(input, { key: 'Enter' })

    await waitFor(() => {
      expect(chat.container.textContent).toContain('Full recovered reply')
      expect(chat.container.textContent).toContain('Cut_recovered')
    })
    chat.unmount()

    const ws = render(html`<${KeeperWorkSandboxTab} keeperName="code-reviewer-sister" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    await waitFor(() => {
      expect(ws.container.textContent).toContain('Audit sandbox')
      expect(ws.container.textContent).toContain('microvm')
      expect(ws.container.textContent).toContain('rg')
    })

    const noteArea = ws.getByLabelText('운영자 노트 입력') as HTMLTextAreaElement
    fireEvent.input(noteArea, { target: { value: 'Prioritize tests next turn' } })
    fireEvent.click(ws.getByRole('button', { name: '운영자 노트 저장' }))
    await waitFor(() => {
      expect(savedNoteBody).toEqual({ text: 'Prioritize tests next turn' })
    })
  })

  it('shows a received Keeper task while other reads are pending and preserves edits across note reads and writes', async () => {
    const keeper = 'code-reviewer-sister'
    const json = (data: unknown, status = 200) =>
      new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })
    let resolveSandbox!: (response: Response) => void
    let resolveNote!: (response: Response) => void
    let resolveSave!: (response: Response) => void
    const firstSandbox = new Promise<Response>(resolve => { resolveSandbox = resolve })
    const noteRead = new Promise<Response>(resolve => { resolveNote = resolve })
    const noteWrite = new Promise<Response>(resolve => { resolveSave = resolve })
    let sandboxReads = 0
    const saves: unknown[] = []
    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.endsWith('/dashboard/execution?light=true')) {
        return json({ tasks: [{ id: 't-1', title: 'Inspect local cache', assignee: keeper }] })
      }
      if (url.includes('/infra/sandboxes')) {
        if (++sandboxReads === 1) return firstSandbox
        if (sandboxReads === 2) return json({ error: { code: 'not_found', message: 'Route unavailable' } }, 404)
        if (sandboxReads === 3) return json({ error: { code: 'sandbox_telemetry_missing', message: 'No sandbox telemetry' } }, 404)
        return json({ schema_version: 1, instance_id: 'i1', generated_at_unix: 1,
          data: { keeper, probe_state: { kind: 'fresh' }, sandbox: { backend: 'microvm' } } })
      }
      if (url.endsWith('/operator-note')) {
        if (init?.method === 'POST') {
          saves.push(JSON.parse(String(init.body)))
          return noteWrite
        }
        return noteRead
      }
      return json({ entries: [], tools: [] })
    })
    vi.stubGlobal('fetch', mockFetch)
    const view = render(html`<${KeeperWorkSandboxTab} keeperName=${keeper} onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    await view.findByText('Inspect local cache')
    expect(view.getByRole('region', { name: 'Keeper 샌드박스 상태' }).textContent).toContain('샌드박스 불러오는 중')
    expect(view.queryByText('현재 조회에서 샌드박스 텔레메트리 행을 찾지 못했습니다.')).toBeNull()

    const note = view.getByLabelText('운영자 노트 입력') as HTMLTextAreaElement
    fireEvent.input(note, { target: { value: 'Temporary draft' } })
    fireEvent.input(note, { target: { value: '' } })
    await act(async () => {
      resolveNote(json({ keeper, pending: false, note: { text: 'Old saved note' } }))
      resolveSandbox(json({ error: 'Sandbox unavailable' }, 503))
    })
    await view.findByText('저장된 노트', { exact: true })
    expect(note.value).toBe('')
    await view.findByRole('alert')
    fireEvent.click(view.getByRole('button', { name: '샌드박스 다시 읽기' }))
    await view.findByText(/Route unavailable/)
    expect(view.queryByText('현재 조회에서 샌드박스 텔레메트리 행을 찾지 못했습니다.')).toBeNull()
    fireEvent.click(view.getByRole('button', { name: '샌드박스 다시 읽기' }))
    await view.findByText('현재 조회에서 샌드박스 텔레메트리 행을 찾지 못했습니다.')
    fireEvent.click(view.getByRole('button', { name: '샌드박스 다시 읽기' }))
    await view.findByText('microvm')
    expect(sandboxReads).toBe(4)
    expect(mockFetch.mock.calls.filter(([url]) => String(url).includes('/dashboard/execution'))).toHaveLength(1)

    fireEvent.input(note, { target: { value: 'Save this draft' } })
    fireEvent.click(view.getByRole('button', { name: '운영자 노트 저장' }))
    expect((view.getByRole('button', { name: '저장 중…' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.input(note, { target: { value: 'Keep editing during the save' } })
    await act(async () => {
      resolveSave(json({ ok: true, keeper, pending: true, note: { text: 'Save this draft' } }))
    })
    await view.findByText('운영자 노트 저장 완료')
    expect(saves).toEqual([{ text: 'Save this draft' }])
    expect(note.value).toBe('Keep editing during the save')
    expect(view.getByText('저장되지 않은 초안')).toBeTruthy()
  })

  it.each([
    { stale: true, partial: true, matching: true },
    { stale: true, partial: false, matching: false },
    { stale: false, partial: true, matching: false },
  ])('qualifies Keeper matches in the workspace sample (stale=$stale, partial=$partial, match=$matching)', async ({ stale, partial, matching }) => {
    const keeper = 'hermes'
    vi.stubGlobal('fetch', async (input: RequestInfo | URL) => {
      if (String(input).endsWith('/dashboard/execution?light=true')) return Response.json({
        tasks: [{ id: 't-sample', title: 'Retained review', assignee: matching ? keeper : 'other' }],
        task_counts: { total: partial ? 25 : 1, shown: 1 },
        projection_diagnostics: {
          cache_state: stale ? 'stale' : 'fresh', last_success_at: '2026-11-25T03:00:00Z',
          stale_reason: stale ? 'refresh unavailable' : null,
        },
      })
      return Response.json({}, { status: 404 })
    })
    const view = render(html`<${KeeperWorkSandboxTab} keeperName=${keeper} onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    const region = view.getByRole('region', { name: '연결된 작업' })
    await waitFor(() => expect(region.textContent).toContain(stale ? 'refresh unavailable' : '작업공간 전체 25건 중 1건 조회'))
    expect(region.textContent?.includes('2026-11-25T03:00:00Z')).toBe(stale)
    expect(region.textContent?.includes('작업공간 전체 25건 중 1건 조회')).toBe(partial)
    expect(region.textContent).not.toContain('Linked Tasks (25)')
    if (matching) expect(view.getByText('Retained review')).toBeTruthy()
    else {
      expect(region.textContent).not.toContain('Linked Tasks (0)')
      expect(region.textContent).not.toContain('조회된 담당 작업 없음')
    }
  })

  it('reads only workspace tasks and sandbox in multi-account mode and offers no local note or Memory actions', async () => {
    authSession.value = {
      kind: 'multi_account_signed_in', mode: 'multi_account', accountId: 'acct-1', displayName: 'Operator',
      email: null, role: 'admin', csrfToken: 'csrf-test', workspaceId: 'default',
      authMethods: { google: true, github: false, dev_token: false },
    }
    const paths: string[] = []
    vi.stubGlobal('fetch', async (input: RequestInfo | URL) => {
      const url = new URL(String(input), 'http://localhost')
      paths.push(url.pathname + url.search)
      if (url.pathname.endsWith('/execution')) return Response.json({ tasks: [], task_counts: { total: 0, shown: 0 } })
      if (url.pathname === '/api/v1/infra/sandboxes/hermes') return Response.json(
        { error: { code: 'sandbox_telemetry_missing', message: 'No sandbox telemetry' } }, { status: 404 },
      )
      return Response.json({}, { status: 404 })
    })
    const work = render(html`<${KeeperWorkSandboxTab} keeperName="hermes" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    const memory = render(html`<${KeeperMemoryTab} keeperName="hermes" />`)
    await work.findByText('조회된 담당 작업 없음')
    await work.findByText('현재 조회에서 샌드박스 텔레메트리 행을 찾지 못했습니다.')
    expect(work.container.textContent).toContain('단일 계정 모드')
    expect(work.queryByRole('textbox', { name: '운영자 노트 입력' })).toBeNull()
    expect(work.queryByRole('button', { name: '운영자 노트 저장' })).toBeNull()
    expect(memory.container.textContent).toContain('단일 계정 모드')
    expect(paths.sort()).toEqual(['/api/v1/dashboard/execution?light=true', '/api/v1/infra/sandboxes/hermes'])
  })

  it.each([true, false])('shows tool coverage gaps with only observed rows (rows=%s)', async withRows => {
    const gap = { stale_reason: 'trajectory append failed' }
    vi.stubGlobal('fetch', async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/tool-stats')) return Response.json({
        health: 'coverage_gap', stale_reason: gap.stale_reason, coverage_gaps: [gap],
        total_entries: Number(withRows), tools: withRows ? [{ name: 'retained-stat', call_count: 1 }] : [],
        projection_diagnostics: { cache_state: 'stale', stale_reason: 'cached observation' },
      })
      if (url.includes('/tool-calls')) return Response.json({
        health: 'coverage_gap', stale_reason: 'IO row was dropped', coverage_gaps: [{ stale_reason: 'IO row was dropped' }],
        count: Number(withRows), entries: withRows ? [{ ts: 1, tool: 'retained-call', wire_outcome: 'ok' }] : [],
      })
      return Response.json({}, { status: 404 })
    })
    const view = render(html`<${KeeperWorkSandboxTab} keeperName="hermes" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    const stats = view.getByRole('region', { name: '도구 호출 통계' })
    const calls = view.getByRole('region', { name: '도구 호출 내역' })
    await waitFor(() => expect(stats.textContent).toContain(gap.stale_reason))
    expect(stats.textContent).toContain('cached observation')
    expect(calls.textContent).toContain('IO row was dropped')
    if (withRows) {
      expect(stats.textContent).toContain('retained-stat')
      expect(calls.textContent).toContain('retained-call')
    } else {
      expect(stats.textContent).not.toContain('0 calls')
      expect(stats.textContent).not.toContain('24h 도구 통계 없음')
      expect(calls.textContent).not.toContain('Tool Calls (0)')
      expect(calls.textContent).not.toContain('도구 호출 기록 없음')
    }
  })

  it('distinguishes a retained empty stats projection from a fresh empty calls source', async () => {
    const empty = { health: 'empty', stale_reason: 'no_entries', coverage_gaps: [] }
    vi.stubGlobal('fetch', async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/tool-stats')) return Response.json({
        ...empty, total_entries: 0, tools: [], projection_diagnostics: { cache_state: 'stale', stale_reason: 'refresh interrupted' },
      })
      if (url.includes('/tool-calls')) return Response.json({ ...empty, count: 0, entries: [] })
      return Response.json({}, { status: 404 })
    })
    const view = render(html`<${KeeperWorkSandboxTab} keeperName="hermes" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    await view.findByText('도구 호출 기록 없음')
    const stats = view.getByRole('region', { name: '도구 호출 통계' })
    expect(stats.textContent).toContain('refresh interrupted')
    expect(stats.textContent).not.toContain('0 calls')
    expect(stats.textContent).not.toContain('24h 도구 통계 없음')
  })

  it('does not turn recovered tool coverage gaps into a current failure', async () => {
    const history = { health: 'ok', stale_reason: null, coverage_gaps: [{ stale_reason: 'recovered append error' }] }
    vi.stubGlobal('fetch', async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/tool-stats')) return Response.json({ ...history, total_entries: 1, tools: [{ name: 'rg', call_count: 1 }] })
      if (url.includes('/tool-calls')) return Response.json({ ...history, count: 1, entries: [{ ts: 1, tool: 'rg' }] })
      return Response.json({}, { status: 404 })
    })
    const view = render(html`<${KeeperWorkSandboxTab} keeperName="hermes" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    await view.findByRole('heading', { name: 'Tool Calls (1)' })
    expect(view.getByRole('heading', { name: 'Tool Stats (24h · 1 calls)' })).toBeTruthy()
    expect(view.container.textContent).not.toContain('recovered append error')
  })

  it('keeps Keeper facts visible when Journal fails and reports an already absent fact as such', async () => {
    const keeper = 'code-reviewer-sister'
    const json = (data: unknown, status = 200) =>
      new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })
    let resolveJournal!: (response: Response) => void
    let resolveRetraction!: (response: Response) => void
    const firstJournal = new Promise<Response>(resolve => { resolveJournal = resolve })
    const retraction = new Promise<Response>(resolve => { resolveRetraction = resolve })
    let journalReads = 0
    let factReads = 0
    const retractions: { plan_id: string; retractions: unknown }[] = []
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.includes('/memory-journal')) {
        if (++journalReads === 1) return firstJournal
        return json({ keeper, returned: 0, entries: [] })
      }
      if (url.endsWith('/memory-facts')) {
        ++factReads
        return json({
          keeper,
          ordinary: { present: true, revision: 5, facts: [{ memory_id: 'fact-A', claim: 'Keeper fact body' }] },
          source_bound: { present: false },
        })
      }
      if (url.endsWith('/memory/retractions')) {
        retractions.push(JSON.parse(String(init?.body)))
        return retraction
      }
      return json({ keeper, compaction: { present: false }, canonical_turns: { present: false },
        memory_digest: { present: false }, librarian_molt: {} })
    }))
    const view = render(html`<${KeeperMemoryTab} keeperName=${keeper} />`)
    await view.findByText('Keeper fact body')
    expect(view.getByRole('heading', { name: 'Memory Journal (—)' })).toBeTruthy()
    expect(view.queryByText('메모리 저널 기록 없음')).toBeNull()
    await act(async () => { resolveJournal(json({ error: 'Journal unavailable' }, 503)) })
    expect((await view.findByRole('alert')).textContent).toContain('Journal unavailable')
    expect(view.getByText('Keeper fact body')).toBeTruthy()
    fireEvent.click(view.getByRole('button', { name: '메모리 저널 다시 읽기' }))
    await view.findByRole('heading', { name: 'Memory Journal (0)' })
    expect(factReads).toBe(1)

    fireEvent.click(view.getByRole('button', { name: 'Retract 선택' }))
    fireEvent.click(view.getByRole('button', { name: 'Fact 철회 (POST /memory/retractions)' }))
    expect((view.getByRole('button', { name: '철회 요청 중…' }) as HTMLButtonElement).disabled).toBe(true)
    expect(retractions[0]?.retractions).toEqual([{ memory_id: 'fact-A', reason: 'operator_cleanup' }])
    await act(async () => {
      resolveRetraction(json({
        ok: true, keeper, plan_id: retractions[0]?.plan_id,
        retractions: [{ memory_id: 'fact-A', outcome: 'not_current' }],
      }))
    })
    await view.findByText('현재 메모리에 없는 항목 · fact-A')
    expect(view.queryByText('철회 완료 · fact-A')).toBeNull()
  })

  it('auto-scrolls Chat on load/send, shows jump-to-bottom pill when scrolled up, preserves anchor on prepend, updates user badge to Delivered, and guards /btw IME Enter', async () => {
    const streamCalls: Record<string, unknown>[] = []
    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const json = (data: unknown) =>
        new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
      if (url.includes('/chat/history/page')) {
        if (url.includes('cursor=cur-older')) {
          return json({
            messages: [
              { id: 'old-1', role: 'user', content: 'Earlier question', ts: 1_700_000_001 },
              { id: 'old-2', role: 'assistant', content: 'Earlier answer', ts: 1_700_000_002 },
            ],
            has_more: false,
            next_cursor: null,
          })
        }
        return json({
          messages: [
            { id: 'm-1', role: 'user', content: 'First msg', ts: 1_700_000_010 },
            { id: 'm-2', role: 'assistant', content: 'Latest msg', ts: 1_700_000_020 },
          ],
          has_more: true,
          next_cursor: 'cur-older',
        })
      }
      if (url.includes('/chat/operations')) return json(queuedOperations())
      if (url.includes('/api/v1/keepers/chat/stream')) {
        const parsed = JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>
        streamCalls.push(parsed)
        const sse = `data: ${JSON.stringify({ type: 'TEXT_MESSAGE_CONTENT', delta: 'Fresh reply' })}\n\ndata: ${JSON.stringify({ type: 'RUN_FINISHED' })}\n\n`
        return new Response(sse, { status: 200, headers: { 'Content-Type': 'text/event-stream' } })
      }
      return json({ entries: [], turns: [] })
    })
    vi.stubGlobal('fetch', mockFetch)

    const chat = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )
    const logEl = chat.getByLabelText('Keeper 대화 기록') as HTMLDivElement
    Object.defineProperty(logEl, 'scrollHeight', {
      configurable: true,
      get: () => logEl.querySelectorAll('article.kp-msg').length * 400,
    })
    Object.defineProperty(logEl, 'clientHeight', { configurable: true, get: () => 400 })

    // 1. Initial history load (2 msgs -> 800px) scrolls to bottom
    await waitFor(() => {
      expect(chat.container.textContent).toContain('Latest msg')
      expect(logEl.scrollTop).toBe(800)
    })

    // 2. User scrolls up -> jump-to-bottom button appears
    logEl.scrollTop = 100
    fireEvent.scroll(logEl)
    await waitFor(() => {
      expect(chat.container.querySelector('[data-testid="chat-scroll-bottom"]')).not.toBeNull()
    })

    // 3. Loading earlier messages (2 -> 4 msgs, +800px growth) preserves viewport anchor (100 -> 900)
    fireEvent.click(chat.getByRole('button', { name: '이전 대화 불러오기' }))
    await waitFor(() => {
      expect(chat.container.textContent).toContain('Earlier question')
      expect(logEl.scrollTop).toBe(900)
    })

    // 4. Sending a new message (4 -> 6 msgs -> 2400px) forces scroll to bottom & transitions user bubble to Delivered
    const composer = chat.getByLabelText('Keeper 채팅 입력') as HTMLTextAreaElement
    fireEvent.input(composer, { target: { value: 'New question' } })
    fireEvent.keyDown(composer, { key: 'Enter' })
    await waitFor(() => {
      expect(chat.container.textContent).toContain('Fresh reply')
      expect(logEl.scrollTop).toBe(2400)
    })
    const userBubbles = chat.container.querySelectorAll('article.kp-msg[data-role="user"]')
    const sentBubble = userBubbles[userBubbles.length - 1]
    expect(sentBubble?.textContent).toContain('Delivered')
    expect(sentBubble?.textContent).not.toContain('Sending')

    // 5. /btw input ignores Korean IME composing Enter and submits on committed Enter
    fireEvent.click(chat.getByRole('button', { name: '/btw 사이드 질의' }))
    const btwInput = chat.getByPlaceholderText('임시 사이드 질문을 입력하세요…') as HTMLInputElement
    fireEvent.input(btwInput, { target: { value: '한글 질문' } })
    fireEvent.keyDown(btwInput, { key: 'Enter', isComposing: true })
    expect(streamCalls).toHaveLength(1)

    fireEvent.keyDown(btwInput, { key: 'Enter', isComposing: false })
    await waitFor(() => expect(streamCalls).toHaveLength(2))
    expect(streamCalls[1]!.turn_instructions).toContain('/btw')
  })

  it('hides Boot on already-booted or paused Keepers and shows Boot only when offline/unbooted/stopped', () => {
    const runningKeeper = makeRosterKeeper({ keepalive_running: true, status: 'running', phase: 'running', paused: false })
    expect(isKeeperBooted(runningKeeper)).toBe(true)
    const r1 = render(
      html`<${KeeperHeader} keeper=${runningKeeper} activeTab="chat" onSelectTab=${vi.fn()} onLifecycleMutated=${vi.fn()} onDeleted=${vi.fn()} />`,
    )
    expect(r1.queryByRole('button', { name: 'Boot' })).toBeNull()
    expect(r1.queryByRole('button', { name: 'Pause' })).not.toBeNull()
    expect(r1.queryByRole('button', { name: 'Interrupt Turn' })).not.toBeNull()
    r1.unmount()

    const pausedKeeper = makeRosterKeeper({ keepalive_running: false, status: 'paused', phase: 'paused', paused: true })
    expect(isKeeperBooted(pausedKeeper)).toBe(true)
    const r2 = render(
      html`<${KeeperHeader} keeper=${pausedKeeper} activeTab="chat" onSelectTab=${vi.fn()} onLifecycleMutated=${vi.fn()} onDeleted=${vi.fn()} />`,
    )
    expect(r2.queryByRole('button', { name: 'Boot' })).toBeNull()
    expect(r2.queryByRole('button', { name: 'Resume' })).not.toBeNull()
    expect(r2.queryByRole('button', { name: 'Pause' })).toBeNull()
    r2.unmount()

    const unbootedKeeper = makeRosterKeeper({ keepalive_running: false, status: 'unbooted', phase: 'offline', paused: false })
    expect(isKeeperBooted(unbootedKeeper)).toBe(false)
    const r3 = render(
      html`<${KeeperHeader} keeper=${unbootedKeeper} activeTab="chat" onSelectTab=${vi.fn()} onLifecycleMutated=${vi.fn()} onDeleted=${vi.fn()} />`,
    )
    expect(r3.queryByRole('button', { name: 'Boot' })).not.toBeNull()
    expect(r3.queryByRole('button', { name: 'Pause' })).toBeNull()
    expect(r3.queryByRole('button', { name: 'Interrupt Turn' })).toBeNull()
    r3.unmount()

    expect(isKeeperBooted(makeRosterKeeper({ keepalive_running: false, status: 'crashed', phase: 'crashed', paused: false }))).toBe(false)
    expect(isKeeperBooted(makeRosterKeeper({ keepalive_running: false, status: 'stopped', phase: 'stopped', paused: false }))).toBe(false)
  })

  it('decodes live numeric release_at, terminal candidate failures, waiting_heads, and KeeperHeader diagnostic banner', () => {
    const items = decodeKeeperRoster(
      {
        keepers: [
          {
            name: 'e-masc-the-leader',
            status: 'active',
            phase: 'failing',
            health: 'failing',
            paused: false,
            keepalive_running: true,
            activation_mode: 'autonomous',
            runtime_id: 'ollama-deepseek-then-glm',
            context_ratio: null,
            context_provenance: 'estimated',
            estimated_context_ratio: 0.61,
            context_metrics_unavailable_reason: 'usage_scope_unavailable',
            runtime_blocker_summary: 'Connection reset on glm-5.3-flash',
            runtime_blocker_signature: 'net:eof',
            runtime_path_rest: {
              status: 'resting',
              runtime_id: 'glm-coding.glm-5.3-flash',
              release_at: 1_764_036_000,
              release_basis: 'rate_limit',
            },
            operator_disposition: 'retry_later',
            operator_disposition_reason: 'transient_runtime_retry',
            failing_since: 1_700_000_000,
            next_action: 'probe',
            last_failure: { cause: 'provider', at_unix: 1_700_000_050 },
            runtime_lane_observation: {
              evidence: {
                failures: [
                  {
                    runtime_id: 'ollama_cloud.deepseek',
                    summary: 'session limit reached',
                    api_candidate_fault: { kind: 'binding', fact: 'rate_limit' },
                  },
                ],
                terminal: {
                  kind: 'candidate',
                  runtime_id: 'glm-coding.glm-5.3-flash',
                  attempt: 2,
                  summary: 'connection reset by peer',
                },
              },
            },
            recent_turns: {
              known_since: 1_700_000_000,
              slots: [{ starts_at: 1_700_000_000, ok: 2, rested: 1, failed: 4, scheduled: 3, reacted: 2, chat: 1, own: 1, unknown: 0 }],
            },
          },
          {
            name: 'paused-resting-keeper',
            status: 'paused',
            phase: 'paused',
            health: 'healthy',
            paused: true,
            keepalive_running: false,
            activation_mode: 'autonomous',
            runtime_id: 'glm-coding.glm-5.3-flash',
            runtime_path_rest: {
              status: 'resting',
              runtime_id: 'glm-coding.glm-5.3-flash',
              release_at: 1_764_036_000,
              release_basis: 'rate_limit',
            },
          },
        ],
      },
    )

    expect(items).toHaveLength(2)
    const k = items[0]!
    const pausedK = items[1]!
    expect(isKeeperPathResting(k)).toBe(true)
    expect(isKeeperPathResting(pausedK)).toBe(false)
    expect(k.runtime_path_rest?.release_at).toContain('2025-11-25')
    expect(k.turns_24h_breakdown).toEqual({ ok: 2, rested: 1, failed: 4, causes: { scheduled: 3, reacted: 2, chat: 1, own: 1, unknown: 0 } })
    expect(k.runtime_lane_failures).toHaveLength(2)
    expect(formatContextDetail(k).label).toBe('~61%')

    const hdr = render(
      html`<${KeeperHeader}
        keeper=${k}
        activeTab="chat"
        onSelectTab=${vi.fn()}
        onLifecycleMutated=${vi.fn()}
        onDeleted=${vi.fn()}
      />`,
    )
    expect(hdr.container.textContent).toContain('Connection reset on glm-5.3-flash')
    expect(hdr.container.textContent).toContain('ollama_cloud.deepseek')
    expect(hdr.container.textContent).toContain('connection reset by peer')
    expect(hdr.container.textContent).toContain('retry_later')
    expect(hdr.container.textContent).toContain('성공 2 · 휴식 1 · 실패 4')
    expect(hdr.container.textContent).toContain('Ctx ~61%')
    hdr.unmount()
  })

  it('attributes non-operator chat speakers honestly, renders YOLO pill + restore_error, decodes array journal changes, suppresses healthy pass disposition, and surfaces Memory OS faults', async () => {
    const journalEntries = Array.from({ length: 15 }, (_, i) => ({
      structural_id: `j-${i}`,
      ok: true,
      revision: i + 1,
      source: { kind: 'commit' },
      change: {
        added: [{ claim: 'a' }, { claim: 'b' }],
        removed: [{ claim: 'old' }],
        retained: i,
        invalidated: [{ support_id: 's1' }],
      },
    }))
    const mockFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      const json = (data: unknown) =>
        new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
      if (url.includes('/api/v1/keepers/tool-approval-mode')) {
        return json({
          default: 'auto',
          overrides: [{ keeper: 'code-reviewer-sister', mode: 'yolo' }],
          restore_error: 'corrupt tool-approval-modes.json line 2',
        })
      }
      if (url.includes('/chat/history/page')) {
        return json({
          has_more: false,
          next_cursor: null,
          messages: [
            { id: 'm-1', role: 'user', content: 'DM from peer', ts: 100, speaker_authority: 'keeper', speaker_name: 'sangsu', surface: { kind: 'agent' } },
            { id: 'm-2', role: 'user', content: 'Slack ping', ts: 101, speaker_authority: 'external', speaker_name: 'alice', surface: { kind: 'slack', channel_name: 'ops' } },
          ],
        })
      }
      if (url.includes('/chat/operations')) return json({ operations: [] })
      if (url.includes('/memory-facts')) {
        return json({
          keeper: 'code-reviewer-sister',
          ordinary: { present: false },
          source_bound: { present: false },
          events_unreadable_lines: 3,
          events_read_error: 'permission denied on events.jsonl',
        })
      }
      if (url.includes('/memory-os-internals')) {
        return json({
          keeper: 'code-reviewer-sister',
          compaction: { present: false, epoch_count: 0, archived_turns_count: 0, anchor_bytes: 0, latest_epoch_id: null, verified_facts_count: 0, decisions_count: 0, open_threads_count: 0, read_error: 'compaction crc mismatch' },
          canonical_turns: { present: false, turn_count: 0, latest_turn_id: null, compaction_watermark_seq: null, compaction_watermark_epoch: null, history_resets_count: 0, read_error: 'canonical log truncated' },
          memory_digest: { present: true, revision: 4, digest_sha256: 'abc', bytes: 120, fact_count: 2, derived_count: 1 },
          librarian_molt: { writer_kind: 'in_process', writer_state: { state: 'stopped', stop: 'snapshot_mismatch' }, pending_molt: { kind: 'compaction' }, available_acts: ['resume'] },
        })
      }
      if (url.includes('/memory-journal')) {
        return json({
          keeper: 'code-reviewer-sister',
          returned: 15,
          undecodable_lines: 0,
          entries: journalEntries,
          activity: { events: [], notes: [] },
        })
      }
      return json({})
    })
    vi.stubGlobal('fetch', mockFetch)

    const hdr = render(
      html`<${KeeperHeader}
        keeper=${makeRosterKeeper()}
        activeTab="chat"
        onSelectTab=${vi.fn()}
        onLifecycleMutated=${vi.fn()}
        onDeleted=${vi.fn()}
      />`,
    )
    await waitFor(() => {
      expect(hdr.container.textContent).toContain('⚠ YOLO')
      expect(hdr.container.textContent).toContain('corrupt tool-approval-modes.json line 2')
    })
    hdr.unmount()

    const chat = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )
    await waitFor(() => {
      expect(chat.container.textContent).toContain('Keeper · sangsu')
      expect(chat.container.textContent).toContain('alice (외부)')
      expect(chat.container.textContent).toContain('slack #ops')
      expect(chat.container.textContent).toContain('agent')
      expect(chat.container.textContent).not.toContain('Operator')
    })
    chat.unmount()

    const mem = render(html`<${KeeperMemoryTab} keeperName="code-reviewer-sister" />`)
    await waitFor(() => {
      expect(mem.container.textContent).toContain('permission denied on events.jsonl')
      expect(mem.container.textContent).toContain('compaction crc mismatch')
      expect(mem.container.textContent).toContain('canonical log truncated')
      expect(mem.container.textContent).toContain('snapshot_mismatch')
      expect(mem.container.textContent).toContain('대기 molt: kind=compaction')
      expect(mem.container.textContent).toContain('상위 12건 표시 (전체 15건)')
      expect(mem.container.textContent).toContain('+2 / -1')
      expect(mem.container.textContent).toContain('invalidated 1')
    })
    mem.unmount()

    // Healthy keeper with operator_disposition: "pass" must NOT render .kp-diag-banner
    const healthyKeeper = {
      ...makeRosterKeeper(),
      name: 'healthy-keeper',
      operator_disposition: 'pass',
      operator_disposition_reason: 'healthy',
    }
    const cleanFetch = vi.fn(async () =>
      new Response(JSON.stringify({ default: 'auto', overrides: [], restore_error: null }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', cleanFetch)
    resourceCache.clearAll()
    const cleanHdr = render(
      html`<${KeeperHeader}
        keeper=${healthyKeeper}
        activeTab="chat"
        onSelectTab=${vi.fn()}
        onLifecycleMutated=${vi.fn()}
        onDeleted=${vi.fn()}
      />`,
    )
    expect(cleanHdr.container.querySelector('.kp-diag-banner')).toBeNull()
    cleanHdr.unmount()
  })

  it('allows queueing follow-up messages mid-stream, bare /btw, and run-next on queued items', async () => {
    const streamCalls: Record<string, unknown>[] = []
    const runNextCalls: Record<string, unknown>[] = []
    let releaseFirstStream: () => void = () => {}
    let firstAborted = false
    const encoder = new TextEncoder()

    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.includes('/chat/history/page')) {
        return new Response(JSON.stringify({ messages: [], has_more: false, next_cursor: null }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.includes('/chat/operations')) {
        const body = url.includes('after_sequence=')
          ? queuedOperations([])
          : queuedOperations([1], () => 'Queued task')
        return new Response(JSON.stringify(body), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.includes('/api/v1/keepers/turn/run-next')) {
        runNextCalls.push(JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>)
        return new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.includes('/api/v1/keepers/chat/stream')) {
        const parsed = JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>
        streamCalls.push(parsed)
        if (streamCalls.length === 1) {
          init?.signal?.addEventListener('abort', () => { firstAborted = true })
          const body = new ReadableStream<Uint8Array>({
            start(controller) {
              controller.enqueue(encoder.encode(
                `data: ${JSON.stringify({ type: 'TEXT_MESSAGE_CONTENT', delta: 'First partial' })}\n\n`,
              ))
              releaseFirstStream = () => {
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: 'RUN_FINISHED' })}\n\n`))
                controller.close()
              }
            },
          })
          return new Response(body, { status: 200, headers: { 'Content-Type': 'text/event-stream' } })
        }
        const acceptSse = `data: ${JSON.stringify({
          type: 'CUSTOM',
          name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
          value: { operation_id: parsed.request_id, state: 'Queued', queued_count: 2 },
        })}\n\n`
        return new Response(acceptSse, { status: 200, headers: { 'Content-Type': 'text/event-stream' } })
      }
      return new Response(JSON.stringify({ entries: [], turns: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    })
    vi.stubGlobal('fetch', mockFetch)

    const { container, getByLabelText, findByRole } = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )

    // 1. Run-next button triggers POST /api/v1/keepers/turn/run-next
    const runNextBtn = await findByRole('button', { name: '지금 실행' })
    fireEvent.click(runNextBtn)
    await waitFor(() => expect(runNextCalls.length).toBe(1))
    expect(runNextCalls[0]).toEqual({ name: 'code-reviewer-sister', request_id: 'queued-1' })

    // 2. Start streaming first turn
    const input = getByLabelText('Keeper 채팅 입력') as HTMLTextAreaElement
    fireEvent.input(input, { target: { value: 'First turn' } })
    fireEvent.keyDown(input, { key: 'Enter' })
    await waitFor(() => expect(container.textContent).toContain('First partial'))

    // 3. Queue a second message while first turn is STILL streaming (must NOT abort first stream)
    fireEvent.input(input, { target: { value: 'Follow-up queued mid-stream' } })
    fireEvent.keyDown(input, { key: 'Enter' })
    await waitFor(() => expect(streamCalls.length).toBe(2))
    expect(streamCalls[1]!.message).toBe('Follow-up queued mid-stream')
    expect(firstAborted).toBe(false)

    // 4. Bare `/btw` opens the side-query box instead of sending `/btw` to Keeper
    fireEvent.input(input, { target: { value: '/btw' } })
    fireEvent.keyDown(input, { key: 'Enter' })
    await waitFor(() => expect(container.textContent).toContain('/btw Ephemeral Side-Query'))
    expect(streamCalls.length).toBe(2)

    releaseFirstStream()
    await waitFor(() => expect(getActiveViewStreamKey()).toBeNull())
  })
})
