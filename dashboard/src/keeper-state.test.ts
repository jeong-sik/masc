import { describe, expect, it } from 'vitest'
import { beforeEach } from 'vitest'
import {
  THREAD_ENTRY_CAP,
  appendThreadEntry,
  chatHistoryEntriesFromRest,
  insertThreadEntryBefore,
  isVisibleDirectConversationEntry,
  keeperThreads,
  mergeServerHistoryEntries,
  normalizeStatusDetail,
  setStatusDetail,
} from './keeper-state'
import type { KeeperConversationEntry } from './types'

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

  it('drops tool rows that lack id or name and keeps the rest of the turn', () => {
    const entries = chatHistoryEntriesFromRest('echo', [
      { role: 'user', content: 'hi', ts: 1_780_000_000 },
      { role: 'tool', content: '{}', ts: 1_780_000_000, tool_call_id: 'toolu_2' },
      { role: 'assistant', content: 'done', ts: 1_780_000_000 },
    ])
    expect(entries.map(e => e.role)).toEqual(['user', 'assistant'])
    expect(entries[1]?.label).toBe('echo')
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

  it('inserts before the target entry and appends when the target is missing', () => {
    appendThreadEntry('echo', entry({ id: 'reply-1', role: 'assistant', source: 'direct_assistant' }))
    insertThreadEntryBefore('echo', 'reply-1', entry({ id: 'tool-1', role: 'tool', source: 'tool_result' }))
    insertThreadEntryBefore('echo', 'missing', entry({ id: 'tail-1' }))

    const ids = (keeperThreads.value.echo ?? []).map(e => e.id)
    expect(ids).toEqual(['tool-1', 'reply-1', 'tail-1'])
  })

  it('caps the thread window at THREAD_ENTRY_CAP', () => {
    for (let i = 0; i < THREAD_ENTRY_CAP + 5; i++) {
      appendThreadEntry('echo', entry({ id: `e-${i}`, text: `m${i}` }))
    }
    expect(keeperThreads.value.echo).toHaveLength(THREAD_ENTRY_CAP)
    expect(keeperThreads.value.echo?.[0]?.id).toBe('e-5')
  })
})
