import { describe, expect, it } from 'vitest'
import { createCollabJoin, feedCollabJoin } from './collab-join'
import type { CollabEntry, CollabFrame } from './collab-wire'

function welcome(op = 'op-1'): CollabFrame {
  return {
    kind: 'welcome', proto: 1, keeper: 'narae', operation: op,
    active: true, guests: 1, entryCount: 2, readOnly: true,
  }
}

function entry(opSeq: number, op = 'op-1'): CollabEntry {
  return { kind: 'entry', seq: opSeq, op, opSeq, ts: 1.0, event: { type: 'text_delta', delta: 'x' } }
}

function chunk(seqs: number[], final: boolean): CollabFrame {
  return {
    kind: 'snapshot-chunk',
    entries: seqs.map(seq => ({ seq, ts: 1.0, event: { type: 'text_delta', delta: 's' } })),
    final,
  }
}

describe('feedCollabJoin', () => {
  it('buffers pre-welcome entries and flushes the unseen ones at the final chunk', () => {
    const join = createCollabJoin()
    expect(feedCollabJoin(join, entry(1))).toEqual([])
    expect(feedCollabJoin(join, entry(3))).toEqual([])
    const [state] = feedCollabJoin(join, welcome())
    expect(state?.kind).toBe('state')
    // Snapshot holds rows 1-2; buffered entry 1 is a dup, entry 3 is fresh.
    const events = feedCollabJoin(join, chunk([1, 2], true))
    expect(events.map(event => event.kind)).toEqual(['snapshot-row', 'snapshot-row', 'live-entry'])
    const live = events[2]
    expect(live?.kind === 'live-entry' && live.entry.opSeq).toBe(3)
  })

  it('buffers entries that arrive mid-snapshot', () => {
    const join = createCollabJoin()
    feedCollabJoin(join, welcome())
    expect(feedCollabJoin(join, chunk([1], false)).map(event => event.kind)).toEqual(['snapshot-row'])
    expect(feedCollabJoin(join, entry(9))).toEqual([])
    const events = feedCollabJoin(join, chunk([2], true))
    expect(events.map(event => event.kind)).toEqual(['snapshot-row', 'live-entry'])
  })

  it('drops live entries the snapshot already holds, after the join', () => {
    const join = createCollabJoin()
    feedCollabJoin(join, welcome())
    feedCollabJoin(join, chunk([1, 2], true))
    expect(feedCollabJoin(join, entry(2))).toEqual([])
    expect(feedCollabJoin(join, entry(5))).toHaveLength(1)
  })

  it('a second welcome updates state without resetting the join', () => {
    const join = createCollabJoin()
    feedCollabJoin(join, entry(4))
    feedCollabJoin(join, welcome())
    const again: CollabFrame = {
      kind: 'welcome', proto: 1, keeper: 'narae', operation: 'op-1',
      active: false, guests: 7, entryCount: 0, readOnly: false,
    }
    const [state] = feedCollabJoin(join, again)
    expect(state).toMatchObject({
      kind: 'state',
      state: { kind: 'state', active: false, guests: 7 },
      welcome: { keeper: 'narae', operation: 'op-1', readOnly: false },
    })
    // The buffered entry survives the second welcome.
    const events = feedCollabJoin(join, chunk([], true))
    expect(events.map(event => event.kind)).toEqual(['live-entry'])
  })

  it('drops chunks outside a snapshot', () => {
    const join = createCollabJoin()
    expect(feedCollabJoin(join, chunk([1], true))).toEqual([])
    feedCollabJoin(join, welcome())
    feedCollabJoin(join, chunk([1], true))
    expect(feedCollabJoin(join, chunk([2], true))).toEqual([])
  })

  it('ignores guest-bound frames from the host', () => {
    const join = createCollabJoin()
    feedCollabJoin(join, welcome())
    expect(feedCollabJoin(join, { kind: 'hello', proto: 1, writeToken: null, label: null })).toEqual([])
    expect(feedCollabJoin(join, { kind: 'prompt', text: 'x' })).toEqual([])
    expect(feedCollabJoin(join, { kind: 'abort' })).toEqual([])
    expect(feedCollabJoin(join, { kind: 'fetch-transcript', reqId: 1, maxBytes: 1 })).toEqual([])
  })

  it('passes state, transcript, bye, and errors through in any phase', () => {
    const join = createCollabJoin()
    expect(feedCollabJoin(join, { kind: 'state', active: true, guests: 3 })).toEqual([
      { kind: 'state', state: { kind: 'state', active: true, guests: 3 }, welcome: null },
    ])
    expect(
      feedCollabJoin(join, { kind: 'transcript', reqId: 1, text: 't', newSize: 1, error: null })[0]?.kind,
    ).toBe('transcript')
    expect(feedCollabJoin(join, { kind: 'bye', reason: 'done' })).toEqual([
      { kind: 'bye', reason: 'done' },
    ])
    expect(feedCollabJoin(join, { kind: 'error', message: 'bad' })).toEqual([
      { kind: 'error-frame', message: 'bad' },
    ])
  })
})
