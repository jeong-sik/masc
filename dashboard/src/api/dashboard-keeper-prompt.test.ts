import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  fetchKeeperLastPrompt,
  putKeeperOperatorNote,
  fetchKeeperOperatorNote,
  fetchKeeperRawTrace,
  fetchKeeperRawTraces,
} from './dashboard-keeper-prompt'
import { clearStoredToken, setStoredToken } from './core'

// Keep each response fresh so every request observes an independent body.
function stubFetch(payload: unknown, status = 200) {
  const fetchMock = vi.fn().mockImplementation(
    async () =>
      new Response(JSON.stringify(payload), {
        status,
        headers: { 'Content-Type': 'application/json' },
      }),
  )
  vi.stubGlobal('fetch', fetchMock)
  setStoredToken('prompt-surface-test-token', { source: 'manual' })
  return fetchMock
}

afterEach(() => {
  clearStoredToken()
  vi.unstubAllGlobals()
})

const capture = {
  keeper: 'kidsnote',
  captured_at: 1786000000,
  trace_id: 'trace-a',
  absolute_turn: 17534,
  assembled_bytes: 435,
  assembled: '--- Memory OS Recall ---\nrevision 223\n',
  blocks: [
    { id: 'memory_os_recall', bytes: 435, text: '--- Memory OS Recall ---\nrevision 223\n' },
  ],
}

describe('last prompt', () => {
  it('keeps block text byte-for-byte, newlines included', async () => {
    const fetchMock = stubFetch(capture)
    const decoded = await fetchKeeperLastPrompt('kidsnote')
    expect(decoded.absoluteTurn).toBe(17534)
    expect(decoded.blocks[0]?.text).toBe('--- Memory OS Recall ---\nrevision 223\n')
    expect(decoded.assembled).toBe('--- Memory OS Recall ---\nrevision 223\n')
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(init.headers).toEqual({})
  })

  it('accepts the operator_note block this build knows', async () => {
    stubFetch({
      ...capture,
      blocks: [{ id: 'operator_note', bytes: 12, text: 'resume 195\n' }],
    })
    const decoded = await fetchKeeperLastPrompt('kidsnote')
    expect(decoded.blocks[0]?.id).toBe('operator_note')
  })

  // A capture written by a build with more blocks must not render as a shorter
  // prompt than the keeper actually received.
  it('rejects the whole capture when a block id is unknown', async () => {
    stubFetch({
      ...capture,
      blocks: [
        { id: 'memory_os_recall', bytes: 4, text: 'ok\n' },
        { id: 'future_block', bytes: 4, text: 'hidden\n' },
      ],
    })
    await expect(fetchKeeperLastPrompt('kidsnote')).rejects.toThrow('prompt capture')
  })

  it('distinguishes an absent assembled context from an empty one', async () => {
    stubFetch({ ...capture, assembled: null, assembled_bytes: 0, blocks: [] })
    const decoded = await fetchKeeperLastPrompt('kidsnote')
    expect(decoded.assembled).toBeNull()
    expect(decoded.blocks).toHaveLength(0)
  })
})

describe('raw traces', () => {
  it('decodes the turn listing', async () => {
    const fetchMock = stubFetch({
      keeper: 'kidsnote',
      turns: [{ file: 'turn-1.jsonl', trace_id: 'trace-kidsnote-1', bytes: 2048, records: 218, modified_at: 1786000000 }],
    })
    const turns = await fetchKeeperRawTraces('kidsnote', 25)
    expect(turns).toHaveLength(1)
    expect(turns[0]?.records).toBe(218)
    expect(turns[0]?.traceId).toBe('trace-kidsnote-1')
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/keepers/kidsnote/raw-traces?limit=25')
    expect(init.headers).toEqual({})
  })

  // A torn line occupies its own position. Dropping it would make a damaged
  // trace read as a shorter one.
  it('keeps an unparseable record in place', async () => {
    stubFetch({
      file: 'turn-1.jsonl',
      total_records: 3,
      offset: 0,
      records: [
        { ok: true, raw: '{"seq":1,"record_type":"run_started"}', record: { seq: 1, record_type: 'run_started' } },
        { ok: false, raw: '{not json', error: 'Line 2: invalid token' },
        { ok: true, raw: '{"seq":3,"record_type":"run_finished"}', record: { seq: 3, record_type: 'run_finished' } },
      ],
    })
    const page = await fetchKeeperRawTrace('kidsnote', 'turn-1.jsonl')
    expect(page.totalRecords).toBe(3)
    expect(page.records).toHaveLength(3)
    expect(page.records[1]).toEqual({ ok: false, raw: '{not json', error: 'Line 2: invalid token' })
  })

  it('rejects a record that is neither ok nor an error', async () => {
    stubFetch({
      file: 'turn-1.jsonl',
      total_records: 1,
      offset: 0,
      records: [{ record: { seq: 1 } }],
    })
    await expect(fetchKeeperRawTrace('kidsnote', 'turn-1.jsonl')).rejects.toThrow('raw trace')
  })
})

describe('operator note', () => {
  it('reports a pending note', async () => {
    stubFetch({
      keeper: 'kidsnote',
      pending: true,
      note: {
        text: 'openssl decision landed',
        created_at: 1786000000,
        created_by: 'operator',
        consumed_at: null,
        consumed_turn: null,
      },
    })
    const note = await fetchKeeperOperatorNote('kidsnote')
    expect(note.pending).toBe(true)
    expect(note.consumedTurn).toBeNull()
  })

  // Delivered and never-existed must not read the same. The consuming turn is
  // the answer to the first question an operator asks.
  it('reports the turn that consumed a delivered note', async () => {
    stubFetch({
      keeper: 'kidsnote',
      pending: false,
      note: {
        text: 'openssl decision landed',
        created_at: 1786000000,
        created_by: 'operator',
        consumed_at: 1786000100,
        consumed_turn: 17534,
      },
    })
    const note = await fetchKeeperOperatorNote('kidsnote')
    expect(note.pending).toBe(false)
    expect(note.consumedTurn).toBe(17534)
  })

  it('rejects a payload whose consumed_turn is neither null nor a number', async () => {
    stubFetch({
      keeper: 'kidsnote',
      pending: false,
      note: {
        text: 'x',
        created_at: 1786000000,
        created_by: 'operator',
        consumed_at: 1786000100,
        consumed_turn: 'seventeen',
      },
    })
    await expect(fetchKeeperOperatorNote('kidsnote')).rejects.toThrow('operator note')
  })
})

describe('writing an operator note', () => {
  it('returns the stored note as pending', async () => {
    stubFetch({
      ok: true,
      keeper: 'kidsnote',
      pending: true,
      note: {
        text: 'resume task-195',
        created_at: 1786000000,
        created_by: 'operator',
        consumed_at: null,
        consumed_turn: null,
      },
    })
    const note = await putKeeperOperatorNote('kidsnote', 'resume task-195')
    expect(note.pending).toBe(true)
    expect(note.text).toBe('resume task-195')
  })

  // The server refuses oversized text rather than truncating it. That refusal
  // has to reach the operator, because a silently shortened instruction is a
  // different instruction and they would not know which one arrived.
  it('surfaces the server refusal instead of resolving', async () => {
    stubFetch(
      {
        ok: false,
        keeper: 'kidsnote',
        error: 'operator note is 8192 bytes; the cap is 4096.',
      },
      400,
    )
    await expect(putKeeperOperatorNote('kidsnote', 'x'.repeat(8192))).rejects.toThrow(
      /8192 bytes/,
    )
  })
})
