/**
 * Virtualized `@tanstack/preact-table` v9 data grid primitive.
 *
 * - Right-aligned `tabular-nums slashed-zero` on numeric columns (`.is-num`).
 * - Honest `Observed<T>` formatting (`"없음"` for absent, `"미보고"` for unreported, `"0"` for zero).
 * - Automatic `@container dtable (max-width: 640px)` mobile card collapse via `data-label`.
 * - Virtualized scrolling via `@tanstack/virtual-core` when row count exceeds `virtualizeThreshold`.
 */

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useMemo, useRef, useState } from 'preact/hooks'
import {
  createColumnHelper,
  createSortedRowModel,
  flexRender,
  rowSortingFeature,
  sortFns,
  tableFeatures,
  useTable,
  type SortingState,
} from '@tanstack/preact-table'
import { formatObserved, type Observed } from '../../core/resource-cache'
import { useVirtualList } from './virtual-list'

export { formatObserved, type Observed }

const TABLE_FEATURES = tableFeatures({
  rowSortingFeature,
  sortedRowModel: createSortedRowModel(),
  sortFns,
})

export interface DataTableColumn<T> {
  readonly id: string
  readonly header: string
  readonly accessor?: (row: T) => unknown
  readonly cell?: (row: T) => ComponentChildren
  readonly observed?: (row: T) => Observed<unknown>
  readonly formatValue?: (value: unknown) => string
  readonly numeric?: boolean
  readonly sortable?: boolean
  readonly sortValue?: (row: T) => string | number
}

export interface DataTableProps<T> {
  readonly data: readonly T[]
  readonly columns: readonly DataTableColumn<T>[]
  readonly getRowId?: (row: T, index: number) => string
  readonly selectedRowId?: string | null
  readonly onRowClick?: (row: T) => void
  readonly estimateRowHeight?: number
  readonly virtualizeThreshold?: number
  readonly maxHeight?: number | string
  readonly emptyLabel?: string
  readonly caption?: string
  readonly className?: string
}

function renderCellContent<T>(col: DataTableColumn<T>, row: T): ComponentChildren {
  if (col.cell) return col.cell(row)
  if (col.observed) {
    const obs = col.observed(row)
    const text = formatObserved(obs, col.formatValue)
    if (obs.kind === 'absent' || obs.kind === 'unreported') {
      return html`<span class="dtable-absent">${text}</span>`
    }
    return text
  }
  const raw = col.accessor ? col.accessor(row) : undefined
  if (raw === undefined || raw === null) {
    return html`<span class="dtable-absent">없음</span>`
  }
  return col.formatValue ? col.formatValue(raw) : String(raw)
}

export function DataTable<T extends object>(props: DataTableProps<T>) {
  const scrollRef = useRef<HTMLDivElement>(null)
  const [sorting, setSorting] = useState<SortingState>([])
  const threshold = props.virtualizeThreshold ?? 80
  const rowHeight = props.estimateRowHeight ?? 38

  const columnMetaById = useMemo(() => {
    const map = new Map<string, DataTableColumn<T>>()
    for (const col of props.columns) map.set(col.id, col)
    return map
  }, [props.columns])

  const tanstackColumns = useMemo(() => {
    const helper = createColumnHelper<typeof TABLE_FEATURES, T>()
    return props.columns.map((col) =>
      helper.accessor(
        (row) => {
          if (col.sortValue) return col.sortValue(row)
          if (col.observed) {
            const obs = col.observed(row)
            return obs.kind === 'value' ? obs.data : null
          }
          return col.accessor ? col.accessor(row) : ''
        },
        {
          id: col.id,
          header: col.header,
          enableSorting: col.sortable ?? false,
          cell: (ctx) => renderCellContent(col, ctx.row.original),
        },
      ),
    )
  }, [props.columns])

  const dataArray = useMemo(() => [...props.data], [props.data])

  const table = useTable<typeof TABLE_FEATURES, T>({
    features: TABLE_FEATURES,
    data: dataArray,
    columns: tanstackColumns,
    state: { sorting },
    onSortingChange: setSorting,
    getRowId: props.getRowId
      ? (row, index) => props.getRowId!(row, index)
      : undefined,
  })

  const rows = table.getRowModel().rows
  const shouldVirtualize = rows.length > threshold

  const { virtualItems, totalSize } = useVirtualList({
    count: shouldVirtualize ? rows.length : 0,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => rowHeight,
    overscan: 8,
    initialHeight: typeof props.maxHeight === 'number' ? props.maxHeight : 480,
  })

  const visibleRows = shouldVirtualize
    ? virtualItems.map((vi) => ({ row: rows[vi.index]!, vi }))
    : rows.map((row) => ({ row, vi: null }))

  const topPadding = shouldVirtualize && virtualItems.length > 0 ? virtualItems[0]!.start : 0
  const bottomPadding = shouldVirtualize && virtualItems.length > 0
    ? Math.max(0, totalSize - virtualItems[virtualItems.length - 1]!.end)
    : 0

  const scrollStyle = props.maxHeight !== undefined
    ? { maxHeight: typeof props.maxHeight === 'number' ? `${props.maxHeight}px` : props.maxHeight }
    : undefined

  return html`
    <div class=${`dtable-wrap ${props.className ?? ''}`.trim()}>
      <div ref=${scrollRef} class="dtable-scroll" style=${scrollStyle}>
        <table class="dtable">
          ${props.caption && html`<caption class="sr-only">${props.caption}</caption>`}
          <thead>
            ${table.getHeaderGroups().map((group) => html`
              <tr key=${group.id}>
                ${group.headers.map((header) => {
                  const meta = columnMetaById.get(header.column.id)
                  const canSort = header.column.getCanSort()
                  const sorted = header.column.getIsSorted()
                  const ariaSort = sorted === 'asc'
                    ? 'ascending'
                    : sorted === 'desc'
                      ? 'descending'
                      : undefined
                  const label = flexRender(header.column.columnDef.header, header.getContext())
                  return html`
                    <th
                      key=${header.id}
                      scope="col"
                      class=${meta?.numeric ? 'is-num' : ''}
                      aria-sort=${ariaSort}
                    >
                      ${canSort
                        ? html`
                            <button
                              type="button"
                              class="dtable-sort-btn"
                              onClick=${header.column.getToggleSortingHandler()}
                            >
                              <span>${label}</span>
                              <span aria-hidden="true">
                                ${sorted === 'asc' ? '▲' : sorted === 'desc' ? '▼' : '↕'}
                              </span>
                            </button>
                          `
                        : label}
                    </th>
                  `
                })}
              </tr>
            `)}
          </thead>
          <tbody>
            ${rows.length === 0
              ? html`
                  <tr>
                    <td colspan=${Math.max(1, props.columns.length)} class="dtable-absent">
                      ${props.emptyLabel ?? '데이터 없음'}
                    </td>
                  </tr>
                `
              : html`
                  ${topPadding > 0 && html`
                    <tr aria-hidden="true">
                      <td colspan=${props.columns.length} style=${{ height: `${topPadding}px`, padding: 0, border: 'none' }} />
                    </tr>
                  `}
                  ${visibleRows.map(({ row }) => {
                    const isSelected = props.selectedRowId != null && row.id === props.selectedRowId
                    return html`
                      <tr
                        key=${row.id}
                        data-selected=${isSelected ? 'true' : undefined}
                        tabIndex=${props.onRowClick ? 0 : undefined}
                        onClick=${props.onRowClick ? () => props.onRowClick!(row.original) : undefined}
                        onKeyDown=${props.onRowClick ? (event: KeyboardEvent) => {
                          if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
                          if (event.key !== 'Enter' && event.key !== ' ') return
                          if (event.target !== event.currentTarget) {
                            const target = event.target
                            if (target instanceof HTMLElement && target.closest('button, a, input, select, textarea, [role="button"]')) {
                              return
                            }
                          }
                          event.preventDefault()
                          props.onRowClick!(row.original)
                        } : undefined}
                      >
                        ${row.getAllCells().map((cell) => {
                          const meta = columnMetaById.get(cell.column.id)
                          return html`
                            <td
                              key=${cell.id}
                              class=${meta?.numeric ? 'is-num' : ''}
                              data-label=${meta?.header ?? cell.column.id}
                            >
                              ${flexRender(cell.column.columnDef.cell, cell.getContext())}
                            </td>
                          `
                        })}
                      </tr>
                    `
                  })}
                  ${bottomPadding > 0 && html`
                    <tr aria-hidden="true">
                      <td colspan=${props.columns.length} style=${{ height: `${bottomPadding}px`, padding: 0, border: 'none' }} />
                    </tr>
                  `}
                `}
          </tbody>
        </table>
      </div>
    </div>
  `
}
