import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  bridgePostsToTrace,
  type AnchoredThreadProducerInput,
} from './anchored-thread-trace-bridge'
import {
  clearTraces,
  keeperTraceState,
} from './keeper-trace-store'

function post(
  id: string,
  ts_iso: string,
  keeper: string,
): AnchoredThreadProducerInput {
  return { id, created_at_iso: ts_iso, author_identity: keeper }
}

beforeEach(() => {
  clearTraces()
})

afterEach(() => {
  clearTraces()
})

describe('bridgePostsToTrace — RFC-0028 PR-δ anchored-thread producer', () => {
  it('emits a trace event for every post on the first call', () => {
    const out = bridgePostsToTrace(
      [
        post('p1', '2026-05-06T01:00:00Z', 'scholar'),
        post('p2', '2026-05-06T01:00:01Z', 'moth'),
      ],
      new Set(),
    )

    expect([...out].sort()).toEqual(['p1', 'p2'])
    const events = keeperTraceState.value.events
    expect(events.length).toBe(2)
    expect(events.every(e => e.source === 'anchored-thread')).toBe(true)
  })

  it('does not re-emit posts that are in the alreadyEmitted set', () => {
    const known = new Set(['p1'])
    bridgePostsToTrace(
      [
        post('p1', '2026-05-06T01:00:00Z', 'scholar'),
        post('p2', '2026-05-06T01:00:01Z', 'moth'),
      ],
      known,
    )

    const ids = keeperTraceState.value.events.map(e => e.id).sort()
    expect(ids).toEqual(['p2'])
  })

  it('returns an updated set including all newly emitted ids', () => {
    const out = bridgePostsToTrace(
      [post('p1', '2026-05-06T01:00:00Z', 'scholar')],
      new Set(['p0']),
    )
    expect([...out].sort()).toEqual(['p0', 'p1'])
  })

  it('returns the input set unchanged when posts is empty', () => {
    const before = new Set(['p0'])
    const after = bridgePostsToTrace([], before)
    expect(after).toBe(before)
    expect(keeperTraceState.value.events.length).toBe(0)
  })

  it('skips posts with malformed created_at_iso (NaN-guard)', () => {
    bridgePostsToTrace(
      [
        post('bad', 'not-a-date', 'scholar'),
        post('p1', '2026-05-06T01:00:00Z', 'moth'),
      ],
      new Set(),
    )
    const ids = keeperTraceState.value.events.map(e => e.id)
    expect(ids).toEqual(['p1'])
  })

  it('maps fields correctly: id, tsMs, keeperName, threadId, source, line=null', () => {
    bridgePostsToTrace(
      [post('p1', '2026-05-06T01:00:00Z', 'scholar')],
      new Set(),
    )
    const event = keeperTraceState.value.events[0]!
    expect(event.id).toBe('p1')
    expect(event.tsMs).toBe(Date.parse('2026-05-06T01:00:00Z'))
    expect(event.keeperName).toBe('scholar')
    expect(event.source).toBe('anchored-thread')
    if (event.source === 'anchored-thread') {
      expect(event.threadId).toBe('p1')
      expect(event.line).toBeNull()
    }
  })

  it('is idempotent across repeated calls with the returned set', () => {
    const inputs = [
      post('p1', '2026-05-06T01:00:00Z', 'scholar'),
      post('p2', '2026-05-06T01:00:01Z', 'moth'),
    ]
    let known: ReadonlySet<string> = new Set()
    known = bridgePostsToTrace(inputs, known)
    known = bridgePostsToTrace(inputs, known)
    known = bridgePostsToTrace(inputs, known)

    expect(keeperTraceState.value.events.length).toBe(2)
  })
})
