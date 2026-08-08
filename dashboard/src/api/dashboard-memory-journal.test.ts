import { afterEach, describe, expect, it, vi } from 'vitest'
import { fetchKeeperMemoryJournal } from './dashboard-memory-journal'
import { clearStoredToken, setStoredToken } from './core'

// A Response body reads once and ensureDevToken consumes the first, so each
// call needs a fresh instance rather than one shared mock value.
function stubFetch(payload: unknown) {
  vi.stubGlobal(
    'fetch',
    vi.fn().mockImplementation(
      async () =>
        new Response(JSON.stringify(payload), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
    ),
  )
  setStoredToken('journal-test-token', { source: 'manual' })
}

afterEach(() => {
  clearStoredToken()
  vi.unstubAllGlobals()
})

const committed = {
  ok: true,
  outcome: 'committed',
  recorded_at: 1786000000,
  revision: 223,
  source: { kind: 'librarian', trace_id: 'trace-a', generation: 1 },
  change: {
    added: [{ claim: 'x', category: 'fact', first_seen: 1785990000 }],
    removed: [],
    retained: 3,
  },
  dropped: [{ memory_id: 'id:gone', reason: 'superseded by the openssl decision' }],
}

const failed = {
  ok: true,
  outcome: 'failed',
  recorded_at: 1786000100,
  trace_id: 'trace-b',
  kind: 'runtime_context_unavailable',
  detail: 'Eio net/clock context unavailable',
  snapshot_present: false,
  cadence_deferred: false,
}

function payload(entries: unknown[], undecodable = 0) {
  return { keeper: 'kidsnote', returned: entries.length, undecodable_lines: undecodable, entries }
}

describe('memory journal', () => {
  it('keeps a commit and a failure as different members', async () => {
    stubFetch(payload([committed, failed]))
    const journal = await fetchKeeperMemoryJournal('kidsnote')
    const [first, second] = journal.entries
    expect(first?.ok).toBe(true)
    expect(first && first.ok && first.outcome).toBe('committed')
    expect(second && second.ok && second.outcome).toBe('failed')
    // A failure has no revision to read, which is the point of the split.
    if (first?.ok && first.outcome === 'committed') expect(first.revision).toBe(223)
    if (second?.ok && second.outcome === 'failed') {
      expect(second.detail).toBe('Eio net/clock context unavailable')
      expect(second.kind).toBe('runtime_context_unavailable')
    }
  })

  // Drop reasons ride this line and nothing else stores them.
  it('carries the librarian drop reasons', async () => {
    stubFetch(payload([committed]))
    const journal = await fetchKeeperMemoryJournal('kidsnote')
    const entry = journal.entries[0]
    if (!entry?.ok || entry.outcome !== 'committed') throw new Error('expected a commit')
    expect(entry.sourceKind).toBe('librarian')
    expect(entry.added).toEqual([{ claim: 'x', category: 'fact', firstSeen: 1785990000 }])
    expect(entry.drops).toHaveLength(1)
    expect(entry.drops[0]?.reason).toBe('superseded by the openssl decision')
  })

  it('keeps a torn line in place with its reason', async () => {
    stubFetch(payload([committed, { ok: false, error: 'not valid JSON' }], 1))
    const journal = await fetchKeeperMemoryJournal('kidsnote')
    expect(journal.undecodableLines).toBe(1)
    expect(journal.entries[1]).toEqual({ ok: false, error: 'not valid JSON' })
  })

  // An outcome from a wider build must not be rendered as something else —
  // that would describe a pass that never happened.
  it('rejects the payload when an outcome is unknown', async () => {
    stubFetch(payload([{ ...committed, outcome: 'deferred' }]))
    await expect(fetchKeeperMemoryJournal('kidsnote')).rejects.toThrow('memory journal')
  })

  it('rejects a commit whose change block is missing', async () => {
    const { change: _change, ...withoutChange } = committed
    stubFetch(payload([withoutChange]))
    await expect(fetchKeeperMemoryJournal('kidsnote')).rejects.toThrow('memory journal')
  })

  it('rejects a commit whose memory producer is unknown', async () => {
    stubFetch(payload([{ ...committed, source: { ...committed.source, kind: 'legacy_writer' } }]))
    await expect(fetchKeeperMemoryJournal('kidsnote')).rejects.toThrow('memory journal')
  })
})
