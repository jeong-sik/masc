// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ConnectorKeeperMatrix,
  deriveMatrix,
  type MatrixData,
} from './connector-keeper-matrix'
import type { GateConnectorInfo } from '../api/gate'
import type { GateKeeperInfo } from '../api/schemas/gate-keepers'

const mkConnector = (id: string, overrides: Partial<GateConnectorInfo> = {}): GateConnectorInfo => ({
  connector_id: id,
  display_name: id,
  channel: id,
  available: overrides.available ?? false,
  gate_healthy: overrides.gate_healthy ?? null,
  configured_bindings: overrides.configured_bindings ?? [],
  capabilities: overrides.capabilities ?? ['bindings'],
  ...(overrides as object),
}) as GateConnectorInfo

const mkKeeper = (name: string): GateKeeperInfo =>
  ({ name }) as GateKeeperInfo

describe('deriveMatrix', () => {
  it('returns 4 columns in known order', () => {
    const m = deriveMatrix([], [])
    expect(m.columns).toEqual(['discord', 'imessage', 'slack', 'telegram'])
  })

  it('cell is na when keeper exists but connector is offline', () => {
    const connectors = [mkConnector('discord', { available: false })]
    const keepers = [mkKeeper('alpha')]
    const m = deriveMatrix(connectors, keepers)
    const alphaRow = m.rows.find(r => r.keeperName === 'alpha')!
    const discordCell = alphaRow.cells.find(c => c.connectorId === 'discord')!
    expect(discordCell.state).toBe('na')
  })

  it('cell is unbound when connector is up but no binding exists', () => {
    const connectors = [mkConnector('discord', { available: true })]
    const keepers = [mkKeeper('alpha')]
    const m = deriveMatrix(connectors, keepers)
    const alphaRow = m.rows.find(r => r.keeperName === 'alpha')!
    const discordCell = alphaRow.cells.find(c => c.connectorId === 'discord')!
    expect(discordCell.state).toBe('unbound')
  })

  it('cell is bound with count when binding exists', () => {
    const connectors = [mkConnector('discord', {
      available: true,
      configured_bindings: [
        { channel_id: 'c1', keeper_name: 'alpha' },
        { channel_id: 'c2', keeper_name: 'alpha' },
      ] as never,
    })]
    const m = deriveMatrix(connectors, [mkKeeper('alpha')])
    const firstRow = m.rows[0]!
    const cell = firstRow.cells.find(c => c.connectorId === 'discord')!
    expect(cell.state).toBe('bound')
    expect(cell.bindingCount).toBe(2)
  })

  it('surfaces unknown keepers referenced by bindings', () => {
    const connectors = [mkConnector('slack', {
      available: true,
      configured_bindings: [{ channel_id: 'c1', keeper_name: 'ghost' }] as never,
    })]
    const m = deriveMatrix(connectors, [mkKeeper('alpha')])
    expect(m.rows.some(r => r.keeperName === 'ghost' && !r.known)).toBe(true)
    const ghostRow = m.rows.find(r => r.keeperName === 'ghost')!
    const slackCell = ghostRow.cells.find(c => c.connectorId === 'slack')!
    expect(slackCell.state).toBe('unknown')
  })

  it('totals reflect live connectors and total bindings', () => {
    const connectors = [
      mkConnector('discord', {
        available: true,
        configured_bindings: [{ channel_id: 'c1', keeper_name: 'alpha' }] as never,
      }),
      mkConnector('slack', { available: false }),
    ]
    const m = deriveMatrix(connectors, [mkKeeper('alpha'), mkKeeper('beta')])
    expect(m.totals.knownKeepers).toBe(2)
    expect(m.totals.liveConnectors).toBe(1)
    expect(m.totals.totalBindings).toBe(1)
    expect(m.totals.unknownKeepers).toBe(0)
  })
})

describe('ConnectorKeeperMatrix', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    document.body.removeChild(container)
  })

  it('renders empty-state copy when no keepers exist', () => {
    const matrix: MatrixData = deriveMatrix([], [])
    render(html`<${ConnectorKeeperMatrix} matrix=${matrix} />`, container)
    expect(container.textContent).toContain('No keepers yet')
  })

  it('renders a cell button for each (keeper × connector) pair', () => {
    const connectors = [
      mkConnector('discord', { available: true, configured_bindings: [{ channel_id: 'c1', keeper_name: 'alpha' }] as never }),
    ]
    const keepers = [mkKeeper('alpha'), mkKeeper('beta')]
    const matrix = deriveMatrix(connectors, keepers)
    render(html`<${ConnectorKeeperMatrix} matrix=${matrix} />`, container)
    const cells = container.querySelectorAll('[data-matrix-cell]')
    // 2 keepers × 4 connectors = 8 cells
    expect(cells.length).toBe(8)
    // alpha × discord is bound
    const bound = container.querySelector('[data-matrix-cell="alpha:discord"]')!
    expect(bound.getAttribute('data-matrix-state')).toBe('bound')
  })
})
