import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  bridgeBdiSnapshotsToTrace,
  type BdiSnapshotProducerInput,
} from './bdi-snapshot-trace-bridge'
import {
  clearTraces,
  keeperTraceState,
} from './keeper-trace-store'

function snap(
  keeper: string,
  generated_at: string | null,
  intention: string | null = 'analyze diff',
): BdiSnapshotProducerInput {
  return { keeper, generated_at, intention }
}

beforeEach(() => {
  clearTraces()
})

afterEach(() => {
  clearTraces()
})

describe('bridgeBdiSnapshotsToTrace — RFC-0028 PR-δ bdi-snapshot producer', () => {
  it('emits a trace event for every snapshot on the first call', () => {
    const out = bridgeBdiSnapshotsToTrace(
      [
        snap('scholar', '2026-05-06T01:00:00Z'),
        snap('moth', '2026-05-06T01:00:01Z'),
      ],
      new Set(),
    )

    expect(out.size).toBe(2)
    const events = keeperTraceState.value.events
    expect(events.length).toBe(2)
    expect(events.every(e => e.source === 'bdi-snapshot')).toBe(true)
  })

  it('does not re-emit snapshots with the same dedup key (polling replay)', () => {
    let known: ReadonlySet<string> = new Set()
    // First poll: snapshot A
    known = bridgeBdiSnapshotsToTrace([snap('scholar', '2026-05-06T01:00:00Z')], known)
    // Second poll: server has not yet published a fresh tick (same generated_at)
    known = bridgeBdiSnapshotsToTrace([snap('scholar', '2026-05-06T01:00:00Z')], known)
    // Third poll: same again
    known = bridgeBdiSnapshotsToTrace([snap('scholar', '2026-05-06T01:00:00Z')], known)

    expect(keeperTraceState.value.events.length).toBe(1)
  })

  it('emits a fresh trace event when generated_at advances', () => {
    let known: ReadonlySet<string> = new Set()
    known = bridgeBdiSnapshotsToTrace([snap('scholar', '2026-05-06T01:00:00Z')], known)
    known = bridgeBdiSnapshotsToTrace([snap('scholar', '2026-05-06T01:00:05Z')], known)
    known = bridgeBdiSnapshotsToTrace([snap('scholar', '2026-05-06T01:00:10Z')], known)

    expect(keeperTraceState.value.events.length).toBe(3)
  })

  it('returns the input set unchanged when snapshots is empty', () => {
    const before = new Set(['bdi:scholar:2026-05-06T01:00:00Z'])
    const after = bridgeBdiSnapshotsToTrace([], before)
    expect(after).toBe(before)
    expect(keeperTraceState.value.events.length).toBe(0)
  })

  it('skips snapshots with null generated_at', () => {
    bridgeBdiSnapshotsToTrace(
      [
        snap('scholar', null),
        snap('moth', '2026-05-06T01:00:00Z'),
      ],
      new Set(),
    )
    const events = keeperTraceState.value.events
    expect(events.length).toBe(1)
    expect(events[0]!.keeperName).toBe('moth')
  })

  it('skips snapshots with malformed generated_at (NaN-guard)', () => {
    bridgeBdiSnapshotsToTrace(
      [
        snap('scholar', 'not-a-date'),
        snap('moth', '2026-05-06T01:00:00Z'),
      ],
      new Set(),
    )
    const events = keeperTraceState.value.events
    expect(events.length).toBe(1)
    expect(events[0]!.keeperName).toBe('moth')
  })

  it('skips snapshots with empty keeper', () => {
    bridgeBdiSnapshotsToTrace(
      [
        snap('', '2026-05-06T01:00:00Z'),
        snap('moth', '2026-05-06T01:00:01Z'),
      ],
      new Set(),
    )
    const events = keeperTraceState.value.events
    expect(events.length).toBe(1)
    expect(events[0]!.keeperName).toBe('moth')
  })

  it('maps fields correctly: id, tsMs, keeperName, source, intention', () => {
    bridgeBdiSnapshotsToTrace(
      [snap('scholar', '2026-05-06T01:00:00Z', 'verify cascade route')],
      new Set(),
    )
    const event = keeperTraceState.value.events[0]!
    expect(event.id).toBe('bdi:scholar:2026-05-06T01:00:00Z')
    expect(event.tsMs).toBe(Date.parse('2026-05-06T01:00:00Z'))
    expect(event.keeperName).toBe('scholar')
    expect(event.source).toBe('bdi-snapshot')
    if (event.source === 'bdi-snapshot') {
      expect(event.intention).toBe('verify cascade route')
    }
  })

  it('preserves a null intention (keeper between intentions)', () => {
    bridgeBdiSnapshotsToTrace(
      [snap('scholar', '2026-05-06T01:00:00Z', null)],
      new Set(),
    )
    const event = keeperTraceState.value.events[0]!
    if (event.source === 'bdi-snapshot') {
      expect(event.intention).toBeNull()
    }
  })

  it('returns an updated set including all newly emitted dedup keys', () => {
    const out = bridgeBdiSnapshotsToTrace(
      [snap('scholar', '2026-05-06T01:00:00Z')],
      new Set(['bdi:other:2026-05-06T00:59:00Z']),
    )
    expect([...out].sort()).toEqual([
      'bdi:other:2026-05-06T00:59:00Z',
      'bdi:scholar:2026-05-06T01:00:00Z',
    ])
  })
})
