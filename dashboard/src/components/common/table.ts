// Table — ARIA grid/table with sortable headers and selectable rows
//
// Keyboard: Arrow keys navigate cells in grid mode. Enter/Space toggles row selection.

import { html } from 'htm/preact'
import type { ComponentChild } from 'preact'
import { useCallback, useState } from 'preact/hooks'

export interface TableColumn<T> {
  key: string
  header: string
  width?: string
  sortable?: boolean
  render?: (row: T) => ComponentChild
}

interface TableProps<T> {
  columns: TableColumn<T>[]
  rows: T[]
  getRowId: (row: T) => string
  selectedIds?: string[]
  onSelect?: (ids: string[]) => void
  sortKey?: string
  sortDir?: 'asc' | 'desc'
  onSort?: (key: string, dir: 'asc' | 'desc') => void
  testId?: string
  'aria-label'?: string
}

const TABLE_CLS =
  'w-full text-sm border-collapse'

const TH_CLS =
  'px-3 py-2 text-left font-medium text-[var(--color-fg-secondary)] ' +
  'border-b border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'

const TD_CLS =
  'px-3 py-2 text-[var(--color-fg-primary)] border-b border-[var(--color-border-default)]'

const ROW_CLS_BASE = 'transition-colors cursor-pointer '

function rowCls(selected: boolean): string {
  return selected
    ? ROW_CLS_BASE + 'bg-[var(--color-accent-fg)]/10'
    : ROW_CLS_BASE + 'hover:bg-[var(--color-bg-hover)]'
}

export function Table<T>({
  columns,
  rows,
  getRowId,
  selectedIds = [],
  onSelect,
  sortKey,
  sortDir = 'asc',
  onSort,
  testId,
  'aria-label': ariaLabel,
}: TableProps<T>) {
  const [focusedRow, setFocusedRow] = useState(0)

  const isSelected = useCallback(
    (id: string) => selectedIds.includes(id),
    [selectedIds],
  )

  const toggleSelect = useCallback(
    (id: string) => {
      if (!onSelect) return
      const next = isSelected(id)
        ? selectedIds.filter((x) => x !== id)
        : [...selectedIds, id]
      onSelect(next)
    },
    [onSelect, selectedIds, isSelected],
  )

  const handleKeyDown = (e: KeyboardEvent) => {
    if (!onSelect) return
    let nextIdx = focusedRow
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      nextIdx = Math.min(rows.length - 1, focusedRow + 1)
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      nextIdx = Math.max(0, focusedRow - 1)
    } else if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      const row = rows[focusedRow]
      if (row) toggleSelect(getRowId(row))
      return
    }
    if (nextIdx !== focusedRow) {
      setFocusedRow(nextIdx)
    }
  }

  const sortIndicator = (col: TableColumn<T>) => {
    if (!col.sortable) return null
    if (sortKey !== col.key) return html`<span class="ml-1 opacity-30">↕</span>`
    return html`<span class="ml-1">${sortDir === 'asc' ? '↑' : '↓'}</span>`
  }

  return html`
    <table
      role="grid"
      aria-label=${ariaLabel}
      data-testid=${testId}
      class=${TABLE_CLS}
      tabindex=${0}
      onKeyDown=${handleKeyDown}
    >
      <thead>
        <tr>
          ${columns.map(
            (col) => html`
              <th
                key=${col.key}
                scope="col"
                role="columnheader"
                aria-sort=${sortKey === col.key
                  ? sortDir === 'asc'
                    ? 'ascending'
                    : 'descending'
                  : 'none'}
                class=${TH_CLS + (col.width ? ` ${col.width}` : '')}
                onClick=${() => {
                  if (col.sortable && onSort) {
                    const nextDir =
                      sortKey === col.key && sortDir === 'asc' ? 'desc' : 'asc'
                    onSort(col.key, nextDir)
                  }
                }}
              >
                <span class=${col.sortable ? 'cursor-pointer select-none' : ''}>
                  ${col.header}${sortIndicator(col)}
                </span>
              </th>
            `,
          )}
        </tr>
      </thead>
      <tbody>
        ${rows.map((row) => {
          const id = getRowId(row)
          const selected = isSelected(id)
          return html`
            <tr
              key=${id}
              role="row"
              aria-selected=${selected}
              class=${rowCls(selected)}
              onClick=${() => toggleSelect(id)}
            >
              ${columns.map(
                (col) => html`
                  <td key=${col.key} role="gridcell" class=${TD_CLS}>
                    ${col.render ? col.render(row) : (row as Record<string, unknown>)[col.key]}
                  </td>
                `,
              )}
            </tr>
          `
        })}
      </tbody>
    </table>
  `
}
