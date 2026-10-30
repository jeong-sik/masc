import { describe, it, expect } from 'vitest'
import { deriveBlockerReason } from './keeper-blocker-reason'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'

const compositeWith = (
  reason: string | null | undefined,
): KeeperCompositeSnapshot | null => {
  if (reason === undefined) return null
  return {
    runtime_attention: { reason },
  } as unknown as KeeperCompositeSnapshot
}

describe('deriveBlockerReason', () => {
  it('prefers composite runtime_attention.reason', () => {
    const r = deriveBlockerReason({
      keeper: {
        runtime_blocker_summary: 'flat blocker text',
        attention_reason: 'flat attention text',
      },
      composite: compositeWith('observer recorded reason'),
    })
    expect(r).toEqual({
      reason: 'observer recorded reason',
      source: 'composite_runtime_attention',
    })
  })

  it('falls through to runtime_blocker_summary when composite is null', () => {
    const r = deriveBlockerReason({
      keeper: {
        runtime_blocker_summary: 'flat blocker text',
        attention_reason: 'flat attention text',
      },
      composite: null,
    })
    expect(r).toEqual({
      reason: 'flat blocker text',
      source: 'flat_runtime_blocker_summary',
    })
  })

  it('falls through to attention_reason when blocker summary is empty', () => {
    const r = deriveBlockerReason({
      keeper: {
        runtime_blocker_summary: null,
        attention_reason: 'flat attention text',
      },
      composite: null,
    })
    expect(r).toEqual({
      reason: 'flat attention text',
      source: 'flat_attention_reason',
    })
  })

  it('returns source=none when all three signals are absent', () => {
    const r = deriveBlockerReason({
      keeper: {
        runtime_blocker_summary: null,
        attention_reason: null,
      },
      composite: null,
    })
    expect(r).toEqual({ reason: null, source: 'none' })
  })

  it('treats empty/whitespace-only strings as missing — keeps falling through', () => {
    // Regression guard: a careless `??` chain treats `""` as present
    // (because it is not null/undefined). The typed function trims
    // and promotes "" to null so the next source can supply a real value.
    const r = deriveBlockerReason({
      keeper: {
        runtime_blocker_summary: '  ',
        attention_reason: 'real reason',
      },
      composite: compositeWith(''),
    })
    expect(r).toEqual({
      reason: 'real reason',
      source: 'flat_attention_reason',
    })
  })
})
