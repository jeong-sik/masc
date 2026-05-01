// use-tree-nav.ts — tree keyboard navigation hook
//
// Kimi design system sec06 6.1.1: useTreeNav implements arrow key navigation
// for tree roles. Up/Down moves items, Right expands, Left collapses.

import { useState, useCallback } from 'preact/hooks'

export interface TreeItem {
  id: string
  expanded?: boolean
  children?: TreeItem[]
}

export interface TreeNavOptions {
  items: TreeItem[]
}

export interface TreeNavResult {
  activeId: string | null
  expandedIds: Set<string>
  handleKeyDown: (e: KeyboardEvent) => void
  getTabIndex: (id: string) => number
  toggleExpand: (id: string) => void
}

function flattenVisible(items: TreeItem[], expanded: Set<string>): string[] {
  const result: string[] = []
  for (const item of items) {
    result.push(item.id)
    if (item.children && item.children.length > 0 && expanded.has(item.id)) {
      result.push(...flattenVisible(item.children, expanded))
    }
  }
  return result
}

function findItem(items: TreeItem[], id: string): TreeItem | null {
  for (const item of items) {
    if (item.id === id) return item
    if (item.children) {
      const found = findItem(item.children, id)
      if (found) return found
    }
  }
  return null
}

function hasChildren(items: TreeItem[], id: string): boolean {
  const item = findItem(items, id)
  return !!(item?.children && item.children.length > 0)
}

export function useTreeNav({ items }: TreeNavOptions): TreeNavResult {
  const [activeId, setActiveId] = useState<string | null>(items[0]?.id ?? null)
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set())

  const toggleExpand = useCallback((id: string) => {
    setExpandedIds((prev) => {
      const next = new Set(prev)
      if (next.has(id)) {
        next.delete(id)
      } else {
        next.add(id)
      }
      return next
    })
  }, [])

  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      const visible = flattenVisible(items, expandedIds)
      const idx = activeId ? visible.indexOf(activeId) : -1

      if (e.key === 'ArrowDown') {
        e.preventDefault()
        const next = Math.min(idx + 1, visible.length - 1)
        if (next >= 0) setActiveId(visible[next] ?? null)
      } else if (e.key === 'ArrowUp') {
        e.preventDefault()
        const next = Math.max(idx - 1, 0)
        if (next >= 0) setActiveId(visible[next] ?? null)
      } else if (e.key === 'ArrowRight') {
        e.preventDefault()
        if (activeId && hasChildren(items, activeId) && !expandedIds.has(activeId)) {
          toggleExpand(activeId)
        }
      } else if (e.key === 'ArrowLeft') {
        e.preventDefault()
        if (activeId) {
          if (expandedIds.has(activeId)) {
            toggleExpand(activeId)
          } else {
            // move to parent logic omitted for simplicity; jump to previous visible
            const next = Math.max(idx - 1, 0)
            if (next >= 0) setActiveId(visible[next] ?? null)
          }
        }
      } else if (e.key === 'Home') {
        e.preventDefault()
        if (visible.length > 0) setActiveId(visible[0] ?? null)
      } else if (e.key === 'End') {
        e.preventDefault()
        if (visible.length > 0) setActiveId(visible[visible.length - 1] ?? null)
      }
    },
    [items, activeId, expandedIds, toggleExpand]
  )

  const getTabIndex = useCallback((id: string) => (id === activeId ? 0 : -1), [activeId])

  return { activeId, expandedIds, handleKeyDown, getTabIndex, toggleExpand }
}
