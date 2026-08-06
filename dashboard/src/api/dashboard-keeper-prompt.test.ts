import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  fetchKeeperLastPrompt,
  fetchKeeperOperatorNote,
  fetchKeeperRawTrace,
  fetchKeeperRawTraces,
} from './dashboard-keeper-prompt'
import { clearStoredToken, setStoredToken } from './core'

// A Response body can only be read once and ensureDevToken consumes the first,
// so each call needs a fresh instance rather than one shared mock value.
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
    stubFetch(capture)
    const decoded = await fetchKeeperLastPrompt('kidsnote')
    expect(decoded.absoluteTurn).toBe(17534)
    expect(decoded.blocks[0]?.text).toBe('--- Memory OS Recall ---\nrevision 223\n')
    expect(decoded.assembled).toBe('--- Memory OS Recall ---\nrevision 223\n')
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
    stubFetch({
      keeper: 'kidsnote',
      turns: [{ file: 'turn-1.jsonl', bytes: 2048, records: 218, modified_at: 1786000000 }],
    })
    const turns = await fetchKeeperRawTraces('kidsnote', 25)
    expect(turns).toHaveLength(1)
    expect(turns[0]?.records).toBe(218)
  })

  // A torn line occupies its own position. Dropping it would make a damaged
  // trace read as a shorter one.
  it('keeps an unparseable record in place', async () => {
    stubFetch({
      file: 'turn-1.jsonl',
      total_records: 3,
      offset: 0,
      records: [
        { ok: true, record: { seq: 1, record_type: 'run_started' } },
        { ok: false, error: 'Line 2: invalid token' },
        { ok: true, record: { seq: 3, record_type: 'run_finished' } },
      ],
    })
    const page = await fetchKeeperRawTrace('kidsnote', 'turn-1.jsonl')
    expect(page.totalRecords).toBe(3)
    expect(page.records).toHaveLength(3)
    expect(page.records[1]).toEqual({ ok: false, error: 'Line 2: invalid token' })
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
