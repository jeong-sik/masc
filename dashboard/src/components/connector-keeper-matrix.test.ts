// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ConnectorKeeperMatrix,
  deriveMatrix,
  summarizeMatrixRow,
  summarizeMatrixColumn,
  type MatrixData,
  type MatrixRow,
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

  it('renders a Coverage header in the trailing column', () => {
    const matrix = deriveMatrix([mkConnector('discord', { available: true })], [mkKeeper('alpha')])
    render(html`<${ConnectorKeeperMatrix} matrix=${matrix} />`, container)
    expect(container.querySelector('[data-matrix-coverage-header]')).toBeTruthy()
  })

  it('renders a per-row coverage chip per keeper (Airflow/GitHub matrix pattern)', () => {
    const connectors = [
      mkConnector('discord', { available: true, configured_bindings: [{ channel_id: 'c1', keeper_name: 'alpha' }] as never }),
      mkConnector('slack', { available: true }),
    ]
    const keepers = [mkKeeper('alpha'), mkKeeper('beta')]
    const matrix = deriveMatrix(connectors, keepers)
    render(html`<${ConnectorKeeperMatrix} matrix=${matrix} />`, container)
    const chips = container.querySelectorAll('[data-matrix-row-coverage]')
    // One chip per keeper row.
    expect(chips.length).toBe(2)
    const alphaChip = container.querySelector('[data-matrix-row-coverage="alpha"]')!
    // alpha: 1 bound (discord) + 1 unbound (slack) + 2 na (imessage, telegram).
    // Live = bound + unbound + unknown = 2.
    expect(alphaChip.getAttribute('data-matrix-row-bound')).toBe('1')
    expect(alphaChip.getAttribute('data-matrix-row-total-live')).toBe('2')
    expect(alphaChip.textContent).toContain('1/2')
  })

  it('renders a per-column totals footer row (GitHub Actions matrix pattern)', () => {
    // Two keepers × 4 known connectors. alpha bound to discord + slack,
    // beta bound to discord only → discord column has 2 bound, slack
    // column has 1 bound, imessage + telegram have 0 bound.
    const connectors = [
      mkConnector('discord', { available: true, configured_bindings: [
        { channel_id: 'c1', keeper_name: 'alpha' },
        { channel_id: 'c2', keeper_name: 'beta' },
      ] as never }),
      mkConnector('slack', { available: true, configured_bindings: [
        { channel_id: 'c3', keeper_name: 'alpha' },
      ] as never }),
    ]
    const keepers = [mkKeeper('alpha'), mkKeeper('beta')]
    const matrix = deriveMatrix(connectors, keepers)
    render(html`<${ConnectorKeeperMatrix} matrix=${matrix} />`, container)
    // Footer label ("Totals →") is visible.
    expect(container.querySelector('[data-matrix-column-totals-label]')).toBeTruthy()
    // Divider is present (semantic break between rows + totals).
    expect(container.querySelector('[data-matrix-column-totals-divider]')).toBeTruthy()
    // Per-column totals cells — one per connector column.
    const cells = container.querySelectorAll('[data-matrix-column-total-bound]')
    expect(cells.length).toBe(4)
    // Discord (col 0) = 2 bound.
    expect(cells[0]!.getAttribute('data-matrix-column-total-bound')).toBe('2')
    // Slack (col 2) = 1 bound.
    expect(cells[2]!.getAttribute('data-matrix-column-total-bound')).toBe('1')
    // Grand total chip = 3 bound.
    const grand = container.querySelector('[data-matrix-grand-total]')
    expect(grand?.getAttribute('data-matrix-grand-total-bound')).toBe('3')
  })

  it('column totals footer highlights amber when a column has unknowns (directory-mismatch guard)', () => {
    const connectors = [
      mkConnector('discord', { available: true, configured_bindings: [
        { channel_id: 'c1', keeper_name: 'alpha' },
        // gamma is NOT in the keeper directory → unknown cell in discord col
        { channel_id: 'c2', keeper_name: 'gamma' },
      ] as never }),
    ]
    const keepers = [mkKeeper('alpha')]
    const matrix = deriveMatrix(connectors, keepers)
    render(html`<${ConnectorKeeperMatrix} matrix=${matrix} />`, container)
    const cells = container.querySelectorAll('[data-matrix-column-total-bound]')
    const discordCell = cells[0] as HTMLElement
    expect(discordCell.getAttribute('data-matrix-column-total-unknown')).toBe('1')
    expect(discordCell.className).toContain('text-[var(--color-status-warn)]')
  })

  it('column totals footer dashes empty columns (no bound, no unbound, no unknown)', () => {
    // imessage + telegram have 0 bindings and are offline → na cells only.
    // The totals cell for those columns shows "—" not "0".
    const matrix = deriveMatrix([mkConnector('discord', { available: true })], [mkKeeper('alpha')])
    render(html`<${ConnectorKeeperMatrix} matrix=${matrix} />`, container)
    const cells = container.querySelectorAll('[data-matrix-column-total-bound]')
    // imessage is col 1 — offline, no bindings → all na → dashed.
    const imessageCell = cells[1] as HTMLElement
    expect(imessageCell.textContent).toContain('—')
  })
})

describe('summarizeMatrixRow (pure)', () => {
  const mkRow = (states: Array<'bound' | 'unbound' | 'na' | 'unknown'>): MatrixRow => ({
    keeperName: 'test',
    known: true,
    cells: states.map((state, i) => ({
      connectorId: (['discord', 'imessage', 'slack', 'telegram'] as const)[i]!,
      keeperName: 'test',
      state,
      bindingCount: state === 'bound' ? 1 : 0,
    })),
  })

  it('counts each state in the row', () => {
    const row = mkRow(['bound', 'unbound', 'na', 'unknown'])
    expect(summarizeMatrixRow(row)).toEqual({ bound: 1, unbound: 1, na: 1, unknown: 1 })
  })

  it('zero-fills states that do not appear', () => {
    const row = mkRow(['bound', 'bound'])
    expect(summarizeMatrixRow(row)).toEqual({ bound: 2, unbound: 0, na: 0, unknown: 0 })
  })

  it('handles an empty row (no cells → all zero)', () => {
    const row: MatrixRow = { keeperName: 't', known: true, cells: [] }
    expect(summarizeMatrixRow(row)).toEqual({ bound: 0, unbound: 0, na: 0, unknown: 0 })
  })
})

describe('summarizeMatrixColumn (pure)', () => {
  it('counts states across all rows for a column', () => {
    const connectors = [
      mkConnector('discord', {
        available: true,
        configured_bindings: [
          { channel_id: 'c1', keeper_name: 'alpha' },
          { channel_id: 'c2', keeper_name: 'gamma' }, // gamma unknown → directory mismatch
        ] as never,
      }),
      mkConnector('slack', { available: true }),
    ]
    const keepers = [mkKeeper('alpha'), mkKeeper('beta')]
    const matrix = deriveMatrix(connectors, keepers)
    // Discord column (idx 0): alpha=bound, beta=unbound, gamma=unknown
    const discordCounts = summarizeMatrixColumn(matrix, 0)
    expect(discordCounts.bound).toBe(1)
    expect(discordCounts.unbound).toBe(1)
    expect(discordCounts.unknown).toBe(1)
    expect(discordCounts.na).toBe(0)
  })

  it('handles an out-of-range column index (returns all-zero, no crash)', () => {
    const matrix = deriveMatrix([mkConnector('discord', { available: true })], [mkKeeper('alpha')])
    // columnIdx 99 → no cell at that index in any row
    expect(summarizeMatrixColumn(matrix, 99)).toEqual({ bound: 0, unbound: 0, na: 0, unknown: 0 })
  })
})
