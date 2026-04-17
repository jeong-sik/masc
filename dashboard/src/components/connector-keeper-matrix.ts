// ConnectorKeeperMatrix — K×M binding grid.
//
// Rows   = keepers (from `fetchGateKeepers` + any referenced-but-unknown
//          keepers surfaced by connector configured_bindings).
// Cols   = the 4 known connectors (discord, imessage, slack, telegram).
// Cell   = binding state for (keeper, connector):
//            bound   — at least one channel bound, shows count
//            unbound — connector is up and operator can bind (clickable)
//            na      — connector is offline (cannot evaluate)
//            unknown — connector directory missing this keeper
//
// Replaces the "per-card bindings list" fan-out in the old layout by
// showing the full matrix in one place. Scales horizontally as more
// connectors ship and vertically as more keepers come online.
//
// Data shape is kept pure in `deriveMatrix` so it can be tested without
// DOM/signals. The component below is a thin renderer.

import { html } from 'htm/preact'
import type { GateConnectorInfo } from '../api/gate'
import type { GateKeeperInfo } from '../api/schemas/gate-keepers'
import {
  CONNECTOR_DISPLAY_NAMES,
  KNOWN_CONNECTOR_IDS,
  channelIcon,
  type KnownConnectorId,
} from './connector-status'
import { openConnectorConfig } from './connector-config-form'

export type MatrixCellState = 'bound' | 'unbound' | 'na' | 'unknown'

export interface MatrixCell {
  connectorId: KnownConnectorId
  keeperName: string
  state: MatrixCellState
  bindingCount: number
}

export interface MatrixRow {
  keeperName: string
  known: boolean
  cells: MatrixCell[]
}

export interface MatrixData {
  columns: KnownConnectorId[]
  rows: MatrixRow[]
  totals: {
    knownKeepers: number
    unknownKeepers: number
    totalBindings: number
    liveConnectors: number
  }
}

function findConnector(connectors: GateConnectorInfo[], id: string): GateConnectorInfo | null {
  return connectors.find(c => c.connector_id === id) ?? null
}

/** Derive the matrix from connectors + keepers. Pure, unit-testable. */
export function deriveMatrix(
  connectors: GateConnectorInfo[],
  keepers: GateKeeperInfo[],
): MatrixData {
  const columns: KnownConnectorId[] = [...KNOWN_CONNECTOR_IDS]
  const knownKeeperNames = new Set(keepers.map(k => k.name))

  const unknownKeeperNames = new Set<string>()
  for (const c of connectors) {
    for (const b of c.configured_bindings ?? []) {
      if (!knownKeeperNames.has(b.keeper_name)) {
        unknownKeeperNames.add(b.keeper_name)
      }
    }
  }

  const allKeeperRows: Array<{ name: string; known: boolean }> = [
    ...keepers.map(k => ({ name: k.name, known: true })),
    ...[...unknownKeeperNames].sort().map(name => ({ name, known: false })),
  ]

  let totalBindings = 0
  const rows: MatrixRow[] = allKeeperRows.map(({ name, known }) => {
    const cells: MatrixCell[] = columns.map(connectorId => {
      const connector = findConnector(connectors, connectorId)
      const connectorUp = connector?.available === true
      const bindings = (connector?.configured_bindings ?? []).filter(
        b => b.keeper_name === name,
      )
      const count = bindings.length
      totalBindings += count
      let state: MatrixCellState
      if (!known) {
        state = count > 0 ? 'unknown' : 'na'
      } else if (count > 0) {
        state = 'bound'
      } else if (connectorUp) {
        state = 'unbound'
      } else {
        state = 'na'
      }
      return { connectorId, keeperName: name, state, bindingCount: count }
    })
    return { keeperName: name, known, cells }
  })

  const liveConnectors = connectors.filter(c => c.available === true).length

  return {
    columns,
    rows,
    totals: {
      knownKeepers: keepers.length,
      unknownKeepers: unknownKeeperNames.size,
      totalBindings,
      liveConnectors,
    },
  }
}

const CELL_TONE: Record<MatrixCellState, { dot: string; text: string; bg: string }> = {
  bound:   { dot: 'bg-emerald-400',     text: 'text-emerald-100',        bg: 'bg-emerald-500/10' },
  unbound: { dot: 'bg-[var(--white-8)]', text: 'text-[var(--text-dim)]', bg: 'bg-transparent'    },
  na:      { dot: 'bg-[var(--white-4)]', text: 'text-[var(--text-dim)]', bg: 'bg-transparent'    },
  unknown: { dot: 'bg-amber-400',       text: 'text-amber-100',          bg: 'bg-amber-500/10'   },
}

const CELL_GLYPH: Record<MatrixCellState, string> = {
  bound:   '●',
  unbound: '+',
  na:      '—',
  unknown: '⚠',
}

function scrollToConnectorRow(connectorId: string) {
  const el = document.getElementById(`connector-row-${connectorId}`)
  if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

function scrollToKeeper(keeperName: string) {
  const el = document.getElementById(`keepers-${keeperName}`)
  if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

function MatrixCellButton({ cell }: { cell: MatrixCell }) {
  const tone = CELL_TONE[cell.state]
  const label = (() => {
    switch (cell.state) {
      case 'bound':   return `${cell.bindingCount} ch`
      case 'unbound': return 'bind'
      case 'na':      return ''
      case 'unknown': return `${cell.bindingCount}?`
    }
  })()
  const title = (() => {
    const conn = CONNECTOR_DISPLAY_NAMES[cell.connectorId] ?? cell.connectorId
    switch (cell.state) {
      case 'bound':   return `${cell.keeperName} · ${conn} · ${cell.bindingCount} channel(s) — 클릭하면 상세로 이동`
      case 'unbound': return `${cell.keeperName} · ${conn} — 클릭하면 바인딩 추가`
      case 'na':      return `${cell.keeperName} · ${conn} — 커넥터 오프라인`
      case 'unknown': return `${cell.keeperName} · ${conn} — 디렉토리 밖 keeper 참조됨`
    }
  })()
  const disabled = cell.state === 'na'
  const onClick = () => {
    if (cell.state === 'unbound') {
      openConnectorConfig(cell.connectorId)
      return
    }
    scrollToConnectorRow(cell.connectorId)
  }
  return html`
    <button
      type="button"
      class=${`flex h-full w-full cursor-pointer items-center justify-center gap-1 rounded px-1 py-1 text-[11px] transition-colors ${tone.bg} ${tone.text} hover:brightness-125 disabled:cursor-not-allowed disabled:opacity-40`}
      onClick=${onClick}
      disabled=${disabled}
      title=${title}
      data-matrix-cell=${`${cell.keeperName}:${cell.connectorId}`}
      data-matrix-state=${cell.state}
    >
      <span class=${`inline-block h-1.5 w-1.5 shrink-0 rounded-full ${tone.dot}`}></span>
      <span>${CELL_GLYPH[cell.state]}</span>
      ${label ? html`<span class="hidden md:inline">${label}</span>` : null}
    </button>
  `
}

export function ConnectorKeeperMatrix({ matrix }: { matrix: MatrixData }) {
  const hasKeepers = matrix.rows.length > 0
  // Grid template: one wide keeper-name column, N fixed-width connector cols.
  // Fixed column widths make the grid *align*, which is the whole point.
  const gridCols = `grid-template-columns: minmax(160px, 1fr) repeat(${matrix.columns.length}, minmax(80px, 1fr));`

  return html`
    <section class="mb-4 rounded-lg border border-[var(--card-border)] bg-[var(--bg-1)] p-3" data-panel="connector-keeper-matrix">
      <header class="mb-2 flex items-baseline justify-between gap-3">
        <div>
          <h4 class="text-[12px] font-semibold uppercase tracking-[0.14em] text-[var(--text-body)]">
            Keeper × Connector Matrix
          </h4>
          <p class="mt-0.5 text-[10px] text-[var(--text-dim)]">
            ${matrix.totals.knownKeepers} keeper${matrix.totals.knownKeepers === 1 ? '' : 's'}
            · ${matrix.totals.liveConnectors}/${matrix.columns.length} connector
            · ${matrix.totals.totalBindings} binding${matrix.totals.totalBindings === 1 ? '' : 's'}
            ${matrix.totals.unknownKeepers > 0
              ? html`· <span class="text-amber-200">${matrix.totals.unknownKeepers} unknown</span>`
              : null}
          </p>
        </div>
        <div class="text-[10px] text-[var(--text-dim)]">
          <span class="mr-2"><span class="mr-1 inline-block h-1.5 w-1.5 rounded-full bg-emerald-400"></span>bound</span>
          <span class="mr-2"><span class="mr-1 inline-block h-1.5 w-1.5 rounded-full bg-[var(--white-8)]"></span>unbound</span>
          <span class="mr-2"><span class="mr-1 inline-block h-1.5 w-1.5 rounded-full bg-[var(--white-4)]"></span>n/a</span>
          <span><span class="mr-1 inline-block h-1.5 w-1.5 rounded-full bg-amber-400"></span>unknown</span>
        </div>
      </header>

      ${!hasKeepers
        ? html`
            <div class="rounded-md border border-dashed border-[var(--card-border)] px-3 py-4 text-center text-[11px] text-[var(--text-dim)]">
              No keepers yet — add one under <code class="rounded bg-[var(--white-4)] px-1">config/keepers/</code> and restart.
            </div>
          `
        : html`
            <div class="overflow-x-auto">
              <div class="grid gap-1 text-[11px]" style=${gridCols} data-matrix-grid>
                <div class="px-1 py-1 text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]">Keeper ↓ / Connector →</div>
                ${matrix.columns.map(colId => html`
                  <button
                    type="button"
                    class="flex cursor-pointer items-center justify-center gap-1 rounded px-1 py-1 text-[10px] uppercase tracking-[0.12em] text-[var(--text-dim)] hover:text-[var(--text-body)]"
                    onClick=${() => scrollToConnectorRow(colId)}
                    title=${`${CONNECTOR_DISPLAY_NAMES[colId] ?? colId} — 행으로 이동`}
                  >
                    <span aria-hidden="true">${channelIcon(colId)}</span>
                    <span>${CONNECTOR_DISPLAY_NAMES[colId] ?? colId}</span>
                  </button>
                `)}

                ${matrix.rows.map(row => html`
                  <${MatrixRowRender} row=${row} />
                `)}
              </div>
            </div>
          `}
    </section>
  `
}

function MatrixRowRender({ row }: { row: MatrixRow }) {
  return html`
    <button
      type="button"
      class=${`flex cursor-pointer items-center gap-2 truncate rounded px-2 py-1 text-left text-[12px] hover:bg-[var(--white-4)] ${row.known ? 'text-[var(--text-body)]' : 'text-amber-100'}`}
      onClick=${() => scrollToKeeper(row.keeperName)}
      title=${row.known ? row.keeperName : `${row.keeperName} — directory 밖 keeper`}
    >
      ${row.known ? null : html`<span class="text-amber-300" aria-hidden="true">⚠</span>`}
      <span class="truncate">${row.keeperName}</span>
    </button>
    ${row.cells.map(cell => html`<${MatrixCellButton} cell=${cell} />`)}
  `
}
