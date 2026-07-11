import { describe, expect, it } from 'vitest'
import type { KeeperConversationDelivery } from '../types/core'
import {
  FAILED_DELIVERY,
  IN_FLIGHT_DELIVERY,
  isFailedDelivery,
  isInFlightDelivery,
} from './keeper-delivery'

// Exhaustive expected classification for every delivery variant, declared as a
// Record keyed by the closed union. Adding a new variant to
// KeeperConversationDelivery fails to compile here until it is classified —
// the compile-time drift guard the replaced OR-chains lacked.
const EXPECTED: Record<KeeperConversationDelivery, 'in-flight' | 'failed' | 'other'> = {
  history: 'other',
  queued: 'in-flight',
  sending: 'in-flight',
  streaming: 'in-flight',
  delivered: 'other',
  no_reply: 'other',
  timeout: 'failed',
  cancelled: 'other',
  error: 'failed',
  transport_failure: 'failed',
  interrupted: 'failed',
}

describe('keeper-delivery classifiers', () => {
  const all = Object.keys(EXPECTED) as KeeperConversationDelivery[]

  it('covers all 11 delivery variants', () => {
    expect(all).toHaveLength(11)
  })

  it('classifies every variant into exactly one bucket', () => {
    for (const d of all) {
      const inFlight = isInFlightDelivery(d)
      const failed = isFailedDelivery(d)
      // in-flight and failed are mutually exclusive
      expect(inFlight && failed).toBe(false)
      const bucket = inFlight ? 'in-flight' : failed ? 'failed' : 'other'
      expect(bucket).toBe(EXPECTED[d])
    }
  })

  it('IN_FLIGHT_DELIVERY and FAILED_DELIVERY are disjoint sets', () => {
    const failed = new Set<string>(FAILED_DELIVERY)
    expect(IN_FLIGHT_DELIVERY.filter((d) => failed.has(d))).toEqual([])
  })

  it('preserves the original in-flight membership {queued, sending, streaming}', () => {
    expect([...IN_FLIGHT_DELIVERY].sort()).toEqual(['queued', 'sending', 'streaming'])
  })

  it('classifies durable transport failure separately from generic errors', () => {
    expect([...FAILED_DELIVERY].sort()).toEqual([
      'error',
      'interrupted',
      'timeout',
      'transport_failure',
    ])
  })
})
