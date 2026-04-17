// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ConnectorOverviewStrip,
  ConnectorBulkActions,
  _testResetBulkInflight,
} from './connector-overview-strip'
import type { GateConnectorInfo } from '../api/gate'
import type { GateKeeperInfo } from '../api/schemas/gate-keepers'

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

const noopDetail = () => null

describe('ConnectorOverviewStrip', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    _testResetBulkInflight()
  })
  afterEach(() => {
    document.body.removeChild(container)
  })

  it('renders one row per known sidecar (4 rows)', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[]}
        keepers=${[] as GateKeeperInfo[]}
        renderExpandedDetail=${noopDetail}
      />`,
      container,
    )
    const rows = container.querySelectorAll('[data-connector-row]')
    expect(rows.length).toBe(4)
    const ids = Array.from(rows).map(r => r.getAttribute('data-connector-row'))
    expect(ids).toEqual(['discord', 'imessage', 'slack', 'telegram'])
  })

  it('marks running connector as CONNECTED and offline ones as OFFLINE', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({ connector_id: 'discord', available: true })]}
        keepers=${[] as GateKeeperInfo[]}
        renderExpandedDetail=${noopDetail}
      />`,
      container,
    )
    const discordRow = container.querySelector('[data-connector-row="discord"]')!
    const imessageRow = container.querySelector('[data-connector-row="imessage"]')!
    expect(discordRow.textContent).toContain('connected')
    expect(imessageRow.textContent).toContain('offline')
  })

  it('summary bar reflects up/warn/down counts', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[
          mkConnector({ connector_id: 'discord', available: true, gate_healthy: true, configured_bindings: [{ channel_id: 'c1', keeper_name: 'k1' }] as never }),
          mkConnector({ connector_id: 'slack', available: true, gate_healthy: true, configured_bindings: [] }),
        ]}
        keepers=${[{ name: 'k1' }] as GateKeeperInfo[]}
        renderExpandedDetail=${noopDetail}
      />`,
      container,
    )
    const summary = container.querySelector('[data-panel="connector-summary-bar"]')!
    // discord: all pills ok → up. slack: bindings warn (keeper exists, none bound) → warn.
    // imessage, telegram: sidecar down → down.
    expect(summary.textContent).toContain('1 up')
    expect(summary.textContent).toContain('1 warn')
    expect(summary.textContent).toContain('2 down')
  })

  it('Start All / Stop All counts disabled states correctly', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[
          mkConnector({ connector_id: 'discord', available: true }),
          mkConnector({ connector_id: 'slack', available: true }),
        ]}
        keepers=${[] as GateKeeperInfo[]}
        renderExpandedDetail=${noopDetail}
      />`,
      container,
    )
    const startBtn = container.querySelector('[data-bulk-action="start"]') as HTMLButtonElement
    const stopBtn = container.querySelector('[data-bulk-action="stop"]') as HTMLButtonElement
    expect(startBtn.textContent).toContain('(2)')
    expect(stopBtn.textContent).toContain('(2)')
  })

  it('renders 4 readiness cells inside each row', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[]}
        keepers=${[] as GateKeeperInfo[]}
        renderExpandedDetail=${noopDetail}
      />`,
      container,
    )
    const row = container.querySelector('[data-connector-row="discord"]')!
    const cells = row.querySelectorAll('[data-rail-pill]')
    expect(cells.length).toBe(4)
  })

  it('clicking a row reveals expanded detail slot', async () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[]}
        keepers=${[] as GateKeeperInfo[]}
        renderExpandedDetail=${(c: GateConnectorInfo | null) => html`<div data-test-expanded=${c?.connector_id ?? 'null'}>EXPAND</div>`}
      />`,
      container,
    )
    // No expansion initially.
    expect(container.querySelector('[data-test-expanded]')).toBeNull()
    const row = container.querySelector('[data-connector-row="slack"]')!
    const toggle = row.querySelector<HTMLButtonElement>('button[aria-label*="detail toggle"]')!
    toggle.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    // Let the signal update flush through preact's render queue.
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await new Promise(resolve => setTimeout(resolve, 0))
    }
    expect(container.querySelector('[data-test-expanded]')).not.toBeNull()
    expect(container.querySelector('[data-connector-row-detail="slack"]')).not.toBeNull()
  })

  it('ConnectorBulkActions stays exported for onboarding grid', () => {
    render(
      html`<${ConnectorBulkActions} connectors=${[] as GateConnectorInfo[]} />`,
      container,
    )
    expect(container.querySelector('[data-bulk-action="start"]')).not.toBeNull()
    expect(container.querySelector('[data-bulk-action="stop"]')).not.toBeNull()
  })
})
