import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  COALESCE_WINDOW_MS,
  RETENTION_MS,
  clearTraces,
  keeperTraceState,
  pushTrace,
  tracesByKeeper,
  tracesBySource,
} from './keeper-trace-store'

beforeEach(() => {
  clearTraces()
})

afterEach(() => {
  clearTraces()
})

describe('keeper-trace-store', () => {
  it('starts empty', () => {
    expect(keeperTraceState.value.events).toHaveLength(0)
  })

  it('appends a single event with count=1', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'th-1',
      line: 12,
    })
    expect(keeperTraceState.value.events).toHaveLength(1)
    expect(keeperTraceState.value.events[0]).toMatchObject({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'anchored-thread',
      count: 1,
    })
  })

  it('coalesces two events of the same (source, keeperName) within COALESCE_WINDOW_MS', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'cascade-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1000 + COALESCE_WINDOW_MS,
      keeperName: 'scholar',
      source: 'cascade-hop',
      hopId: 'h-2',
      provider: 'glm',
    })
    expect(keeperTraceState.value.events).toHaveLength(1)
    const merged = keeperTraceState.value.events[0]!
    expect(merged.count).toBe(2)
    // Coalesced entry preserves the original id (first event), updates tsMs.
    expect(merged.id).toBe('a-1')
    expect(merged.tsMs).toBe(1000 + COALESCE_WINDOW_MS)
  })

  it('does NOT coalesce when the gap exceeds COALESCE_WINDOW_MS', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'cascade-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1000 + COALESCE_WINDOW_MS + 1,
      keeperName: 'scholar',
      source: 'cascade-hop',
      hopId: 'h-2',
      provider: 'glm',
    })
    expect(keeperTraceState.value.events).toHaveLength(2)
    expect(keeperTraceState.value.events.map(e => e.count)).toEqual([1, 1])
  })

  it('does NOT coalesce events from different sources within the window', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'cascade-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1010,
      keeperName: 'scholar',
      source: 'bdi-snapshot',
      intention: 'inspect',
    })
    expect(keeperTraceState.value.events).toHaveLength(2)
    expect(keeperTraceState.value.events.map(e => e.source)).toEqual(['cascade-hop', 'bdi-snapshot'])
  })

  it('does NOT coalesce same-source events for different keepers within the window', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'cascade-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1010,
      keeperName: 'moth',
      source: 'cascade-hop',
      hopId: 'h-2',
      provider: 'glm',
    })
    expect(keeperTraceState.value.events).toHaveLength(2)
    expect(keeperTraceState.value.events.map(e => e.keeperName)).toEqual(['scholar', 'moth'])
  })

  it('inserts out-of-order events into ascending tsMs position', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 5000,
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'th-1',
      line: 1,
    })
    pushTrace({
      id: 'a-2',
      tsMs: 2000,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'd-1',
      semanticOutcome: 'success',
    })
    pushTrace({
      id: 'a-3',
      tsMs: 3500,
      keeperName: 'scholar',
      source: 'bdi-snapshot',
      intention: 'inspect',
    })
    expect(keeperTraceState.value.events.map(e => e.tsMs)).toEqual([2000, 3500, 5000])
    expect(keeperTraceState.value.events.map(e => e.id)).toEqual(['a-2', 'a-3', 'a-1'])
  })

  it('coalesces beyond count=2 (3+ rapid events)', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'd-1',
      semanticOutcome: 'success',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1010,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'd-2',
      semanticOutcome: 'success',
    })
    pushTrace({
      id: 'a-3',
      tsMs: 1040,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'd-3',
      semanticOutcome: 'success',
    })
    expect(keeperTraceState.value.events).toHaveLength(1)
    const merged = keeperTraceState.value.events[0]!
    expect(merged.count).toBe(3)
    expect(merged.id).toBe('a-1') // first id preserved
    expect(merged.tsMs).toBe(1040)
  })

  it('prunes events older than RETENTION_MS relative to the latest', () => {
    pushTrace({
      id: 'old-1',
      tsMs: 0,
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'th-old',
      line: 1,
    })
    pushTrace({
      id: 'old-2',
      tsMs: 200,
      keeperName: 'moth',
      source: 'cascade-hop',
      hopId: 'h-old',
      provider: 'glm',
    })
    // Push event at RETENTION_MS + 500 → cutoff = 500, both prior events
    // (tsMs 0 + 200) fall outside the window.
    pushTrace({
      id: 'fresh-1',
      tsMs: RETENTION_MS + 500,
      keeperName: 'luna',
      source: 'bdi-snapshot',
      intention: 'review',
    })
    expect(keeperTraceState.value.events.map(e => e.id)).toEqual(['fresh-1'])
  })

  it('keeps events that are inside RETENTION_MS but past the cutoff midpoint', () => {
    pushTrace({
      id: 'survivor',
      tsMs: 5_000,
      keeperName: 'scholar',
      source: 'cascade-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    // Push event at RETENTION_MS + 10 → cutoff = 10, survivor@5000 stays
    // because 5000 >= 10.
    pushTrace({
      id: 'fresh',
      tsMs: RETENTION_MS + 10,
      keeperName: 'luna',
      source: 'bdi-snapshot',
      intention: 'review',
    })
    expect(keeperTraceState.value.events.map(e => e.id)).toEqual(['survivor', 'fresh'])
  })

  it('keeps boundary event exactly at retention edge', () => {
    pushTrace({
      id: 'boundary',
      tsMs: 0,
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'th-1',
      line: 1,
    })
    pushTrace({
      id: 'fresh',
      tsMs: RETENTION_MS,
      keeperName: 'moth',
      source: 'cascade-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    // Latest tsMs = RETENTION_MS, cutoff = 0 → boundary at tsMs=0 is kept (>= cutoff).
    expect(keeperTraceState.value.events.map(e => e.id)).toEqual(['boundary', 'fresh'])
  })

  it('clearTraces drops every event', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'cascade-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    clearTraces()
    expect(keeperTraceState.value.events).toHaveLength(0)
  })

  it('clearTraces is idempotent on empty state', () => {
    const stateBefore = keeperTraceState.value
    clearTraces()
    expect(keeperTraceState.value).toBe(stateBefore)
  })

  it('tracesByKeeper filters by keeperName and rejects whitespace', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'cascade-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1100,
      keeperName: 'moth',
      source: 'cascade-hop',
      hopId: 'h-2',
      provider: 'glm',
    })
    expect(tracesByKeeper('scholar').map(e => e.id)).toEqual(['a-1'])
    expect(tracesByKeeper('moth').map(e => e.id)).toEqual(['a-2'])
    expect(tracesByKeeper(' ')).toEqual([])
  })

  it('tracesBySource filters by source variant', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'cascade-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1100,
      keeperName: 'scholar',
      source: 'bdi-snapshot',
      intention: 'inspect',
    })
    pushTrace({
      id: 'a-3',
      tsMs: 1200,
      keeperName: 'moth',
      source: 'bdi-snapshot',
      intention: 'review',
    })
    expect(tracesBySource('cascade-hop').map(e => e.id)).toEqual(['a-1'])
    expect(tracesBySource('bdi-snapshot').map(e => e.id)).toEqual(['a-2', 'a-3'])
    expect(tracesBySource('decision-log')).toEqual([])
  })

  it('preserves discriminated-union narrowing for each source', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'th-1',
      line: 12,
    })
    pushTrace({
      id: 'b-1',
      tsMs: 1100,
      keeperName: 'scholar',
      source: 'cascade-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'c-1',
      tsMs: 1200,
      keeperName: 'scholar',
      source: 'bdi-snapshot',
      intention: 'inspect',
    })
    pushTrace({
      id: 'd-1',
      tsMs: 1300,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'dec-1',
      semanticOutcome: 'success',
    })

    for (const event of keeperTraceState.value.events) {
      // Compile-time exhaustive narrowing.
      switch (event.source) {
        case 'anchored-thread':
          expect(event.threadId).toBe('th-1')
          expect(event.line).toBe(12)
          break
        case 'cascade-hop':
          expect(event.hopId).toBe('h-1')
          expect(event.provider).toBe('glm')
          break
        case 'bdi-snapshot':
          expect(event.intention).toBe('inspect')
          break
        case 'decision-log':
          expect(event.decisionId).toBe('dec-1')
          expect(event.semanticOutcome).toBe('success')
          break
      }
    }
  })
})
