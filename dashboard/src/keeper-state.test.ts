import { describe, expect, it } from 'vitest'
import { beforeEach } from 'vitest'
import {
  THREAD_ENTRY_CAP,
  appendAssistantToolTraceArgsDelta,
  appendAssistantToolTraceStep,
  appendAssistantThinkingDelta,
  appendThreadEntry,
  attachKeeperAudioClip,
  chatHistoryEntriesFromRest,
  finalizeAssistantEntry,
  insertThreadEntryBefore,
  isDefaultVisibleConversationEntry,
  isToolConversationEntry,
  isVisibleDirectConversationEntry,
  keeperThreads,
  markAssistantToolTraceEnded,
  mergeServerHistoryEntries,
  normalizeAudioClip,
  normalizeStatusDetail,
  removeThreadEntries,
  setStatusDetail,
} from './keeper-state'
import type { ChatBlock, KeeperConversationEntry } from './types'

describe('normalizeStatusDetail', () => {
  it('infers and hides internal keeper history from direct comms', () => {
    const detail = normalizeStatusDetail('sangsu', '', {
      history_tail: [
        {
          role: 'user',
          content:
            '## Current World State\n\n### Workspace State\n- Failed tasks: 9\n- Active agents: 5\n\n### Context\n- Utilization: 72%\n- Idle: 132s',
          ts_unix: 10,
        },
        {
          role: 'assistant',
          content: '9개 실패 태스크가 계속되는데 왜 이걸로 하냐니? 그냥 고치거나 무시하거냐.',
          ts_unix: 11,
        },
        {
          role: 'user',
          source: 'direct_user',
          content: '지금 상태 어때?',
          ts_unix: 20,
        },
        {
          role: 'assistant',
          source: 'direct_assistant',
          content: '직접 상태는 괜찮고, 대화 UI만 정리하면 됩니다.',
          ts_unix: 21,
        },
      ],
    })

    expect(detail.history.map(entry => entry.source)).toEqual([
      'world_state_prompt',
      'internal_assistant',
      'direct_user',
      'direct_assistant',
    ])
    expect(detail.history.filter(isVisibleDirectConversationEntry).map(entry => entry.text)).toEqual([
      '지금 상태 어때?',
      '직접 상태는 괜찮고, 대화 UI만 정리하면 됩니다.',
    ])
  })

  it('keeps explicit direct history visible', () => {
    const detail = normalizeStatusDetail('sangsu', '', {
      history_tail: [
        {
          role: 'user',
          source: 'direct_user',
          content: 'ping',
          ts_unix: 30,
        },
        {
          role: 'assistant',
          source: 'direct_assistant',
          content: 'pong',
          ts_unix: 31,
        },
      ],
    })

    expect(detail.history.every(isVisibleDirectConversationEntry)).toBe(true)
  })
})

describe('default conversation visibility (tool calls vs internal)', () => {
  function mk(partial: Partial<KeeperConversationEntry>): KeeperConversationEntry {
    return {
      id: 'e',
      role: 'assistant',
      source: 'direct_assistant',
      label: 'sangsu',
      text: '',
      rawText: '',
      timestamp: '2026-06-19T00:00:00.000Z',
      delivery: 'history',
      streamState: null,
      details: null,
      ...partial,
    }
  }

  it('surfaces tool-call rows by default but keeps them out of direct comms', () => {
    const tool = mk({ role: 'tool', source: 'tool_result', text: '{"path":"x"}' })
    // The "direct conversation" predicate is unchanged: tool rows are not direct comms.
    expect(isVisibleDirectConversationEntry(tool)).toBe(false)
    expect(isToolConversationEntry(tool)).toBe(true)
    // The default-visible predicate (toggle off) does include them.
    expect(isDefaultVisibleConversationEntry(tool)).toBe(true)
  })

  it('keeps truly-internal sources behind the toggle', () => {
    for (const source of ['world_state_prompt', 'internal_assistant', 'system'] as const) {
      const internal = mk({ source })
      expect(isToolConversationEntry(internal)).toBe(false)
      expect(isDefaultVisibleConversationEntry(internal)).toBe(false)
    }
  })

  it('keeps direct user/assistant turns visible', () => {
    expect(isDefaultVisibleConversationEntry(mk({ role: 'user', source: 'direct_user' }))).toBe(true)
    expect(isDefaultVisibleConversationEntry(mk({ role: 'assistant', source: 'direct_assistant' }))).toBe(true)
  })
})

describe('thread history merge & persistence', () => {
  beforeEach(() => {
    keeperThreads.value = {}
  })

  function entry(partial: Partial<KeeperConversationEntry>): KeeperConversationEntry {
    return {
      id: 'e-1',
      role: 'user',
      source: 'direct_user',
      label: '사용자',
      text: 'hello',
      rawText: 'hello',
      timestamp: '2026-06-10T00:00:00.000Z',
      delivery: 'delivered',
      streamState: null,
      details: null,
      ...partial,
    }
  }

  it('keeps hydrated history when a status refresh carries no history', () => {
    appendThreadEntry('echo', entry({ id: 'hist-1', delivery: 'history' }))
    appendThreadEntry('echo', entry({ id: 'local-1', text: 'live', rawText: 'live' }))

    // hydrateKeeperStatus fast path: include_history_tail=false → history: []
    setStatusDetail('echo', {
      name: 'echo',
      diagnostic: null,
      history: [],
      rawText: '',
      loadedAt: new Date().toISOString(),
    })

    const ids = (keeperThreads.value.echo ?? []).map(e => e.id)
    expect(ids).toContain('hist-1')
    expect(ids).toContain('local-1')
  })

  it('does not duplicate a local message when server history arrives with a different timestamp', () => {
    appendThreadEntry('echo', entry({ id: 'local-1', text: 'gg', rawText: 'gg', timestamp: '2026-06-10T00:00:01.000Z' }))

    mergeServerHistoryEntries('echo', [
      entry({ id: 'hist-1', text: 'gg', rawText: 'gg', delivery: 'history', timestamp: '2026-06-10T00:00:05.000Z' }),
    ])

    const matches = (keeperThreads.value.echo ?? []).filter(e => e.text === 'gg')
    expect(matches).toHaveLength(1)
    expect(matches[0]?.delivery).toBe('history')
  })

  it('preserves live assistant thinking trace when matching server history replaces the entry', () => {
    appendThreadEntry('echo', entry({
      id: 'assistant-live',
      role: 'assistant',
      text: 'final answer',
      rawText: 'final answer',
      delivery: 'streaming',
      streamState: 'streaming',
    }))
    appendAssistantThinkingDelta('echo', 'assistant-live', 'checking ')
    appendAssistantThinkingDelta('echo', 'assistant-live', 'context')
    finalizeAssistantEntry('echo', 'assistant-live', {
      delivery: 'delivered',
      streamState: null,
    })

    mergeServerHistoryEntries('echo', [
      entry({
        id: 'assistant-history',
        role: 'assistant',
        text: 'final answer',
        rawText: 'final answer',
        delivery: 'history',
        timestamp: '2026-06-10T00:00:05.000Z',
      }),
    ])

    const thread = keeperThreads.value.echo ?? []
    expect(thread).toHaveLength(1)
    expect(thread[0]?.id).toBe('assistant-history')
    expect(thread[0]?.delivery).toBe('history')
    expect(thread[0]?.traceSteps).toEqual([
      { kind: 'think', text: 'checking context', ts: expect.any(String) },
    ])
  })

  it('distributes identical-text assistant turns trace 1:1 across history rows (#21748)', () => {
    // Two local optimistic assistants with the SAME reply text but distinct
    // thinking traces. Before the fix, both history rows matched the FIRST
    // local source via the role+text fallback, so the second row inherited the
    // first turn's trace.
    appendThreadEntry('echo', entry({
      id: 'local-a',
      role: 'assistant',
      text: 'done',
      rawText: 'done',
      delivery: 'delivered',
      streamState: null,
      timestamp: '2026-06-10T00:00:01.000Z',
    }))
    appendThreadEntry('echo', entry({
      id: 'local-b',
      role: 'assistant',
      text: 'done',
      rawText: 'done',
      delivery: 'delivered',
      streamState: null,
      timestamp: '2026-06-10T00:00:02.000Z',
    }))
    appendAssistantThinkingDelta('echo', 'local-a', 'first turn reasoning')
    appendAssistantThinkingDelta('echo', 'local-b', 'second turn reasoning')

    mergeServerHistoryEntries('echo', [
      entry({ id: 'hist-a', role: 'assistant', text: 'done', rawText: 'done', delivery: 'history', timestamp: '2026-06-10T00:00:01.000Z' }),
      entry({ id: 'hist-b', role: 'assistant', text: 'done', rawText: 'done', delivery: 'history', timestamp: '2026-06-10T00:00:02.000Z' }),
    ])

    const thread = keeperThreads.value.echo ?? []
    const traceTextOf = (id: string) => {
      const step = thread.find(e => e.id === id)?.traceSteps?.[0]
      return step && 'text' in step ? step.text : undefined
    }
    // Each history row carries its OWN local trace, not the other's.
    expect(traceTextOf('hist-a')).toBe('first turn reasoning')
    expect(traceTextOf('hist-b')).toBe('second turn reasoning')
  })

  it('uses turnRef to keep multiturn traces attached when finalize order inverts', () => {
    // Reverse-finalize scenario: local-a is appended FIRST but finalizes
    // LATER (ts=02); local-b is appended SECOND but finalizes EARLIER (ts=01).
    // The server sends history chronological (earliest first): [hist-b(01), hist-a(02)].
    // turnRef is the producer-assigned join key, so the trace follows the turn
    // instead of append order or timestamp order.
    appendThreadEntry('echo', entry({
      id: 'local-a',
      role: 'assistant',
      text: 'done',
      rawText: 'done',
      delivery: 'delivered',
      streamState: null,
      timestamp: '2026-06-10T00:00:02.000Z', // appended first, finalized LATER
      turnRef: 'trace-x#42',
    }))
    appendThreadEntry('echo', entry({
      id: 'local-b',
      role: 'assistant',
      text: 'done',
      rawText: 'done',
      delivery: 'delivered',
      streamState: null,
      timestamp: '2026-06-10T00:00:01.000Z', // appended second, finalized EARLIER
      turnRef: 'trace-x#41',
    }))
    appendAssistantThinkingDelta('echo', 'local-a', 'turn-a reasoning')
    appendAssistantThinkingDelta('echo', 'local-b', 'turn-b reasoning')

    mergeServerHistoryEntries('echo', [
      entry({ id: 'hist-b', role: 'assistant', text: 'done', rawText: 'done', delivery: 'history', timestamp: '2026-06-10T00:00:01.000Z', turnRef: 'trace-x#41' }),
      entry({ id: 'hist-a', role: 'assistant', text: 'done', rawText: 'done', delivery: 'history', timestamp: '2026-06-10T00:00:02.000Z', turnRef: 'trace-x#42' }),
    ])

    const thread = keeperThreads.value.echo ?? []
    const traceTextOf = (id: string) => {
      const step = thread.find(e => e.id === id)?.traceSteps?.[0]
      return step && 'text' in step ? step.text : undefined
    }
    expect(traceTextOf('hist-a')).not.toBe(traceTextOf('hist-b'))
    expect(traceTextOf('hist-a')).toBe('turn-a reasoning')
    expect(traceTextOf('hist-b')).toBe('turn-b reasoning')
  })

  it('keeps local entries the server has not persisted yet', () => {
    appendThreadEntry('echo', entry({ id: 'local-1', text: 'not yet saved' }))

    mergeServerHistoryEntries('echo', [
      entry({ id: 'hist-1', text: 'old message', delivery: 'history' }),
    ])

    const ids = (keeperThreads.value.echo ?? []).map(e => e.id)
    expect(ids).toEqual(['hist-1', 'local-1'])
  })

  it('converts REST chat history into entries with chained sources', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'hi', ts: 1_780_000_000 },
      { role: 'assistant', content: 'hello there', ts: 1_780_000_000 },
    ])
    expect(entries).toHaveLength(2)
    expect(entries[0]?.role).toBe('user')
    expect(entries[0]?.delivery).toBe('history')
    expect(entries[1]?.role).toBe('assistant')
    expect(entries[1]?.label).toBe('echo')
    expect(entries[1]?.timestamp).toBeTruthy()
  })

  it('preserves REST chat history provenance instead of re-inferring it away', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      {
        role: 'user',
        source: 'world_state_prompt',
        content: 'state snapshot',
        ts: 1_780_000_000,
        surface: { kind: 'dashboard', session_id: 'sess-1' },
        speaker_id: 'operator-1',
        speaker_name: 'Operator',
        speaker_authority: 'owner',
      },
      {
        role: 'assistant',
        source: 'direct_assistant',
        content: 'reply from channel context',
        ts: 1_780_000_001,
        turn_ref: 'trace-rest#7',
        conversation_id: 'discord:guild-1:channel:channel-1',
        external_message_id: 'message-1',
        surface: {
          kind: 'discord',
          guild_id: 'guild-1',
          channel_id: 'channel-1',
          thread_id: 'thread-1',
        },
      },
    ])

    expect(entries[0]?.source).toBe('world_state_prompt')
    expect(entries[0]?.surface).toEqual({ kind: 'dashboard', session_id: 'sess-1' })
    expect(entries[1]?.source).toBe('direct_assistant')
    expect(entries[1]?.surface).toEqual({
      kind: 'discord',
      guild_id: 'guild-1',
      channel_id: 'channel-1',
      thread_id: 'thread-1',
    })
    expect(entries[1]?.turnRef).toBe('trace-rest#7')
    expect(entries[0]?.speakerId).toBe('operator-1')
    expect(entries[0]?.speakerName).toBe('Operator')
    expect(entries[0]?.speakerAuthority).toBe('owner')
    expect(entries[1]?.conversationId).toBe('discord:guild-1:channel:channel-1')
    expect(entries[1]?.externalMessageId).toBe('message-1')
  })

  it('prefers backend stream contracts from REST chat history', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      {
        role: 'assistant',
        source: 'direct_assistant',
        content: 'reply from retained trace',
        ts: 1_780_000_001,
        turn_ref: 'trace-rest#8',
        stream_contract: {
          source: 'backend_turn_trace',
          status: 'backend_trace_join',
          turn_ref: 'trace-rest#8',
          trace_event_count: 3,
          delivery_receipt: 'no_delivery_receipt',
          reason: 'turn_ref joined to retained trajectory/internal-history events',
        },
      },
    ])

    expect(entries[0]?.streamContract).toEqual({
      source: 'backend_turn_trace',
      status: 'backend_trace_join',
      turnRef: 'trace-rest#8',
      traceEventCount: 3,
      deliveryReceipt: 'no_delivery_receipt',
      reason: 'turn_ref joined to retained trajectory/internal-history events',
    })
  })

  it('normalizes durable backend lifecycle stream contracts from REST chat history', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      {
        role: 'assistant',
        source: 'direct_assistant',
        content: 'reply from durable lifecycle replay',
        ts: 1_780_000_001,
        turn_ref: 'trace-rest#9',
        stream_contract: {
          source: 'backend_stream_lifecycle',
          status: 'backend_lifecycle_replay',
          turn_ref: 'trace-rest#9',
          event_name: 'RUN_FINISHED',
          lifecycle_events: [
            'RUN_STARTED',
            'TEXT_MESSAGE_START',
            'TEXT_MESSAGE_END',
            'RUN_FINISHED',
          ],
          delivery_receipt: 'server_lifecycle_replay_only',
          reason: 'history row records durable server stream lifecycle replay',
        },
      },
    ])

    expect(entries[0]?.streamContract).toEqual({
      source: 'backend_stream_lifecycle',
      status: 'backend_lifecycle_replay',
      turnRef: 'trace-rest#9',
      eventName: 'RUN_FINISHED',
      lifecycleEvents: [
        'RUN_STARTED',
        'TEXT_MESSAGE_START',
        'TEXT_MESSAGE_END',
        'RUN_FINISHED',
      ],
      deliveryReceipt: 'server_lifecycle_replay_only',
      reason: 'history row records durable server stream lifecycle replay',
    })
  })

  it('falls back explicitly when REST chat history carries an unknown stream contract', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      {
        role: 'assistant',
        source: 'direct_assistant',
        content: 'reply',
        ts: 1_780_000_001,
        stream_contract: {
          source: 'future_backend_source',
          status: 'future_status',
        },
      },
    ])

    expect(entries[0]?.streamContract).toMatchObject({
      source: 'rest_history',
      status: 'history_without_stream_events',
    })
  })

  it('preserves object payloads in persisted tool trace blocks', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      {
        role: 'assistant',
        content: 'done',
        ts: 1_780_000_000,
        blocks: [
          {
            t: 'trace',
            trace: [
              {
                kind: 'tool',
                name: 'lookup',
                toolCallId: 'tc-object',
                args: { query: 'masc', limit: 2 },
                result: { ok: true },
              },
            ],
          },
        ] as unknown as ChatBlock[],
      },
    ])

    const traceBlock = entries[0]?.blocks?.find((block): block is Extract<ChatBlock, { t: 'trace' }> => block.t === 'trace')
    expect(traceBlock?.trace).toEqual([
      {
        kind: 'tool',
        name: 'lookup',
        toolCallId: 'tc-object',
        args: '{\n  "query": "masc",\n  "limit": 2\n}',
        result: '{\n  "ok": true\n}',
      },
    ])
  })

  it('preserves persisted thinking/tool interleaving trace blocks on reload', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      {
        role: 'assistant',
        content: 'done',
        ts: 1_780_000_000,
        turn_ref: 'trace-ui#12',
        blocks: [
          { t: 'p', html: 'done' },
          {
            t: 'trace',
            trace: [
              { kind: 'think', text: 'checking tasks', ts: '2026-07-01T00:00:00Z' },
              {
                kind: 'tool',
                name: 'keeper_tasks_list',
                tool_call_id: 'exec-1',
                status: 'ok',
                args: {},
                result: { ok: true },
                ts: '2026-07-01T00:00:01Z',
              },
              { kind: 'think', text: 'summarizing', ts: '2026-07-01T00:00:02Z' },
            ],
          },
        ] as unknown as ChatBlock[],
      },
    ])

    const traceBlock = entries[0]?.blocks?.find((block): block is Extract<ChatBlock, { t: 'trace' }> => block.t === 'trace')
    expect(traceBlock?.trace).toEqual([
      { kind: 'think', text: 'checking tasks', ts: '2026-07-01T00:00:00Z' },
      {
        kind: 'tool',
        name: 'keeper_tasks_list',
        toolCallId: 'exec-1',
        status: 'ok',
        args: '{}',
        result: '{\n  "ok": true\n}',
        ts: '2026-07-01T00:00:01Z',
      },
      { kind: 'think', text: 'summarizing', ts: '2026-07-01T00:00:02Z' },
    ])
    expect(entries[0]?.turnRef).toBe('trace-ui#12')
  })

  it('maps persisted tool rows to the live tool-entry convention', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'run checks', ts: 1_780_000_000 },
      {
        role: 'tool',
        content: '{"path":"x"}',
        ts: 1_780_000_000,
        tool_call_id: 'toolu_1',
        tool_call_name: 'Read',
        source: 'dashboard',
      },
      { role: 'assistant', content: 'all green', ts: 1_780_000_000 },
    ])
    expect(entries.map(e => e.role)).toEqual(['user', 'tool', 'assistant'])
    const tool = entries[1]
    // Same id/shape as the live TOOL_CALL_* path so replaceThread dedups
    // a rehydrated row against a still-mounted live entry.
    expect(tool?.id).toBe('tool-toolu_1')
    expect(tool?.source).toBe('tool_result')
    expect(tool?.label).toBe('Read')
    // Argument JSON must come through verbatim, not reply-formatted.
    expect(tool?.text).toBe('{"path":"x"}')
    expect(tool?.delivery).toBe('history')
  })

  it('decodes persisted attachments so uploads survive a reload', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      {
        role: 'user',
        content: 'see this',
        ts: 1_780_000_000,
        attachments: [
          { id: 'att1', type: 'image', name: 'shot.png', size: 1234, mime_type: 'image/png', data: 'BASE64' },
          { id: 'att2', type: 'doc', name: 'notes.txt', size: 9, mime_type: 'text/plain', data: 'ZZ' },
        ],
      },
    ])
    const atts = entries[0]?.attachments ?? []
    expect(atts).toHaveLength(2)
    // snake_case mime_type -> camelCase mimeType, type narrowed to image/file.
    expect(atts[0]).toMatchObject({ id: 'att1', type: 'image', mimeType: 'image/png', data: 'BASE64' })
    expect(atts[1]?.type).toBe('file')
  })

  it('drops attachment rows missing id or data (unrenderable)', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      {
        role: 'user',
        content: 'x',
        ts: 1_780_000_000,
        attachments: [{ id: '', type: 'file', name: 'n', size: 0, mime_type: '', data: 'D' }],
      },
    ])
    expect(entries[0]?.attachments).toBeUndefined()
  })

  it('marks a transport_failure row as error delivery, not a saved reply', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'do it', ts: 1_780_000_000 },
      { role: 'assistant', content: 'Keeper request failed: timeout', ts: 1_780_000_000, kind: 'transport_failure' },
    ])
    expect(entries[1]?.delivery).toBe('error')
    expect(entries[1]?.error).toBe('Keeper request failed: timeout')
    // A normal reply on the same role stays 'history'.
    const ok = chatHistoryEntriesFromRest('echo', [
      { role: 'assistant', content: 'done', ts: 1_780_000_000 },
    ])
    expect(ok[0]?.delivery).toBe('history')
  })

  it('prefers server-provided rich blocks for assistant rows', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'assistant', content: 'hello', ts: 1_780_000_000, blocks: [{ t: 'image', src: 'https://x.com/a.png' }] },
    ])
    expect(entries[0]?.blocks).toEqual([{ t: 'image', src: 'https://x.com/a.png' }])
  })

  it('passes a fusion block through with board_post_id required and run_id optional', () => {
    const withRunId = chatHistoryEntriesFromRest('echo', [
      {
        role: 'assistant',
        content: 'panel concluded',
        ts: 1_780_000_000,
        blocks: [{ t: 'fusion', board_post_id: 'post-1', run_id: 'fus-1' }],
      },
    ])
    expect(withRunId[0]?.blocks).toEqual([{ t: 'fusion', board_post_id: 'post-1', run_id: 'fus-1' }])

    const withoutRunId = chatHistoryEntriesFromRest('echo', [
      {
        role: 'assistant',
        content: 'panel concluded',
        ts: 1_780_000_000,
        blocks: [{ t: 'fusion', board_post_id: 'post-2' }] as any,
      },
    ])
    expect(withoutRunId[0]?.blocks).toEqual([{ t: 'fusion', board_post_id: 'post-2', run_id: undefined }])
  })

  it('drops a fusion block missing board_post_id and falls back to the local parser', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'assistant', content: 'panel concluded', ts: 1_780_000_000, blocks: [{ t: 'fusion', run_id: 'fus-orphan' }] as any },
    ])
    expect(entries[0]?.blocks).toEqual([{ t: 'p', html: 'panel concluded' }])
  })

  it('falls back to the local parser when server blocks are missing or empty', () => {
    const withMissing = chatHistoryEntriesFromRest('echo', [
      { role: 'assistant', content: 'https://x.com/post', ts: 1_780_000_000 },
    ])
    expect(withMissing[0]?.blocks).toEqual([{ t: 'link', url: 'https://x.com/post', title: 'x.com', meta: 'x.com' }])
    const withEmpty = chatHistoryEntriesFromRest('echo', [
      { role: 'assistant', content: 'https://x.com/post', ts: 1_780_000_000, blocks: [] },
    ])
    expect(withEmpty[0]?.blocks).toEqual([{ t: 'link', url: 'https://x.com/post', title: 'x.com', meta: 'x.com' }])
  })

  it('drops malformed server blocks and falls back to the local parser', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'assistant', content: 'hello', ts: 1_780_000_000, blocks: [{ t: 'unknown' }] as any },
    ])
    expect(entries[0]?.blocks).toEqual([{ t: 'p', html: 'hello' }])
  })

  it('preserves server-provided media blocks on user rows', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'https://x.com/post', ts: 1_780_000_000, blocks: [{ t: 'image', src: 'https://x.com/a.png' }] },
    ])
    expect(entries[0]?.blocks).toEqual([{ t: 'image', src: 'https://x.com/a.png' }])
  })

  it('drops html-bearing and forwarding payload blocks on user rows', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      {
        role: 'user',
        content: 'uploaded',
        ts: 1_780_000_000,
        blocks: [
          { t: 'code', html: '<img src=x onerror=alert(1)>' },
          { t: 'svg', svg: '<svg onload=alert(1) />' },
          {
            t: 'attach',
            name: 'screen.png',
            src: 'https://x.com/screen.png',
            svg: '<svg onload=alert(1) />',
            data: 'RAW',
            mimeType: 'image/svg+xml',
          },
        ] as any,
      },
    ])
    expect(entries[0]?.blocks).toEqual([
      { t: 'attach', name: 'screen.png', src: 'https://x.com/screen.png' },
    ])
  })

  it('does not locally parse user text into rich blocks', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'https://x.com/post', ts: 1_780_000_000 },
    ])
    expect(entries[0]?.blocks).toBeUndefined()
  })

  it('normalizes extended rich block shapes from history rows', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      {
        role: 'assistant',
        content: 'rich reply',
        ts: 1_780_000_000,
        blocks: [
          { t: 'attach', name: 'screen.png', src: 'https://x.com/screen.png', sizeBytes: 42, kind: 'image' },
          { t: 'voice', secs: 5, wave: [0.2, 0.6], transcript: 'memo' },
          { t: 'table', head: ['name', { v: 'count', num: true }], rows: [['a', '1']] },
        ],
      },
    ])
    expect(entries[0]?.blocks).toEqual([
      {
        t: 'attach',
        name: 'screen.png',
        src: 'https://x.com/screen.png',
        sizeBytes: 42,
        kind: 'image',
      },
      { t: 'voice', secs: 5, wave: [0.2, 0.6], transcript: 'memo' },
      { t: 'table', head: ['name', { v: 'count', num: true }], rows: [['a', '1']] },
    ])
  })

  it('drops tool rows that lack id or name and keeps the rest of the turn', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'hi', ts: 1_780_000_000 },
      { role: 'tool', content: '{}', ts: 1_780_000_000, tool_call_id: 'toolu_2' },
      { role: 'assistant', content: 'done', ts: 1_780_000_000 },
    ])
    expect(entries.map(e => e.role)).toEqual(['user', 'assistant'])
    expect(entries[1]?.label).toBe('echo')
  })

  it('preserves valid turn_ref on every persisted chat-history path and rejects malformed values', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'query', ts: 1_780_000_000, turn_ref: 'trace-a#1' },
      {
        role: 'tool',
        content: '{"q":1}',
        ts: 1_780_000_000,
        tool_call_id: 'toolu_turn',
        tool_call_name: 'masc_status',
        turn_ref: 'trace-a#1',
      },
      { role: 'assistant', content: 'answer', ts: 1_780_000_000, turn_ref: 'trace-a#1' },
      { role: 'assistant', content: 'legacy answer', ts: 1_780_000_001 },
      { role: 'user', content: 'bad user ref', ts: 1_780_000_002, turn_ref: 42 as unknown as string },
      {
        role: 'tool',
        content: '{"q":2}',
        ts: 1_780_000_003,
        tool_call_id: 'toolu_bad_ref',
        tool_call_name: 'masc_status',
        turn_ref: 42 as unknown as string,
      },
    ])

    expect(entries.map(e => e.turnRef)).toEqual([
      'trace-a#1',
      'trace-a#1',
      'trace-a#1',
      null,
      null,
      null,
    ])
  })

  it('dedups a rehydrated tool row against the live tool entry', () => {
    appendThreadEntry('echo', entry({
      id: 'tool-toolu_3',
      role: 'tool',
      source: 'tool_result',
      text: '{"q":1}',
      rawText: '{"q":1}',
      delivery: 'delivered',
    }))

    mergeServerHistoryEntries('echo', chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'query', ts: 1_780_000_000 },
      {
        role: 'tool',
        content: '{"q":1}',
        ts: 1_780_000_000,
        tool_call_id: 'toolu_3',
        tool_call_name: 'masc_status',
      },
      { role: 'assistant', content: 'answer', ts: 1_780_000_000 },
    ]))

    const thread = keeperThreads.value.echo ?? []
    expect(thread.filter(e => e.role === 'tool')).toHaveLength(1)
    expect(thread.map(e => e.role)).toEqual(['user', 'tool', 'assistant'])
  })

  it('dedups a streaming live tool row when matching history arrives', () => {
    appendThreadEntry('echo', entry({
      id: 'tool-toolu_streaming',
      role: 'tool',
      source: 'tool_result',
      label: 'Read',
      text: '{"path":"x"}',
      rawText: '{"path":"x"}',
      delivery: 'streaming',
      streamState: 'streaming',
    }))

    mergeServerHistoryEntries('echo', chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'query', ts: 1_780_000_000 },
      {
        role: 'tool',
        content: '{"path":"x"}',
        ts: 1_780_000_000,
        tool_call_id: 'toolu_streaming',
        tool_call_name: 'Read',
      },
      { role: 'assistant', content: 'answer', ts: 1_780_000_000 },
    ]))

    const tools = (keeperThreads.value.echo ?? []).filter(e => e.role === 'tool')
    expect(tools).toHaveLength(1)
    expect(tools[0]?.id).toBe('tool-toolu_streaming')
    expect(tools[0]?.delivery).toBe('history')
    expect(tools[0]?.streamState).toBeNull()
  })

  it('inserts before the target entry and appends when the target is missing', () => {
    appendThreadEntry('echo', entry({ id: 'reply-1', role: 'assistant', source: 'direct_assistant' }))
    insertThreadEntryBefore('echo', 'reply-1', entry({ id: 'tool-1', role: 'tool', source: 'tool_result' }))
    insertThreadEntryBefore('echo', 'missing', entry({ id: 'tail-1' }))

    const ids = (keeperThreads.value.echo ?? []).map(e => e.id)
    expect(ids).toEqual(['tool-1', 'reply-1', 'tail-1'])
  })

  it('does not duplicate an existing tool row when a start event repeats', () => {
    appendThreadEntry('echo', entry({ id: 'reply-1', role: 'assistant', source: 'direct_assistant' }))
    insertThreadEntryBefore('echo', 'reply-1', entry({ id: 'tool-1', role: 'tool', source: 'tool_result', text: '{"a":1}' }))
    insertThreadEntryBefore('echo', 'reply-1', entry({ id: 'tool-1', role: 'tool', source: 'tool_result', text: '{"a":2}' }))

    const tools = (keeperThreads.value.echo ?? []).filter(e => e.id === 'tool-1')
    expect(tools).toHaveLength(1)
    expect(tools[0]?.text).toBe('{"a":1}')
  })

  it('preserves accumulated tool trace state when TOOL_CALL_START repeats', () => {
    appendThreadEntry('echo', entry({ id: 'reply-1', role: 'assistant', source: 'direct_assistant' }))
    appendAssistantToolTraceStep('echo', 'reply-1', {
      toolCallId: 'tc-1',
      name: 'lookup',
      ts: '2026-06-25T00:00:00.000Z',
      oasBlockIndex: 5,
    })
    appendAssistantToolTraceArgsDelta('echo', 'reply-1', 'tc-1', '{"a":1}')
    markAssistantToolTraceEnded('echo', 'reply-1', 'tc-1')
    appendAssistantToolTraceStep('echo', 'reply-1', {
      toolCallId: 'tc-1',
      name: 'lookup-again',
      ts: '2026-06-25T00:00:01.000Z',
      oasBlockIndex: 6,
    })

    const reply = keeperThreads.value.echo?.find(e => e.id === 'reply-1')
    expect(reply?.traceSteps).toEqual([
      {
        kind: 'tool',
        name: 'lookup',
        toolCallId: 'tc-1',
        status: 'ok',
        args: '{"a":1}',
        ts: '2026-06-25T00:00:00.000Z',
        oasBlockIndex: 5,
      },
    ])
  })

  it('removes only the requested local thread entries', () => {
    appendThreadEntry('echo', entry({ id: 'user-1', role: 'user', text: 'question' }))
    appendThreadEntry('echo', entry({ id: 'reply-1', role: 'assistant', text: '' }))
    appendThreadEntry('echo', entry({ id: 'reply-2', role: 'assistant', text: 'answer' }))

    removeThreadEntries('echo', ['reply-1', 'missing'])

    const ids = (keeperThreads.value.echo ?? []).map(e => e.id)
    expect(ids).toEqual(['user-1', 'reply-2'])
  })

  it('caps the thread window at THREAD_ENTRY_CAP', () => {
    for (let i = 0; i < THREAD_ENTRY_CAP + 5; i++) {
      appendThreadEntry('echo', entry({ id: `e-${i}`, text: `m${i}` }))
    }
    expect(keeperThreads.value.echo).toHaveLength(THREAD_ENTRY_CAP)
    expect(keeperThreads.value.echo?.[0]?.id).toBe('e-5')
  })

  it('keeps local entries at the end when server history plus locals exceed the cap', () => {
    const history = Array.from({ length: THREAD_ENTRY_CAP }, (_, i) =>
      entry({ id: `hist-${i}`, text: `h${i}`, delivery: 'history' }),
    )
    appendThreadEntry('echo', entry({ id: 'local-1', text: 'live1' }))
    appendThreadEntry('echo', entry({ id: 'optimistic-1', text: 'live2' }))
    mergeServerHistoryEntries('echo', history)

    const thread = keeperThreads.value.echo ?? []
    expect(thread).toHaveLength(THREAD_ENTRY_CAP)
    expect(thread.at(-1)?.id).toBe('optimistic-1')
    expect(thread.at(-2)?.id).toBe('local-1')
  })

  it('sorts a stale locally-appended error into chronological position, not the bottom', () => {
    // A live turn failed days ago and appended an error entry, which stayed at
    // the end of the thread. Newer server history must not leave that days-old
    // dns_failure floating at the bottom where it reads as the newest message.
    appendThreadEntry(
      'echo',
      entry({ id: 'err-old', text: 'dns_failure', delivery: 'error', timestamp: '2026-06-15T00:00:00.000Z' }),
    )
    mergeServerHistoryEntries('echo', [
      entry({ id: 'h-16', text: 'day 16', delivery: 'history', timestamp: '2026-06-16T00:00:00.000Z' }),
      entry({ id: 'h-19', text: 'day 19', delivery: 'history', timestamp: '2026-06-19T00:00:00.000Z' }),
    ])
    const ids = (keeperThreads.value.echo ?? []).map(e => e.id)
    expect(ids).toEqual(['err-old', 'h-16', 'h-19'])
  })

  it('keeps no-timestamp live entries at the bottom of the sorted thread', () => {
    // A still-streaming/optimistic entry with no timestamp must sort last so the
    // in-flight tail stays at the bottom even as older history is merged.
    appendThreadEntry('echo', entry({ id: 'live', text: '응답 연결 중', delivery: 'sending', timestamp: null }))
    mergeServerHistoryEntries('echo', [
      entry({ id: 'h-19', text: 'day 19', delivery: 'history', timestamp: '2026-06-19T00:00:00.000Z' }),
    ])
    const ids = (keeperThreads.value.echo ?? []).map(e => e.id)
    expect(ids.at(-1)).toBe('live')
  })

  it('accepts attachment-only history rows', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      {
        role: 'user',
        content: '',
        ts: 1_780_000_000,
        attachments: [
          { id: 'att1', type: 'image', name: 'shot.png', size: 1234, mime_type: 'image/png', data: 'BASE64' },
        ],
      },
    ])
    expect(entries).toHaveLength(1)
    expect(entries[0]?.text).toBe('')
    expect(entries[0]?.attachments).toHaveLength(1)
  })

  it('still drops rows that have no content and no attachments', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: '', ts: 1_780_000_000 },
    ])
    expect(entries).toHaveLength(0)
  })
})

describe('R3 producer-assigned message id', () => {
  it('keys history entries off the server-minted id when present', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { id: 'msg-0001700000000000-0', role: 'user', content: 'hi', ts: 1_780_000_000 },
      { id: 'msg-0001700000000000-1', role: 'assistant', content: 'hello', ts: 1_780_000_000 },
    ])
    expect(entries.map(e => e.id)).toEqual([
      'msg-0001700000000000-0',
      'msg-0001700000000000-1',
    ])
  })

  it('derives a stable content-keyed id when a row predates R3 (no id)', () => {
    const first = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'same text', ts: 1_780_000_000 },
    ])
    const second = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'same text', ts: 1_780_000_000 },
    ])
    // Deterministic across calls — the former id was index/timestamp
    // derived; the fallback is content derived so it never shifts.
    expect(first[0]?.id).toBeTruthy()
    expect(first[0]?.id).toBe(second[0]?.id)
  })

  it('keeps the fallback id stable regardless of page position (the old index bug)', () => {
    const alone = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'stable', ts: 1_780_000_000 },
    ])
    const shifted = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'earlier', ts: 1_779_000_000 },
      { role: 'assistant', content: 'reply', ts: 1_779_000_000 },
      { role: 'user', content: 'stable', ts: 1_780_000_000 },
    ])
    const aloneId = alone.find(e => e.rawText === 'stable')?.id
    const shiftedId = shifted.find(e => e.rawText === 'stable')?.id
    expect(aloneId).toBeTruthy()
    expect(shiftedId).toBe(aloneId)
  })

  it('gives different content different fallback ids', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'one', ts: 1_780_000_000 },
      { role: 'user', content: 'two', ts: 1_780_000_000 },
    ])
    expect(entries[0]?.id).not.toBe(entries[1]?.id)
  })
})

describe('RFC-0235 audio clip normalization', () => {
  beforeEach(() => {
    keeperThreads.value = {}
  })

  function entry(partial: Partial<KeeperConversationEntry>): KeeperConversationEntry {
    return {
      id: 'e-1',
      role: 'user',
      source: 'direct_user',
      label: '사용자',
      text: 'hello',
      rawText: 'hello',
      timestamp: '2026-06-10T00:00:00.000Z',
      delivery: 'delivered',
      streamState: null,
      details: null,
      ...partial,
    }
  }

  it('normalizes snake_case history audio fields with a URL fallback', () => {
    const clip = normalizeAudioClip({
      token: 'clip-abc',
      mime: 'audio/mpeg',
      duration_sec: 7.5,
      message_text: 'hello',
      device_id: 'living-room',
    })
    expect(clip).toEqual({
      token: 'clip-abc',
      audioUrl: '/api/v1/voice/audio/clip-abc',
      mime: 'audio/mpeg',
      durationSec: 7.5,
      messageText: 'hello',
      deviceId: 'living-room',
      expired: null,
    })
  })

  it('carries the expired flag from the backend', () => {
    const clip = normalizeAudioClip({
      token: 'clip-expired',
      mime: 'audio/mpeg',
      message_text: 'hello',
      expired: true,
    })
    expect(clip).toEqual({
      token: 'clip-expired',
      audioUrl: '/api/v1/voice/audio/clip-expired',
      mime: 'audio/mpeg',
      durationSec: null,
      messageText: 'hello',
      deviceId: null,
      expired: true,
    })
  })

  it('preserves an explicit audio_url from SSE payloads', () => {
    const clip = normalizeAudioClip({
      token: 'clip-def',
      audioUrl: 'https://cdn.example/voice/clip-def.mp3',
      mime: 'audio/mpeg',
      messageText: 'hi',
    })
    expect(clip?.audioUrl).toBe('https://cdn.example/voice/clip-def.mp3')
  })

  it('returns null for malformed audio objects', () => {
    expect(normalizeAudioClip(null)).toBeNull()
    expect(normalizeAudioClip({ token: 'x' })).toBeNull()
    expect(normalizeAudioClip({ token: 'x', mime: 42 })).toBeNull()
  })

  it('carries audio clips through REST history into conversation entries', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      {
        role: 'assistant',
        content: 'hello there',
        ts: 1_780_000_000,
        audio: {
          token: 'hist-clip',
          mime: 'audio/mpeg',
          duration_sec: 3,
          message_text: 'hello there',
        },
      },
    ])
    expect(entries).toHaveLength(1)
    expect(entries[0]?.audio?.token).toBe('hist-clip')
    expect(entries[0]?.audio?.audioUrl).toBe('/api/v1/voice/audio/hist-clip')
  })

  it('attaches an SSE audio clip to the matching streaming assistant entry', () => {
    appendThreadEntry('echo', entry({
      id: 'reply-1',
      role: 'assistant',
      source: 'direct_assistant',
      text: 'hello operator',
      rawText: 'hello operator',
      delivery: 'streaming',
    }))
    const attached = attachKeeperAudioClip('echo', {
      token: 'live-clip',
      mime: 'audio/mpeg',
      message_text: 'hello operator',
      duration_sec: 4,
    })
    expect(attached).toBe(true)
    expect(keeperThreads.value.echo?.[0]?.audio?.token).toBe('live-clip')
  })

  it('does not attach when no assistant text matches', () => {
    appendThreadEntry('echo', entry({
      id: 'reply-1',
      role: 'assistant',
      source: 'direct_assistant',
      text: 'different text',
      rawText: 'different text',
    }))
    const attached = attachKeeperAudioClip('echo', {
      token: 'live-clip',
      mime: 'audio/mpeg',
      message_text: 'hello operator',
    })
    expect(attached).toBe(false)
    expect(keeperThreads.value.echo?.[0]?.audio).toBeUndefined()
  })
})
