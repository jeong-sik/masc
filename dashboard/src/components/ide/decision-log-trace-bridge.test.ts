import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  bridgeDecisionsToTrace,
  type DecisionLogProducerInput,
} from './decision-log-trace-bridge'
import {
  clearTraces,
  keeperTraceState,
} from './keeper-trace-store'

function dec(
  keeper_name: string,
  ts_unix: number | null,
  event_type = 'turn',
  outcome: string | null = 'ok',
): DecisionLogProducerInput {
  return { keeper_name, ts_unix, event_type, outcome }
}

beforeEach(() => {
  clearTraces()
})

afterEach(() => {
  clearTraces()
})

describe('bridgeDecisionsToTrace — RFC-0028 PR-δ decision-log producer', () => {
  it('emits a trace event for every decision on the first call', () => {
    const out = bridgeDecisionsToTrace(
      [
        dec('scholar', 1_715_000_000),
        dec('moth', 1_715_000_001),
      ],
      new Set(),
    )

    expect(out.size).toBe(2)
    const events = keeperTraceState.value.events
    expect(events.length).toBe(2)
    expect(events.every(e => e.source === 'decision-log')).toBe(true)
  })

  it('does not re-emit decisions that share the same dedup key', () => {
    const known = new Set(['decision:scholar:1715000000:turn'])
    bridgeDecisionsToTrace(
      [
        dec('scholar', 1_715_000_000),
        dec('moth', 1_715_000_001),
      ],
      known,
    )

    const ids = keeperTraceState.value.events.map(e => e.id)
    expect(ids).toEqual(['decision:moth:1715000001:turn'])
  })

  it('returns an updated set including all newly emitted dedup keys', () => {
    const out = bridgeDecisionsToTrace(
      [dec('scholar', 1_715_000_000)],
      new Set(['decision:other:0:turn']),
    )
    expect([...out].sort()).toEqual([
      'decision:other:0:turn',
      'decision:scholar:1715000000:turn',
    ])
  })

  it('returns the input set unchanged when decisions is empty', () => {
    const before = new Set(['decision:scholar:0:turn'])
    const after = bridgeDecisionsToTrace([], before)
    expect(after).toBe(before)
    expect(keeperTraceState.value.events.length).toBe(0)
  })

  it('skips decisions with null ts_unix', () => {
    bridgeDecisionsToTrace(
      [
        dec('scholar', null),
        dec('moth', 1_715_000_000),
      ],
      new Set(),
    )
    const ids = keeperTraceState.value.events.map(e => e.id)
    expect(ids).toEqual(['decision:moth:1715000000:turn'])
  })

  it('skips decisions with non-finite ts_unix (NaN)', () => {
    bridgeDecisionsToTrace(
      [
        dec('scholar', Number.NaN),
        dec('moth', 1_715_000_000),
      ],
      new Set(),
    )
    const ids = keeperTraceState.value.events.map(e => e.id)
    expect(ids).toEqual(['decision:moth:1715000000:turn'])
  })

  it('skips decisions with an empty keeper_name (would corrupt routing bucket)', () => {
    bridgeDecisionsToTrace(
      [
        dec('', 1_715_000_000),
        dec('moth', 1_715_000_001),
      ],
      new Set(),
    )
    const events = keeperTraceState.value.events
    expect(events.length).toBe(1)
    expect(events[0]!.keeperName).toBe('moth')
  })

  it('maps fields correctly: id, tsMs, keeperName, source, decisionId, semanticOutcome', () => {
    bridgeDecisionsToTrace(
      [dec('scholar', 1_715_000_000, 'tool_use', 'error_retryable')],
      new Set(),
    )
    const event = keeperTraceState.value.events[0]!
    expect(event.id).toBe('decision:scholar:1715000000:tool_use')
    expect(event.tsMs).toBe(1_715_000_000_000)
    expect(event.keeperName).toBe('scholar')
    expect(event.source).toBe('decision-log')
    if (event.source === 'decision-log') {
      expect(event.decisionId).toBe('decision:scholar:1715000000:tool_use')
      expect(event.semanticOutcome).toBe('error_retryable')
    }
  })

  it('preserves a null semanticOutcome (in-flight decisions)', () => {
    bridgeDecisionsToTrace(
      [dec('scholar', 1_715_000_000, 'turn', null)],
      new Set(),
    )
    const event = keeperTraceState.value.events[0]!
    if (event.source === 'decision-log') {
      expect(event.semanticOutcome).toBeNull()
    }
  })

  it('is idempotent across repeated calls with the returned set', () => {
    const inputs = [
      dec('scholar', 1_715_000_000),
      dec('moth', 1_715_000_001),
    ]
    let known: ReadonlySet<string> = new Set()
    known = bridgeDecisionsToTrace(inputs, known)
    known = bridgeDecisionsToTrace(inputs, known)
    known = bridgeDecisionsToTrace(inputs, known)

    expect(keeperTraceState.value.events.length).toBe(2)
  })
})
