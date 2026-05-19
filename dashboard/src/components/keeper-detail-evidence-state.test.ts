import { describe, it, expect } from 'vitest'
import {
  applyFetchFailed,
  applyFetchSucceeded,
  evidenceFreshData,
  loadingEvidence,
  type EvidenceState,
} from './keeper-detail-evidence-state'

type Sample = { value: number }

describe('keeper-detail evidence state', () => {
  it('loadingEvidence is the loading arm', () => {
    expect(loadingEvidence.kind).toBe('loading')
  })

  it('applyFetchSucceeded yields a fresh arm with the data', () => {
    const next = applyFetchSucceeded<Sample>({ value: 7 }, 1_700_000_000_000)
    expect(next.kind).toBe('fresh')
    expect(next.data).toEqual({ value: 7 })
    expect(next.fetchedAt).toBe(1_700_000_000_000)
  })

  it('applyFetchFailed from loading yields error (no prior data)', () => {
    const next = applyFetchFailed<Sample>(loadingEvidence, 'boom', 1_700_000_000_100)
    expect(next.kind).toBe('error')
    if (next.kind !== 'error') throw new Error('unreachable')
    expect(next.error).toBe('boom')
  })

  it('applyFetchFailed from error yields error (no prior data)', () => {
    const prev: EvidenceState<Sample> = { kind: 'error', error: 'first' }
    const next = applyFetchFailed<Sample>(prev, 'second', 1_700_000_000_200)
    expect(next.kind).toBe('error')
    if (next.kind !== 'error') throw new Error('unreachable')
    expect(next.error).toBe('second')
  })

  it('applyFetchFailed from fresh yields stale and preserves data', () => {
    const fresh = applyFetchSucceeded<Sample>({ value: 42 }, 1_700_000_000_000)
    const next = applyFetchFailed<Sample>(fresh, 'network down', 1_700_000_005_000)
    expect(next.kind).toBe('stale')
    if (next.kind !== 'stale') throw new Error('unreachable')
    expect(next.data).toEqual({ value: 42 })
    expect(next.fetchedAt).toBe(1_700_000_000_000)
    expect(next.stalenessMs).toBe(5_000)
    expect(next.error).toBe('network down')
  })

  it('applyFetchFailed from stale keeps the original fetchedAt and updates staleness/error', () => {
    const fresh = applyFetchSucceeded<Sample>({ value: 99 }, 1_700_000_000_000)
    const firstFailure = applyFetchFailed<Sample>(fresh, 'first', 1_700_000_003_000)
    const secondFailure = applyFetchFailed<Sample>(firstFailure, 'second', 1_700_000_009_000)
    expect(secondFailure.kind).toBe('stale')
    if (secondFailure.kind !== 'stale') throw new Error('unreachable')
    expect(secondFailure.data).toEqual({ value: 99 })
    expect(secondFailure.fetchedAt).toBe(1_700_000_000_000)
    expect(secondFailure.stalenessMs).toBe(9_000)
    expect(secondFailure.error).toBe('second')
  })

  it('applyFetchFailed clamps negative deltas to zero (clock skew)', () => {
    const fresh = applyFetchSucceeded<Sample>({ value: 1 }, 1_700_000_010_000)
    const next = applyFetchFailed<Sample>(fresh, 'skew', 1_700_000_000_000)
    expect(next.kind).toBe('stale')
    if (next.kind !== 'stale') throw new Error('unreachable')
    expect(next.stalenessMs).toBe(0)
  })

  it('evidenceFreshData returns data only for the fresh arm', () => {
    expect(evidenceFreshData<Sample>(loadingEvidence)).toBeNull()
    expect(evidenceFreshData<Sample>({ kind: 'error', error: 'x' })).toBeNull()
    const fresh = applyFetchSucceeded<Sample>({ value: 3 }, 1_700_000_000_000)
    expect(evidenceFreshData<Sample>(fresh)).toEqual({ value: 3 })
    const stale = applyFetchFailed<Sample>(fresh, 'gone', 1_700_000_002_000)
    // CRITICAL: stale data must NOT leak through the fresh-only accessor.
    // This is the silent-fallback regression guard.
    expect(evidenceFreshData<Sample>(stale)).toBeNull()
  })
})
