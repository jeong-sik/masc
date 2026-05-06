// roving-tabindex.ts — Roving Tabindex hook for tablist / radiogroup / toolbar
//
// Kimi design system sec01 1.3.2: one item is tabbable (tabindex=0), rest are
// tabindex=-1. Arrow keys move focus; Home/End jump to extremes.

import { useState } from 'preact/hooks'

interface RovingTabIndexResult {
  activeIndex: number
  handleKeyDown: (e: KeyboardEvent) => void
  getTabIndex: (index: number) => number
}

export function useRovingTabIndex(
  itemCount: number,
  orientation: 'horizontal' | 'vertical' = 'horizontal',
): RovingTabIndexResult {
  const [activeIndex, setActiveIndex] = useState(0)

  const handleKeyDown = (e: KeyboardEvent) => {
    const keys =
      orientation === 'horizontal'
        ? { next: 'ArrowRight', prev: 'ArrowLeft' }
        : { next: 'ArrowDown', prev: 'ArrowUp' }

    if (e.key === keys.next) {
      e.preventDefault()
      setActiveIndex((i) => Math.min(i + 1, itemCount - 1))
    }
    if (e.key === keys.prev) {
      e.preventDefault()
      setActiveIndex((i) => Math.max(i - 1, 0))
    }
    if (e.key === 'Home') {
      e.preventDefault()
      setActiveIndex(0)
    }
    if (e.key === 'End') {
      e.preventDefault()
      setActiveIndex(itemCount - 1)
    }
  }

  const getTabIndex = (index: number) => (index === activeIndex ? 0 : -1)

  return { activeIndex, handleKeyDown, getTabIndex }
}
