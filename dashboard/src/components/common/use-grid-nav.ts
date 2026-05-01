// use-grid-nav.ts — grid keyboard navigation hook
//
// Kimi design system sec06 6.1.1: useGridNav implements arrow key navigation
// for grid roles (grid, treegrid). Supports Ctrl+Home / Ctrl+End.

import { useState, useCallback } from 'preact/hooks'

export interface GridNavOptions {
  rowCount: number
  colCount: number
  wrap?: boolean
}

export interface GridNavResult {
  activeRow: number
  activeCol: number
  handleKeyDown: (e: KeyboardEvent) => void
  getTabIndex: (row: number, col: number) => number
}

export function useGridNav({ rowCount, colCount, wrap = false }: GridNavOptions): GridNavResult {
  const [activeRow, setActiveRow] = useState(0)
  const [activeCol, setActiveCol] = useState(0)

  const move = useCallback(
    (dr: number, dc: number) => {
      setActiveRow((r) => {
        const nextR = r + dr
        if (wrap) {
          return ((nextR % rowCount) + rowCount) % rowCount
        }
        return Math.max(0, Math.min(nextR, rowCount - 1))
      })
      setActiveCol((c) => {
        const nextC = c + dc
        if (wrap) {
          return ((nextC % colCount) + colCount) % colCount
        }
        return Math.max(0, Math.min(nextC, colCount - 1))
      })
    },
    [rowCount, colCount, wrap]
  )

  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === 'ArrowRight') {
        e.preventDefault()
        move(0, 1)
      } else if (e.key === 'ArrowLeft') {
        e.preventDefault()
        move(0, -1)
      } else if (e.key === 'ArrowDown') {
        e.preventDefault()
        move(1, 0)
      } else if (e.key === 'ArrowUp') {
        e.preventDefault()
        move(-1, 0)
      } else if (e.key === 'Home') {
        e.preventDefault()
        if (e.ctrlKey) {
          setActiveRow(0)
          setActiveCol(0)
        } else {
          setActiveCol(0)
        }
      } else if (e.key === 'End') {
        e.preventDefault()
        if (e.ctrlKey) {
          setActiveRow(rowCount - 1)
          setActiveCol(colCount - 1)
        } else {
          setActiveCol(colCount - 1)
        }
      }
    },
    [move, rowCount, colCount]
  )

  const getTabIndex = useCallback(
    (row: number, col: number) => (row === activeRow && col === activeCol ? 0 : -1),
    [activeRow, activeCol]
  )

  return { activeRow, activeCol, handleKeyDown, getTabIndex }
}
