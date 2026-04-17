// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { ConnectorOverviewStrip } from './connector-overview-strip'
import type { GateConnectorInfo } from '../api/gate'

const mkConnector = (overrides: Partial<GateConnectorInfo> = {}): GateConnectorInfo => ({
  connector_id: overrides.connector_id ?? 'discord',
  display_name: overrides.display_name ?? 'Discord',
  channel: overrides.channel ?? 'discord',
  available: overrides.available ?? true,
  gate_healthy: overrides.gate_healthy ?? true,
  configured_bindings: overrides.configured_bindings ?? [],
  capabilities: overrides.capabilities ?? ['bindings'],
  ...(overrides as object),
}) as GateConnectorInfo

describe('ConnectorOverviewStrip', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    document.body.removeChild(container)
  })

  it('always renders one tile per known sidecar (4 tiles)', () => {
    render(
      html`<${ConnectorOverviewStrip} connectors=${[]} keeperCount=${0} />`,
      container,
    )
    const tiles = container.querySelectorAll('[data-overview-tile]')
    expect(tiles.length).toBe(4)
    const ids = Array.from(tiles).map(t => t.getAttribute('data-overview-tile'))
    expect(ids).toEqual(['discord', 'imessage', 'slack', 'telegram'])
  })

  it('marks running connector as 🟢 connected and offline ones as ⊘ offline', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({ connector_id: 'discord', available: true })]}
        keeperCount=${0}
      />`,
      container,
    )
    const discordTile = container.querySelector('[data-overview-tile="discord"]')!
    const imessageTile = container.querySelector('[data-overview-tile="imessage"]')!
    expect(discordTile.textContent).toContain('connected')
    expect(imessageTile.textContent).toContain('offline')
  })

  it('renders 4 readiness pills inside each tile', () => {
    render(
      html`<${ConnectorOverviewStrip} connectors=${[]} keeperCount=${0} />`,
      container,
    )
    const discordTile = container.querySelector('[data-overview-tile="discord"]')!
    const pills = discordTile.querySelectorAll('[data-rail-pill]')
    expect(pills.length).toBe(4)
  })
})
