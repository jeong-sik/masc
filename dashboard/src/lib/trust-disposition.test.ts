import { describe, expect, it } from 'vitest'
import serverValues from '../api/fixtures/trust-dispositions.json'
import { TRUST_DISPOSITIONS } from '../types'
import { asTrustDisposition } from './trust-disposition'

describe('TRUST_DISPOSITIONS', () => {
  it('is exactly the values the server sends, in its order', () => {
    // test_keeper_trust_disposition pins this fixture to every OCaml
    // Keeper_trust_disposition.t, so a value added or removed on either side fails.
    expect([...TRUST_DISPOSITIONS]).toEqual(serverValues)
  })
})

describe('asTrustDisposition', () => {
  it('keeps a value the server sends and drops any other', () => {
    expect(asTrustDisposition(' Blocked ')).toBe('Blocked')
    expect(asTrustDisposition('Pause')).toBeNull()
    expect(asTrustDisposition(null)).toBeNull()
  })
})
