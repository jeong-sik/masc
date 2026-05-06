import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  bridgeCascadeEventsToTrace,
  type CascadeHopProducerInput,
} from './cascade-hop-trace-bridge'
import {
  clearTraces,
  keeperTraceState,
} from './keeper-trace-store'

function evt(
  cascade_name: string,
  cycle: number,
  ts: number,
  strategy = 'round_robin',
): CascadeHopProducerInput {
  return { cascade_name, cycle, ts, strategy }
}

beforeEach(() => {
  clearTraces()
})

afterEach(() => {
  clearTraces()
})

describe('bridgeCascadeEventsToTrace — RFC-0028 PR-δ cascade-hop producer', () => {
  it('emits a trace event for every cascade event on the first call', () => {
    const out = bridgeCascadeEventsToTrace(
      [
        evt('default', 1, 1_715_000_000),
        evt('default', 2, 1_715_000_001),
      ],
      new Set(),
    )

    expect(out.size).toBe(2)
    const events = keeperTraceState.value.events
    expect(events.length).toBe(2)
    expect(events.every(e => e.source === 'cascade-hop')).toBe(true)
  })

  it('does not re-emit cascade events that share the same dedup key', () => {
    const known = new Set(['cascade:default:1:1715000000'])
    bridgeCascadeEventsToTrace(
      [
        evt('default', 1, 1_715_000_000),
        evt('default', 2, 1_715_000_001),
      ],
      known,
    )

    const ids = keeperTraceState.value.events.map(e => e.id)
    expect(ids).toEqual(['cascade:default:2:1715000001'])
  })

  it('returns an updated set including all newly emitted dedup keys', () => {
    const out = bridgeCascadeEventsToTrace(
      [evt('default', 1, 1_715_000_000)],
      new Set(['cascade:other:0:0']),
    )
    expect([...out].sort()).toEqual([
      'cascade:default:1:1715000000',
      'cascade:other:0:0',
    ])
  })

  it('returns the input set unchanged when events is empty', () => {
    const before = new Set(['cascade:default:0:0'])
    const after = bridgeCascadeEventsToTrace([], before)
    expect(after).toBe(before)
    expect(keeperTraceState.value.events.length).toBe(0)
  })

  it('skips events with non-finite ts (NaN-guard)', () => {
    bridgeCascadeEventsToTrace(
      [
        evt('default', 1, Number.NaN),
        evt('default', 2, 1_715_000_000),
      ],
      new Set(),
    )
    const ids = keeperTraceState.value.events.map(e => e.id)
    expect(ids).toEqual(['cascade:default:2:1715000000'])
  })

  it('accepts both unix-seconds and unix-milliseconds for ts', () => {
    bridgeCascadeEventsToTrace(
      [
        evt('a', 1, 1_715_000_000),       // seconds
        evt('b', 1, 1_715_000_000_000),   // milliseconds
      ],
      new Set(),
    )
    const events = keeperTraceState.value.events
    expect(events.length).toBe(2)
    const aMs = events.find(e => e.keeperName === 'a')?.tsMs
    const bMs = events.find(e => e.keeperName === 'b')?.tsMs
    expect(aMs).toBe(1_715_000_000_000)
    expect(bMs).toBe(1_715_000_000_000)
  })

  it('maps fields correctly: id, tsMs, keeperName, source, hopId, provider', () => {
    bridgeCascadeEventsToTrace(
      [evt('mainline', 7, 1_715_000_000, 'weighted_score')],
      new Set(),
    )
    const event = keeperTraceState.value.events[0]!
    expect(event.id).toBe('cascade:mainline:7:1715000000')
    expect(event.tsMs).toBe(1_715_000_000_000)
    expect(event.keeperName).toBe('mainline')
    expect(event.source).toBe('cascade-hop')
    if (event.source === 'cascade-hop') {
      expect(event.hopId).toBe('mainline-7')
      expect(event.provider).toBe('weighted_score')
    }
  })

  it('is idempotent across repeated calls with the returned set', () => {
    const inputs = [
      evt('default', 1, 1_715_000_000),
      evt('default', 2, 1_715_000_001),
    ]
    let known: ReadonlySet<string> = new Set()
    known = bridgeCascadeEventsToTrace(inputs, known)
    known = bridgeCascadeEventsToTrace(inputs, known)
    known = bridgeCascadeEventsToTrace(inputs, known)

    expect(keeperTraceState.value.events.length).toBe(2)
  })
})
