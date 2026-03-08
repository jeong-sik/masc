// VirtualList — scroll-position based windowing for fixed-height items
//
// Only activates above ACTIVATION_THRESHOLD items. Below that, renders all
// items directly (zero overhead). Uses requestAnimationFrame-throttled scroll
// handler + ResizeObserver for efficient viewport tracking.

import { html } from 'htm/preact'
import { useRef, useEffect, useState } from 'preact/hooks'

const ACTIVATION_THRESHOLD = 40

interface VirtualListProps<T> {
  items: T[]
  itemHeight: number
  overscan?: number
  renderItem: (item: T, index: number) => unknown
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
  // Below threshold: render everything, no virtualization overhead
  if (items.length <= ACTIVATION_THRESHOLD) {
    return html`
      <div class=${className}>
        ${items.map((item, i) => renderItem(item, i))}
      </div>
    `
  }

  const containerRef = useRef<HTMLDivElement>(null)
  const [range, setRange] = useState<VisibleRange>({ start: 0, end: 30 })

  useEffect(() => {
    const el = containerRef.current
    if (!el) return

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
      if (ticking) return
      ticking = true
      requestAnimationFrame(() => {
        recompute()
        ticking = false
      })
    }

    const ro = new ResizeObserver(() => recompute())

    recompute()
    el.addEventListener('scroll', onScroll, { passive: true })
    ro.observe(el)

    return () => {
      el.removeEventListener('scroll', onScroll)
      ro.disconnect()
    }
  }, [items.length, itemHeight, overscan])

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
