// VirtualList — scroll-position based windowing for fixed and dynamic-height items
//
// Only activates above ACTIVATION_THRESHOLD items. Below that, renders all
// items directly (zero overhead). Uses requestAnimationFrame-throttled scroll
// handler + ResizeObserver for efficient viewport tracking.
//
// Hooks are always called unconditionally to satisfy Rules of Hooks.
// The threshold check only affects the returned markup.

import { html } from 'htm/preact'
import { useRef, useEffect, useState, useMemo } from 'preact/hooks'
import type { ComponentChildren } from 'preact'
import { onFpsChange } from '../../utils/fps-adaptive'

const ACTIVATION_THRESHOLD = 40

interface VirtualListProps<T> {
  items: T[]
  itemHeight?: number
  estimatedItemHeight?: number
  overscan?: number
  renderItem: (item: T, index: number) => ComponentChildren
  getKey: (item: T) => string
  className?: string
}

interface VisibleRange {
  start: number
  end: number
}

function binarySearchOffset(offsets: number[], target: number): number {
  let lo = 0
  let hi = offsets.length - 1
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2)
    const midOffset = offsets[mid] ?? 0
    if (midOffset < target) {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  return lo
}

export function VirtualList<T>({
  items,
  itemHeight,
  estimatedItemHeight = 40,
  overscan = 5,
  renderItem,
  getKey,
  className = '',
}: VirtualListProps<T>) {
  // Hooks must be called unconditionally (Rules of Hooks)
  const containerRef = useRef<HTMLDivElement>(null)
  const heightsRef = useRef<Map<string, number>>(new Map())
  const [range, setRange] = useState<VisibleRange>({ start: 0, end: 30 })
  const [measureTick, setMeasureTick] = useState(0)
  const [effectiveOverscan, setEffectiveOverscan] = useState(overscan)
  const virtualize = items.length > ACTIVATION_THRESHOLD

  const dynamicMode = itemHeight === undefined

  // PR-4.9: FPS adaptive quality — shrink overscan when frame rate drops.
  useEffect(() => {
    if (!virtualize) return undefined
    return onFpsChange((fps) => {
      if (fps < 30) setEffectiveOverscan(1)
      else if (fps < 45) setEffectiveOverscan(Math.max(2, overscan - 2))
      else setEffectiveOverscan(overscan)
    })
  }, [virtualize, overscan])

  const offsets = useMemo(() => {
    if (!dynamicMode) return [] as number[]
    const acc: number[] = new Array(items.length + 1)
    acc[0] = 0
    for (let i = 0; i < items.length; i++) {
      const item = items[i]
      if (item === undefined) continue
      const h = heightsRef.current.get(getKey(item)) ?? estimatedItemHeight
      acc[i + 1] = (acc[i] ?? 0) + h
    }
    return acc
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dynamicMode, items, measureTick, estimatedItemHeight, getKey])

  useEffect(() => {
    if (!virtualize) return
    const el = containerRef.current
    if (!el) return

    let disposed = false

    const recompute = () => {
      const os = effectiveOverscan
      if (dynamicMode) {
        const { scrollTop, clientHeight } = el
        const startIdx = binarySearchOffset(offsets, scrollTop)
        const newStart = Math.max(0, startIdx - os)
        const endIdx = binarySearchOffset(offsets, scrollTop + clientHeight)
        const newEnd = Math.min(items.length, endIdx + os)
        setRange(prev => {
          if (prev.start === newStart && prev.end === newEnd) return prev
          return { start: newStart, end: newEnd }
        })
      } else {
        const { scrollTop, clientHeight } = el
        const ih = itemHeight!
        const newStart = Math.max(0, Math.floor(scrollTop / ih) - os)
        const newEnd = Math.min(
          items.length,
          Math.ceil((scrollTop + clientHeight) / ih) + os,
        )
        setRange(prev => {
          if (prev.start === newStart && prev.end === newEnd) return prev
          return { start: newStart, end: newEnd }
        })
      }
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
  }, [virtualize, items.length, itemHeight, effectiveOverscan, dynamicMode, offsets])

  // Observe child heights in dynamic mode
  useEffect(() => {
    if (!virtualize || !dynamicMode) return
    const el = containerRef.current
    if (!el) return

    let disposed = false
    const ro = new ResizeObserver((entries) => {
      let changed = false
      for (const entry of entries) {
        const target = entry.target as HTMLElement
        const key = target.dataset.vlKey
        if (!key) continue
        const h = entry.borderBoxSize?.[0]?.blockSize ?? target.getBoundingClientRect().height
        const prev = heightsRef.current.get(key)
        if (prev !== h) {
          heightsRef.current.set(key, h)
          changed = true
        }
      }
      if (changed && !disposed) {
        setMeasureTick(t => t + 1)
      }
    })

    const viewport = el.querySelector('.virtual-list-viewport')
    if (viewport) {
      for (const child of viewport.children) {
        ro.observe(child)
      }
    }

    return () => {
      disposed = true
      ro.disconnect()
    }
  }, [virtualize, dynamicMode, range.start, range.end])

  // Below threshold: render all items directly, no virtualization
  if (!virtualize) {
    return html`
      <div class=${className}>
        ${items.map((item, i) => renderItem(item, i))}
      </div>
    `
  }

  // Dynamic height path
  if (dynamicMode) {
    const totalHeight = offsets[items.length] ?? items.length * estimatedItemHeight
    const offsetY = offsets[range.start] ?? range.start * estimatedItemHeight
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
              return html`<div key=${getKey(item)} data-vl-key=${getKey(item)}>${renderItem(item, idx)}</div>`
            })}
          </div>
        </div>
      </div>
    `
  }

  // Fixed height path
  const ih = itemHeight!
  const totalHeight = items.length * ih
  const offsetY = range.start * ih
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
