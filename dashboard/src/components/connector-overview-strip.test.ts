// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { ConnectorOverviewStrip, _testResetBulkInflight, countConnectedSidecars } from './connector-overview-strip'
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

  it('Start All button counts only sidecars currently down', () => {
    _testResetBulkInflight()
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[
          mkConnector({ connector_id: 'discord', available: true }),
          mkConnector({ connector_id: 'slack', available: true }),
        ]}
        keeperCount=${0}
      />`,
      container,
    )
    const startBtn = container.querySelector('[data-bulk-action="start"]') as HTMLButtonElement
    const stopBtn = container.querySelector('[data-bulk-action="stop"]') as HTMLButtonElement
    // 2 of 4 are up → 2 down → Start All shows (2). 2 up → Stop All (2).
    expect(startBtn.textContent).toContain('(2)')
    expect(stopBtn.textContent).toContain('(2)')
  })

  it('Start All disabled when all sidecars are already up', () => {
    _testResetBulkInflight()
    const allUp = ['discord', 'imessage', 'slack', 'telegram'].map(id =>
      mkConnector({ connector_id: id, available: true }),
    )
    render(
      html`<${ConnectorOverviewStrip} connectors=${allUp} keeperCount=${0} />`,
      container,
    )
    const startBtn = container.querySelector('[data-bulk-action="start"]') as HTMLButtonElement
    expect(startBtn.disabled).toBe(true)
    expect(startBtn.title).toContain('이미 실행')
  })

  it('Stop All disabled when nothing is up', () => {
    _testResetBulkInflight()
    render(
      html`<${ConnectorOverviewStrip} connectors=${[]} keeperCount=${0} />`,
      container,
    )
    const stopBtn = container.querySelector('[data-bulk-action="stop"]') as HTMLButtonElement
    expect(stopBtn.disabled).toBe(true)
    expect(stopBtn.title).toContain('실행 중인 sidecar 없음')
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

  it('strip root has sticky positioning so it stays visible while scrolling', () => {
    render(html`<${ConnectorOverviewStrip} connectors=${[]} keeperCount=${0} />`, container)
    const root = container.querySelector('[data-overview-strip-root]') as HTMLElement
    expect(root).toBeTruthy()
    expect(root.className).toContain('sticky')
    expect(root.className).toContain('top-0')
  })

  it('celebration banner hidden when fewer than 4 sidecars are up', () => {
    _testResetBulkInflight()
    const threeUp = ['discord', 'imessage', 'slack'].map(id => mkConnector({ connector_id: id, available: true }))
    render(html`<${ConnectorOverviewStrip} connectors=${threeUp} keeperCount=${0} />`, container)
    expect(container.querySelector('[data-celebration]')).toBeNull()
  })

  it('celebration banner shows when all 4 sidecars are up', () => {
    _testResetBulkInflight()
    const allUp = ['discord', 'imessage', 'slack', 'telegram'].map(id => mkConnector({ connector_id: id, available: true }))
    render(html`<${ConnectorOverviewStrip} connectors=${allUp} keeperCount=${0} />`, container)
    const banner = container.querySelector('[data-celebration="all-connected"]')
    expect(banner).toBeTruthy()
    expect(banner?.textContent).toContain('4/4')
  })
})

describe('countConnectedSidecars', () => {
  it('returns 0 for empty list', () => {
    expect(countConnectedSidecars([])).toBe(0)
  })

  it('counts only available=true known sidecars', () => {
    const list = [
      mkConnector({ connector_id: 'discord', available: true }),
      mkConnector({ connector_id: 'slack', available: false }),
      mkConnector({ connector_id: 'unknown-bridge', available: true }),
    ]
    expect(countConnectedSidecars(list)).toBe(1)
  })
})
