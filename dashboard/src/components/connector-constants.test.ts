import { describe, expect, it } from 'vitest'
import {
  CONNECTOR_DISPLAY_NAMES,
  KNOWN_CONNECTOR_IDS,
  channelIcon,
  connectorAccentStyle,
  connectorActivation,
} from './connector-constants'

describe('connector vocabulary constants', () => {
  it('KNOWN_CONNECTOR_IDS is the expected set', () => {
    expect([...KNOWN_CONNECTOR_IDS]).toEqual(['discord', 'imessage', 'slack', 'telegram'])
  })

  it('every known connector has a display name (no drift)', () => {
    for (const id of KNOWN_CONNECTOR_IDS) {
      expect(CONNECTOR_DISPLAY_NAMES[id]).toBeTruthy()
    }
  })

  it('every known connector has an activation requirement', () => {
    for (const id of KNOWN_CONNECTOR_IDS) {
      expect(connectorActivation(id)).toBeTruthy()
    }
  })

  it('an id outside the known set has no activation requirement', () => {
    expect(connectorActivation('unknown')).toBeNull()
    expect(connectorActivation('')).toBeNull()
  })
})

describe('connectorAccentStyle / channelIcon fallbacks', () => {
  it('connectorAccentStyle returns a gradient, with a neutral fallback', () => {
    expect(connectorAccentStyle('discord')).toContain('linear-gradient')
    expect(connectorAccentStyle('unknown')).toContain('120,130,150')
  })
  it('channelIcon returns a per-channel glyph, with a link fallback', () => {
    expect(channelIcon('discord')).toBe('\u{1F3AE}')
    expect(channelIcon('nope')).toBe('\u{1F517}')
  })
})
