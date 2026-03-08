// VirtualList — scroll-position based windowing for fixed-height items
//
// Only activates above ACTIVATION_THRESHOLD items. Below that, renders all
// items directly (zero overhead). Uses requestAnimationFrame-throttled scroll
// handler + ResizeObserver for efficient viewport tracking.
//
// Hooks are always called unconditionally to satisfy Rules of Hooks.
// The threshold check only affects the returned markup.

import { html } from 'htm/preact'
import { useRef, useEffect, useState } from 'preact/hooks'
import type { ComponentChildren } from 'preact'

const ACTIVATION_THRESHOLD = 40

interface VirtualListProps<T> {
  items: T[]
  itemHeight: number
  overscan?: number
  renderItem: (item: T, index: number) => ComponentChildren
  getKey: (item: T) => string
  className?: string
}

interface VisibleRange {
  start: number
  end: number
}

export function VirtualList<T>({
  items,
  itemHeight,
  overscan = 5,
  renderItem,
  getKey,
  className = '',
}: VirtualListProps<T>) {
  // Hooks must be called unconditionally (Rules of Hooks)
  const containerRef = useRef<HTMLDivElement>(null)
  const [range, setRange] = useState<VisibleRange>({ start: 0, end: 30 })
  const virtualize = items.length > ACTIVATION_THRESHOLD

  useEffect(() => {
    if (!virtualize) return
    const el = containerRef.current
    if (!el) return

    let disposed = false

    const recompute = () => {
      const { scrollTop, clientHeight } = el
      const newStart = Math.max(0, Math.floor(scrollTop / itemHeight) - overscan)
      const newEnd = Math.min(
        items.length,
        Math.ceil((scrollTop + clientHeight) / itemHeight) + overscan,
      )
      setRange(prev => {
        if (prev.start === newStart && prev.end === newEnd) return prev
        return { start: newStart, end: newEnd }
      })
    }

    let ticking = false
    const onScroll = () => {
      if (ticking || disposed) return
      ticking = true
      requestAnimationFrame(() => {
        if (!disposed) recompute()
        ticking = false
      })
    }

    const ro = new ResizeObserver(() => {
      if (!disposed) recompute()
    })

    recompute()
    el.addEventListener('scroll', onScroll, { passive: true })
    ro.observe(el)

    return () => {
      disposed = true
      el.removeEventListener('scroll', onScroll)
      ro.disconnect()
    }
  }, [virtualize, items.length, itemHeight, overscan])

  // Below threshold: render all items directly, no virtualization
  if (!virtualize) {
    return html`
      <div class=${className}>
        ${items.map((item, i) => renderItem(item, i))}
      </div>
    `
  }

  const totalHeight = items.length * itemHeight
  const offsetY = range.start * itemHeight
  const visible = items.slice(range.start, range.end)

  return html`
    <div ref=${containerRef} class=${className}>
      <div class="virtual-list-spacer" style=${{ height: `${totalHeight}px`, position: 'relative' }}>
        <div
          class="virtual-list-viewport"
          style=${{
            position: 'absolute',
            top: 0,
            left: 0,
            right: 0,
            willChange: 'transform',
            transform: `translateY(${offsetY}px)`,
          }}
        >
          ${visible.map((item, i) => {
            const idx = range.start + i
            return html`<div key=${getKey(item)}>${renderItem(item, idx)}</div>`
          })}
        </div>
      </div>
    </div>
  `
}
