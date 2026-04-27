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
import { KeeperBadge } from './keeper-badge'
import { Tk } from './tk'

type MatrixCellState = 'bound' | 'unbound' | 'na' | 'unknown'

interface MatrixCell {
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

/** Per-row or per-column state breakdown. Airflow / GitHub Actions
    matrices render these as trailing chips so the operator can scan
    "this keeper's coverage" or "this connector's adoption" without
    counting cells. */
interface MatrixStateCounts {
  bound: number
  unbound: number
  na: number
  unknown: number
}

/** Pure: count each state in a row. */
export function summarizeMatrixRow(row: MatrixRow): MatrixStateCounts {
  const counts: MatrixStateCounts = { bound: 0, unbound: 0, na: 0, unknown: 0 }
  for (const c of row.cells) counts[c.state]++
  return counts
}

/** Pure: count each state in a column. */
export function summarizeMatrixColumn(
  matrix: MatrixData,
  columnIdx: number,
): MatrixStateCounts {
  const counts: MatrixStateCounts = { bound: 0, unbound: 0, na: 0, unknown: 0 }
  for (const row of matrix.rows) {
    const cell = row.cells[columnIdx]
    if (cell !== undefined) counts[cell.state]++
  }
  return counts
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
  bound:   { dot: 'bg-[var(--ok-10)]',     text: 'text-[var(--color-status-ok)]',        bg: 'bg-[var(--ok-10)]' },
  unbound: { dot: 'bg-[var(--white-8)]', text: 'text-[var(--color-fg-disabled)]', bg: 'bg-transparent'    },
  na:      { dot: 'bg-[var(--white-4)]', text: 'text-[var(--color-fg-disabled)]', bg: 'bg-transparent'    },
  unknown: { dot: 'bg-[var(--warn-10)]',       text: 'text-[var(--color-status-warn)]',          bg: 'bg-[var(--warn-10)]'   },
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
      class=${`flex h-full w-full cursor-pointer items-center justify-center gap-1 rounded px-1 py-1 text-2xs transition-colors ${tone.bg} ${tone.text} hover:brightness-125 disabled:cursor-not-allowed disabled:opacity-40`}
      onClick=${onClick}
      disabled=${disabled}
      title=${title}
      aria-label=${title}
      data-matrix-cell=${`${cell.keeperName}:${cell.connectorId}`}
      data-matrix-state=${cell.state}
    >
      <span class=${`inline-block h-1.5 w-1.5 shrink-0 rounded-full ${tone.dot}`} aria-hidden="true"></span>
      <span>${CELL_GLYPH[cell.state]}</span>
      ${label ? html`<span class="hidden md:inline">${label}</span>` : null}
    </button>
  `
}

export function ConnectorKeeperMatrix({ matrix }: { matrix: MatrixData }) {
  const hasKeepers = matrix.rows.length > 0
  // Grid template: one wide keeper-name column, N fixed-width connector cols,
  // and one trailing narrow column for per-row coverage totals (Airflow /
  // GitHub Actions matrix convention — "N bound, M unbound" chip so the
  // operator can scan per-keeper coverage without counting cells).
  const gridCols = `grid-template-columns: minmax(160px, 1fr) repeat(${matrix.columns.length}, minmax(80px, 1fr)) minmax(90px, auto);`

  return html`
    <section class="mb-4 rounded border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3" data-panel="connector-keeper-matrix" aria-label="Keeper × Connector 매트릭스">
      <header class="mb-2 flex items-baseline justify-between gap-3">
        <div>
          <h4 class="text-xs font-semibold uppercase tracking-4 text-[var(--color-fg-primary)]">
            Keeper × Connector Matrix
          </h4>
          <p class="mt-0.5 text-3xs text-[var(--color-fg-disabled)]">
            ${matrix.totals.knownKeepers} keeper${matrix.totals.knownKeepers === 1 ? '' : 's'}
            · ${matrix.totals.liveConnectors}/${matrix.columns.length} connector
            · ${matrix.totals.totalBindings} binding${matrix.totals.totalBindings === 1 ? '' : 's'}
            ${matrix.totals.unknownKeepers > 0
              ? html`· <span class="text-[var(--color-status-warn)]">${matrix.totals.unknownKeepers} unknown</span>`
              : null}
          </p>
        </div>
        <div class="text-3xs text-[var(--color-fg-disabled)]">
          <span class="mr-2"><span class="mr-1 inline-block h-1.5 w-1.5 rounded-full bg-[var(--ok-10)]" aria-hidden="true"></span>bound</span>
          <span class="mr-2"><span class="mr-1 inline-block h-1.5 w-1.5 rounded-full bg-[var(--white-8)]" aria-hidden="true"></span>unbound</span>
          <span class="mr-2"><span class="mr-1 inline-block h-1.5 w-1.5 rounded-full bg-[var(--white-4)]" aria-hidden="true"></span>n/a</span>
          <span><span class="mr-1 inline-block h-1.5 w-1.5 rounded-full bg-[var(--warn-10)]" aria-hidden="true"></span>unknown</span>
        </div>
      </header>

      ${!hasKeepers
        ? html`
            <div class="rounded border border-dashed border-[var(--color-border-default)] px-3 py-4 text-center text-2xs text-[var(--color-fg-disabled)]">
              No keepers yet — add one under <${Tk}>config/keepers/<//> and restart.
            </div>
          `
        : html`
            <div class="overflow-x-auto">
              <div class="grid gap-1 text-2xs" style=${gridCols} data-matrix-grid>
                <div class="px-1 py-1 text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]">키퍼 ↓ / 커넥터 →</div>
                ${matrix.columns.map(colId => html`
                  <button
                    type="button"
                    class="flex cursor-pointer items-center justify-center gap-1 rounded px-1 py-1 text-3xs uppercase tracking-3 text-[var(--color-fg-disabled)] hover:text-[var(--color-fg-primary)]"
                    onClick=${() => scrollToConnectorRow(colId)}
                    title=${`${CONNECTOR_DISPLAY_NAMES[colId] ?? colId} — 행으로 이동`}
                    aria-label=${`${CONNECTOR_DISPLAY_NAMES[colId] ?? colId} — 행으로 이동`}
                  >
                    <span aria-hidden="true">${channelIcon(colId)}</span>
                    <span>${CONNECTOR_DISPLAY_NAMES[colId] ?? colId}</span>
                  </button>
                `)}
                <div
                  class="px-1 py-1 text-center text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]"
                  title="키퍼별 커버리지 총합 (연결 / 미연결 / 해당 없음)"
                  data-matrix-coverage-header
                >커버리지</div>

                ${matrix.rows.map(row => html`
                  <${MatrixRowRender} row=${row} />
                `)}

                <${MatrixColumnTotalsRow} matrix=${matrix} />
              </div>
            </div>
          `}
    </section>
  `
}

/** Per-column totals footer — GitHub Actions matrix + Airflow DAG-grid
    convention. The row lives INSIDE the same grid as the data rows so
    its cells align pixel-for-pixel with the connector columns above.
    Reads "N keepers" where N = bound (actively using this connector). */
function MatrixColumnTotalsRow({ matrix }: { matrix: MatrixData }) {
  const totalBound = matrix.rows.reduce(
    (acc, row) => acc + row.cells.filter(c => c.state === 'bound').length,
    0,
  )
  return html`
    <div
      class="col-span-full mt-1 border-t border-[var(--color-border-default)]"
      aria-hidden="true"
      data-matrix-column-totals-divider
    ></div>
    <div
      class="flex items-center gap-1 px-2 py-1 text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]"
      data-matrix-column-totals-label
    >Totals →</div>
    ${matrix.columns.map((_, idx) => html`
      <${ColumnTotalsCell} counts=${summarizeMatrixColumn(matrix, idx)} />
    `)}
    <div
      class=${`flex items-center justify-end gap-1 px-1 py-1 text-3xs tabular-nums ${totalBound > 0 ? 'text-[var(--color-status-ok)]' : 'text-[var(--color-fg-disabled)]'}`}
      title=${`전체 합계: 모든 keeper × connector 의 bound cell ${totalBound}개`}
      data-matrix-grand-total
      data-matrix-grand-total-bound=${totalBound}
    >
      <span aria-hidden="true">●</span>
      <span>${totalBound}</span>
    </div>
  `
}

function ColumnTotalsCell({ counts }: { counts: MatrixStateCounts }) {
  const { bound, unbound, unknown } = counts
  // Show bound count primarily (the interesting one), plus amber badge
  // when any unknowns exist. Empty column (0 bound, 0 unbound) → dash.
  const hasAny = bound + unbound + unknown > 0
  const tone =
    unknown > 0 ? 'text-[var(--color-status-warn)]' :
    bound > 0 ? 'text-[var(--color-status-ok)]' :
    'text-[var(--color-fg-disabled)]'
  const label = hasAny ? `${bound}` : '—'
  const title = `${bound} bound · ${unbound} unbound · ${unknown} unknown · ${counts.na} n/a`
  return html`
    <div
      class=${`flex items-center justify-center gap-1 px-1 py-1 text-3xs tabular-nums ${tone}`}
      title=${title}
      data-matrix-column-total-bound=${bound}
      data-matrix-column-total-unknown=${unknown}
    >
      <span aria-hidden="true">●</span>
      <span>${label}</span>
    </div>
  `
}

function MatrixRowRender({ row }: { row: MatrixRow }) {
  const counts = summarizeMatrixRow(row)
  return html`
    <button
      type="button"
      class=${`flex cursor-pointer items-center gap-2 truncate rounded px-2 py-1 text-left text-xs hover:bg-[var(--white-4)] ${row.known ? 'text-[var(--color-fg-primary)]' : 'text-[var(--color-status-warn)]'}`}
      onClick=${() => scrollToKeeper(row.keeperName)}
      title=${row.known ? row.keeperName : `${row.keeperName} — directory 밖 keeper`}
      aria-label=${row.known ? row.keeperName : `${row.keeperName} — directory 밖 keeper`}
    >
      ${row.known ? null : html`<span class="text-[var(--color-status-warn)]" aria-hidden="true">⚠</span>`}
      <${KeeperBadge} id=${row.keeperName} variant="full" size="sm" />
    </button>
    ${row.cells.map(cell => html`<${MatrixCellButton} cell=${cell} />`)}
    <${RowCoverageChip} keeperName=${row.keeperName} counts=${counts} />
  `
}

/** Airflow/GitHub Actions matrix convention: trailing per-row summary
    chip showing the state breakdown so the operator can scan "this
    keeper is bound to 2/4 connectors" without counting cells. */
function RowCoverageChip({
  keeperName,
  counts,
}: { keeperName: string; counts: MatrixStateCounts }) {
  const { bound, unbound, na, unknown } = counts
  const totalLive = bound + unbound + unknown // exclude n/a (connector offline)
  const coverageLabel = `${bound}/${totalLive > 0 ? totalLive : '—'}`
  const title = `${keeperName} — ${bound} bound, ${unbound} unbound, ${na} n/a, ${unknown} unknown`
  // Tone follows the dominant state: if anything is unknown → amber,
  // else if all live cells are bound → emerald, else muted.
  const tone =
    unknown > 0 ? 'text-[var(--color-status-warn)]' :
    (bound > 0 && unbound === 0) ? 'text-[var(--color-status-ok)]' :
    'text-[var(--color-fg-disabled)]'
  return html`
    <div
      class=${`flex items-center justify-end gap-1 px-1 py-1 text-3xs tabular-nums ${tone}`}
      title=${title}
      data-matrix-row-coverage=${keeperName}
      data-matrix-row-bound=${bound}
      data-matrix-row-total-live=${totalLive}
    >
      <span aria-hidden="true">●</span>
      <span>${coverageLabel}</span>
    </div>
  `
}
