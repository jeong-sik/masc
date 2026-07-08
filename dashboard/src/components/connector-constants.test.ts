import { describe, expect, it } from 'vitest'
import {
  CONNECTOR_DISPLAY_NAMES,
  IN_PROCESS_CONNECTOR_ENV,
  IN_PROCESS_CONNECTOR_IDS,
  KNOWN_CONNECTOR_IDS,
  channelIcon,
  connectorAccentStyle,
  isInProcessConnector,
  sidecarCommands,
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

  it('in-process connectors are a subset of known connectors with an env var', () => {
    for (const id of IN_PROCESS_CONNECTOR_IDS) {
      expect((KNOWN_CONNECTOR_IDS as readonly string[]).includes(id)).toBe(true)
      expect(IN_PROCESS_CONNECTOR_ENV[id]).toBeTruthy()
      expect(isInProcessConnector(id)).toBe(true)
    }
  })
})

describe('isInProcessConnector', () => {
  it('discord and slack are in-process, external sidecars are not', () => {
    expect(isInProcessConnector('discord')).toBe(true)
    expect(isInProcessConnector('slack')).toBe(true)
    expect(isInProcessConnector('telegram')).toBe(false)
    expect(isInProcessConnector('imessage')).toBe(false)
    expect(isInProcessConnector('unknown')).toBe(false)
  })
})

describe('sidecarCommands', () => {
  it('uses the known sidecar dir for external connectors', () => {
    expect(sidecarCommands('telegram').start).toBe('cd sidecars/telegram-bot && ./run.sh')
    expect(sidecarCommands('telegram').stop).toBe('cd sidecars/telegram-bot && ./run.sh stop')
  })
  it('falls back to a derived dir for unknown connectors', () => {
    expect(sidecarCommands('whatsapp').start).toBe('cd sidecars/whatsapp-bot && ./run.sh')
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
