import { describe, expect, it } from 'vitest'
import { KNOWN_CONNECTOR_IDS, isKnownConnectorId } from './connector-ids'

describe('isKnownConnectorId', () => {
  it('accepts every known connector id', () => {
    for (const id of KNOWN_CONNECTOR_IDS) {
      expect(isKnownConnectorId(id)).toBe(true)
    }
  })

  it('rejects an unknown id, an empty string and undefined', () => {
    expect(isKnownConnectorId('unknown')).toBe(false)
    expect(isKnownConnectorId('')).toBe(false)
    expect(isKnownConnectorId(undefined)).toBe(false)
  })
})
