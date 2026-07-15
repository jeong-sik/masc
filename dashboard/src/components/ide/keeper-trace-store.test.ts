import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  COALESCE_WINDOW_MS,
  RETENTION_MS,
  clearTraces,
  filterTraceEventsByReplay,
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

  it('filters trace events at the replay cursor', () => {
    pushTrace({
      id: 'old',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'old-thread',
      line: 12,
    })
    pushTrace({
      id: 'new',
      tsMs: 2000,
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'new-thread',
      line: 13,
    })

    expect(filterTraceEventsByReplay(keeperTraceState.value.events, null).map(e => e.id))
      .toEqual(['old', 'new'])
    expect(filterTraceEventsByReplay(keeperTraceState.value.events, 1500).map(e => e.id))
      .toEqual(['old'])
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
      source: 'runtime-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1000 + COALESCE_WINDOW_MS,
      keeperName: 'scholar',
      source: 'runtime-hop',
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
      source: 'runtime-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1000 + COALESCE_WINDOW_MS + 1,
      keeperName: 'scholar',
      source: 'runtime-hop',
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
      source: 'runtime-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1010,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'dec-a-2',
      semanticOutcome: 'success',
    })
    expect(keeperTraceState.value.events).toHaveLength(2)
    expect(keeperTraceState.value.events.map(e => e.source)).toEqual(['runtime-hop', 'decision-log'])
  })

  it('does NOT coalesce same-source events for different keepers within the window', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'runtime-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1010,
      keeperName: 'moth',
      source: 'runtime-hop',
      hopId: 'h-2',
      provider: 'glm',
    })
    expect(keeperTraceState.value.events).toHaveLength(2)
    expect(keeperTraceState.value.events.map(e => e.keeperName)).toEqual(['scholar', 'moth'])
  })

  it('does NOT coalesce anchored-thread events for different file lines within the window', () => {
    pushTrace({
      id: 'a-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'th-1',
      filePath: 'runtime.ts',
      line: 12,
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1010,
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'th-2',
      filePath: 'worker.ts',
      line: 12,
    })
    pushTrace({
      id: 'a-3',
      tsMs: 1020,
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'th-3',
      filePath: 'runtime.ts',
      line: 20,
    })

    expect(keeperTraceState.value.events.map(e => e.id)).toEqual(['a-1', 'a-2', 'a-3'])
    expect(keeperTraceState.value.events.map(e => e.count)).toEqual([1, 1, 1])
  })

  it('does NOT coalesce activity events for different file lines within the window', () => {
    pushTrace({
      id: 'activity-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'activity-event',
      eventId: 'evt-1',
      filePath: 'runtime.ts',
      line: 12,
      surface: 'Task',
    })
    pushTrace({
      id: 'activity-2',
      tsMs: 1010,
      keeperName: 'scholar',
      source: 'activity-event',
      eventId: 'evt-2',
      filePath: 'worker.ts',
      line: 12,
      surface: 'Task',
    })
    pushTrace({
      id: 'activity-3',
      tsMs: 1020,
      keeperName: 'scholar',
      source: 'activity-event',
      eventId: 'evt-3',
      filePath: 'runtime.ts',
      line: 20,
      surface: 'Log',
    })

    expect(keeperTraceState.value.events.map(e => e.id)).toEqual(['activity-1', 'activity-2', 'activity-3'])
    expect(keeperTraceState.value.events.map(e => e.count)).toEqual([1, 1, 1])
  })

  it('does NOT coalesce record events with different optional trace contexts', () => {
    pushTrace({
      id: 'decision-1',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'd-1',
      semanticOutcome: 'success',
      filePath: 'runtime.ts',
      line: 12,
      taskId: 'task-runtime',
    })
    pushTrace({
      id: 'decision-2',
      tsMs: 1010,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'd-2',
      semanticOutcome: 'success',
      filePath: 'runtime.ts',
      line: 13,
      taskId: 'task-runtime',
    })
    pushTrace({
      id: 'decision-3',
      tsMs: 1020,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'd-3',
      semanticOutcome: 'success',
      filePath: 'runtime.ts',
      line: 12,
      taskId: 'task-other',
    })

    expect(keeperTraceState.value.events.map(e => e.id)).toEqual([
      'decision-1',
      'decision-2',
      'decision-3',
    ])
    expect(keeperTraceState.value.events.map(e => e.count)).toEqual([1, 1, 1])
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
      source: 'decision-log',
      decisionId: 'dec-a-3',
      semanticOutcome: 'success',
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
      source: 'runtime-hop',
      hopId: 'h-old',
      provider: 'glm',
    })
    // Push event at RETENTION_MS + 500 → cutoff = 500, both prior events
    // (tsMs 0 + 200) fall outside the window.
    pushTrace({
      id: 'fresh-1',
      tsMs: RETENTION_MS + 500,
      keeperName: 'luna',
      source: 'decision-log',
      decisionId: 'dec-fresh-1',
      semanticOutcome: 'success',
    })
    expect(keeperTraceState.value.events.map(e => e.id)).toEqual(['fresh-1'])
  })

  it('keeps events that are inside RETENTION_MS but past the cutoff midpoint', () => {
    pushTrace({
      id: 'survivor',
      tsMs: 5_000,
      keeperName: 'scholar',
      source: 'runtime-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    // Push event at RETENTION_MS + 10 → cutoff = 10, survivor@5000 stays
    // because 5000 >= 10.
    pushTrace({
      id: 'fresh',
      tsMs: RETENTION_MS + 10,
      keeperName: 'luna',
      source: 'decision-log',
      decisionId: 'dec-fresh',
      semanticOutcome: 'success',
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
      source: 'runtime-hop',
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
      source: 'runtime-hop',
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
      source: 'runtime-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1100,
      keeperName: 'moth',
      source: 'runtime-hop',
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
      source: 'runtime-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'a-2',
      tsMs: 1100,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'dec-a-2-bysource',
      semanticOutcome: 'success',
    })
    pushTrace({
      id: 'a-3',
      tsMs: 1200,
      keeperName: 'moth',
      source: 'decision-log',
      decisionId: 'dec-a-3-bysource',
      semanticOutcome: 'success',
    })
    expect(tracesBySource('runtime-hop').map(e => e.id)).toEqual(['a-1'])
    expect(tracesBySource('decision-log').map(e => e.id)).toEqual(['a-2', 'a-3'])
    expect(tracesBySource('activity-event')).toEqual([])
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
      source: 'runtime-hop',
      hopId: 'h-1',
      provider: 'glm',
    })
    pushTrace({
      id: 'd-1',
      tsMs: 1300,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'dec-1',
      semanticOutcome: 'success',
    })
    pushTrace({
      id: 'e-1',
      tsMs: 1400,
      keeperName: 'scholar',
      source: 'activity-event',
      eventId: 'evt-1',
      filePath: 'runtime.ts',
      line: 9,
      surface: 'Task',
    })

    for (const event of keeperTraceState.value.events) {
      // Compile-time exhaustive narrowing.
      switch (event.source) {
        case 'anchored-thread':
          expect(event.threadId).toBe('th-1')
          expect(event.line).toBe(12)
          break
        case 'runtime-hop':
          expect(event.hopId).toBe('h-1')
          expect(event.provider).toBe('glm')
          break
        case 'decision-log':
          expect(event.decisionId).toBe('dec-1')
          expect(event.semanticOutcome).toBe('success')
          break
        case 'activity-event':
          expect(event.eventId).toBe('evt-1')
          expect(event.filePath).toBe('runtime.ts')
          expect(event.line).toBe(9)
          expect(event.surface).toBe('Task')
          break
      }
    }
  })
})
