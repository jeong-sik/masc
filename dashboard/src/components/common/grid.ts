// Grid — ARIA grid with row-level keyboard navigation
// Kimi sec06 ARIA pattern: grid. ArrowUp/Down moves between rows;
// Home/End jumps to first/last row; Enter selects.

import { html } from 'htm/preact'
import { useCallback, useRef, useState } from 'preact/hooks'

export interface GridColumn {
  key: string
  header: string
}

export interface GridRow {
  id: string
  [key: string]: string
}

interface GridProps {
  columns: GridColumn[]
  rows: GridRow[]
  selectedRowId?: string
  onSelectRow?: (id: string) => void
  'aria-label'?: string
  class?: string
}

const TABLE_CLS =
  'w-full text-sm border-collapse text-[var(--color-fg-primary)]'

const TH_CLS =
  'px-3 py-2 text-left font-medium text-[var(--color-fg-muted)] ' +
  'border-b border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'

const TR_BASE =
  'outline-none cursor-pointer border-b border-[var(--color-border-default)] '

function trCls(selected: boolean): string {
  return selected
    ? TR_BASE +
        'bg-[var(--color-accent-fg)] text-[var(--color-bg-page)]'
    : TR_BASE +
        'hover:bg-[var(--color-bg-hover)]'
}

const TD_CLS = 'px-3 py-2'

export function Grid({
  columns,
  rows,
  selectedRowId,
  onSelectRow,
  'aria-label': ariaLabel,
  class: cx,
}: GridProps) {
  const [focusedIndex, setFocusedIndex] = useState(() =>
    Math.max(
      0,
      rows.findIndex((r) => r.id === selectedRowId),
    ),
  )
  const rowRefs = useRef<(HTMLTableRowElement | null)[]>([])

  const focusRow = useCallback(
    (idx: number) => {
      if (idx >= 0 && idx < rows.length) {
        setFocusedIndex(idx)
        rowRefs.current[idx]?.focus()
      }
    },
    [rows.length],
  )

  const handleKeyDown = (e: KeyboardEvent) => {
    if (rows.length === 0) return
    let nextIdx = focusedIndex

    if (e.key === 'ArrowDown') {
      e.preventDefault()
      nextIdx = Math.min(rows.length - 1, focusedIndex + 1)
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      nextIdx = Math.max(0, focusedIndex - 1)
    } else if (e.key === 'Home') {
      e.preventDefault()
      nextIdx = 0
    } else if (e.key === 'End') {
      e.preventDefault()
      nextIdx = rows.length - 1
    } else if (e.key === 'Enter') {
      e.preventDefault()
      const row = rows[focusedIndex]
      if (row) onSelectRow?.(row.id)
      return
    }

    if (nextIdx !== focusedIndex) {
      focusRow(nextIdx)
    }
  }

  return html`
    <table
      role="grid"
      aria-label=${ariaLabel}
      tabindex=${0}
      class=${(cx ? cx + ' ' : '') + TABLE_CLS}
      onKeyDown=${handleKeyDown}
    >
      <thead>
        <tr role="row">
          ${columns.map(
            (col) => html`
              <th role="columnheader" scope="col" class=${TH_CLS}>${col.header}</th>
            `,
          )}
        </tr>
      </thead>
      <tbody>
        ${rows.map(
          (row, idx) => html`
            <tr
              key=${row.id}
              role="row"
              aria-selected=${row.id === selectedRowId}
              tabindex=${idx === focusedIndex ? 0 : -1}
              class=${trCls(row.id === selectedRowId)}
              ref=${(el: HTMLTableRowElement | null) => (rowRefs.current[idx] = el)}
              onClick=${() => {
                setFocusedIndex(idx)
                onSelectRow?.(row.id)
              }}
            >
              ${columns.map(
                (col) => html`
                  <td role="gridcell" class=${TD_CLS}>${row[col.key] ?? ''}</td>
                `,
              )}
            </tr>
          `,
        )}
      </tbody>
    </table>
  `
}
