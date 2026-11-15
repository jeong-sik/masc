// VirtualList — scroll-position based windowing for fixed and dynamic-height items
//
// Every list has the same DOM: root → spacer → viewport → one keyed row per
// drawn item. Up to ACTIVATION_THRESHOLD items the list draws every row in
// normal flow, which keeps them reachable by the browser's find and by
// assistive technology. Above it the list draws the rows near the scroll
// position and offsets them inside a spacer as tall as the whole list. A row
// that is drawn before and after the item count crosses the threshold keeps
// its DOM node, and so its focus and whatever state lives in that node.
//
// The caller names the element that scrolls the list (`scrollBox`). The list
// reads the position from that element and does not look for one itself.

import { html } from 'htm/preact'
import { useRef, useEffect, useLayoutEffect, useState, useMemo } from 'preact/hooks'
import type { ComponentChildren } from 'preact'
import { onFpsChange } from '../../utils/fps-adaptive'

const ACTIVATION_THRESHOLD = 40

/** The element whose scrolling moves the list.
 *  - `'self'`: the list's own root. The caller's `className` gives it a bounded
 *    height and `overflow-y`.
 *  - an element: an ancestor that scrolls, with the list somewhere inside it.
 *    A caller that gets it from a ref renders the list once the element exists. */
export type VirtualListScrollBox = 'self' | HTMLElement

interface VirtualListProps<T> {
  items: T[]
  itemHeight?: number
  estimatedItemHeight?: number
  overscan?: number
  renderItem: (item: T, index: number) => ComponentChildren
  getKey: (item: T) => string
  scrollBox: VirtualListScrollBox
  className?: string
  onEndReached?: () => void
  tabIndex?: number
  ariaLabel?: string
}

interface VisibleRange {
  start: number
  end: number
}

/** The stretch of the list the scroll box shows, measured from the list's top. */
interface View {
  top: number
  height: number
  /** Height of the whole list, drawn or not. */
  listHeight: number
}

function viewOf(root: HTMLElement, scrollBox: VirtualListScrollBox): View {
  if (scrollBox === 'self') {
    return { top: root.scrollTop, height: root.clientHeight, listHeight: root.scrollHeight }
  }
  const boxTop = scrollBox.getBoundingClientRect().top + scrollBox.clientTop
  return {
    top: boxTop - root.getBoundingClientRect().top,
    height: scrollBox.clientHeight,
    listHeight: root.offsetHeight,
  }
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

/** The items a view shows, widened by the overscan on both sides.
 *  `itemHeight` undefined means dynamic heights, read from `offsets`. A list
 *  that sits above or below what its scroll box shows has no item in view, so
 *  both ends stay inside the list. */
function rangeInView(
  view: View,
  count: number,
  overscan: number,
  offsets: number[],
  itemHeight: number | undefined,
): VisibleRange {
  const bottom = view.top + view.height
  const first = itemHeight === undefined
    ? binarySearchOffset(offsets, view.top)
    : Math.floor(view.top / itemHeight)
  const last = itemHeight === undefined
    ? binarySearchOffset(offsets, bottom)
    : Math.ceil(bottom / itemHeight)
  const inList = (index: number) => Math.min(count, Math.max(0, index))
  return { start: inList(first - overscan), end: inList(last + overscan) }
}

function sameRange(left: VisibleRange, right: VisibleRange): boolean {
  return left.start === right.start && left.end === right.end
}

function readRowHeight(entry: ResizeObserverEntry): number {
  const blockSize = entry.borderBoxSize?.[0]?.blockSize
  if (typeof blockSize === 'number' && blockSize > 0) {
    return blockSize
  }
  const contentHeight = entry.contentRect?.height
  if (typeof contentHeight === 'number' && contentHeight > 0) {
    return contentHeight
  }
  const target = entry.target as HTMLElement
  return target.getBoundingClientRect().height
}

export function VirtualList<T>({
  items,
  itemHeight,
  estimatedItemHeight = 40,
  overscan = 5,
  renderItem,
  getKey,
  scrollBox,
  className = '',
  onEndReached,
  tabIndex,
  ariaLabel,
}: VirtualListProps<T>) {
  const rootRef = useRef<HTMLDivElement>(null)
  const viewportRef = useRef<HTMLDivElement>(null)
  const heightsRef = useRef<Map<string, number>>(new Map())
  const endReachedCalledRef = useRef(false)
  // The rows the scroll position shows. It follows the scroll box at every
  // item count, so that the render in which a list grows past the threshold
  // already knows which rows are on screen and keeps their DOM nodes.
  const [range, setRange] = useState<VisibleRange>({ start: 0, end: 30 })
  const [measureTick, setMeasureTick] = useState(0)
  const [effectiveOverscan, setEffectiveOverscan] = useState(overscan)
  const windowed = items.length > ACTIVATION_THRESHOLD
  const drawn: VisibleRange = windowed ? range : { start: 0, end: items.length }

  const dynamicMode = itemHeight === undefined

  // Callers pass getKey inline, so its identity changes every render. Read it
  // through a ref so derived work follows the items, not the callback.
  const getKeyRef = useRef(getKey)
  getKeyRef.current = getKey

  // The rows the child ResizeObserver must watch are identified by their
  // keys. A same-length dataset can replace every visible key while the
  // range indices stay put, so the observer binding follows this signature.
  const drawnKeySignature = items
    .slice(drawn.start, drawn.end)
    .map(item => getKey(item))
    .join('\u0000')

  // Allow onEndReached to fire again after the dataset grows (typical infinite
  // scroll pattern: new items load while the user remains near the bottom).
  useEffect(() => {
    endReachedCalledRef.current = false
  }, [items.length])

  // PR-4.9: FPS adaptive quality — shrink overscan when frame rate drops.
  // Overscan only decides what a windowed list draws, and the subscription
  // keeps a frame counter running, so a list that draws every row stays out.
  useEffect(() => {
    if (!windowed) return undefined
    return onFpsChange((fps) => {
      if (fps < 30) setEffectiveOverscan(1)
      else if (fps < 45) setEffectiveOverscan(Math.max(2, overscan - 2))
      else setEffectiveOverscan(overscan)
    })
  }, [windowed, overscan])

  // Discard cached heights for items that are no longer present so the map
  // does not grow unbounded across reordering / filtering.
  useEffect(() => {
    if (items.length === 0) {
      heightsRef.current.clear()
      return
    }
    const validKeys = new Set(items.map(getKeyRef.current))
    for (const key of heightsRef.current.keys()) {
      if (!validKeys.has(key)) {
        heightsRef.current.delete(key)
      }
    }
  }, [items])

  const offsets = useMemo(() => {
    if (!dynamicMode) return [] as number[]
    const acc: number[] = new Array(items.length + 1)
    acc[0] = 0
    for (let i = 0; i < items.length; i++) {
      const item = items[i]
      if (item === undefined) continue
      const h = heightsRef.current.get(getKeyRef.current(item)) ?? estimatedItemHeight
      acc[i + 1] = (acc[i] ?? 0) + h
    }
    return acc
  }, [dynamicMode, items, measureTick, estimatedItemHeight])

  // The effect below runs after the browser has painted. When the items change
  // under a scrolled list, that paint would still show the previous range: a
  // list that shrank slices past its end. That leaves the top of the viewport,
  // or all of it, without rows for a frame. Move the window to the scroll
  // position before that paint. Preact renders the state change below in a
  // microtask, which is what keeps it in the same frame.
  useLayoutEffect(() => {
    const root = rootRef.current
    if (!root) return
    const next = rangeInView(viewOf(root, scrollBox), items.length, effectiveOverscan, offsets, itemHeight)
    setRange(prev => (sameRange(prev, next) ? prev : next))
  }, [scrollBox, items.length, effectiveOverscan, offsets, itemHeight])

  useEffect(() => {
    const root = rootRef.current
    if (!root) return
    const scroller = scrollBox === 'self' ? root : scrollBox

    let disposed = false
    const endThreshold = dynamicMode ? estimatedItemHeight * 5 : itemHeight! * 4

    const recompute = () => {
      const next = rangeInView(viewOf(root, scrollBox), items.length, effectiveOverscan, offsets, itemHeight)
      setRange(prev => (sameRange(prev, next) ? prev : next))
    }

    const checkEndReached = () => {
      if (!onEndReached || disposed) return
      const view = viewOf(root, scrollBox)
      const remaining = view.listHeight - view.top - view.height
      const nearBottom = remaining < endThreshold
      if (nearBottom && !endReachedCalledRef.current) {
        endReachedCalledRef.current = true
        onEndReached()
      } else if (!nearBottom) {
        endReachedCalledRef.current = false
      }
    }

    let ticking = false
    const onScroll = () => {
      if (ticking || disposed) return
      ticking = true
      requestAnimationFrame(() => {
        if (!disposed) {
          recompute()
          checkEndReached()
        }
        ticking = false
      })
    }

    const ro = new ResizeObserver(() => {
      if (!disposed) recompute()
    })

    recompute()
    checkEndReached()
    scroller.addEventListener('scroll', onScroll, { passive: true })
    ro.observe(scroller)

    return () => {
      disposed = true
      scroller.removeEventListener('scroll', onScroll)
      ro.disconnect()
    }
  }, [scrollBox, items.length, itemHeight, effectiveOverscan, dynamicMode, offsets, estimatedItemHeight, onEndReached])

  // Observe row heights in dynamic mode. A list that draws every row measures
  // them too: when it grows past the threshold, the rows above the scroll
  // position already have the height they were laid out with, and the rows on
  // screen stay where they were.
  useEffect(() => {
    if (!dynamicMode) return
    const viewport = viewportRef.current
    if (!viewport) return

    let disposed = false
    const ro = new ResizeObserver((entries) => {
      let changed = false
      for (const entry of entries) {
        const key = (entry.target as HTMLElement).dataset.vlKey
        if (!key) continue
        const h = readRowHeight(entry)
        const prev = heightsRef.current.get(key)
        if (prev !== h && h > 0) {
          heightsRef.current.set(key, h)
          changed = true
        }
      }
      if (changed && !disposed) {
        setMeasureTick(t => t + 1)
      }
    })

    for (const child of viewport.children) {
      ro.observe(child)
    }

    return () => {
      disposed = true
      ro.disconnect()
    }
  }, [dynamicMode, drawnKeySignature])

  const rowHeight = itemHeight ?? estimatedItemHeight
  const totalHeight = itemHeight === undefined
    ? offsets[items.length] ?? items.length * estimatedItemHeight
    : items.length * itemHeight
  const offsetY = itemHeight === undefined
    ? offsets[drawn.start] ?? drawn.start * estimatedItemHeight
    : drawn.start * itemHeight

  // A windowed list reserves the height of every row and moves the drawn rows
  // to their place in it. `flex: none` keeps that height when the caller's
  // className makes the root a flex container. A list that draws every row
  // leaves them in normal flow, where the browser gives each its real height.
  const spacerStyle = windowed
    ? { height: `${totalHeight}px`, position: 'relative', flex: 'none' }
    : undefined
  const viewportStyle = windowed
    ? {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        willChange: 'transform',
        transform: `translateY(${offsetY}px)`,
      }
    : undefined
  // With every row in the DOM, content-visibility lets the browser skip layout
  // and paint for the rows that are off screen.
  const rowStyle = windowed
    ? undefined
    : { contentVisibility: 'auto', containIntrinsicSize: `auto ${rowHeight}px` }

  return html`
    <div ref=${rootRef} class=${className} tabindex=${tabIndex} aria-label=${ariaLabel}>
      <div class="virtual-list-spacer" style=${spacerStyle}>
        <div ref=${viewportRef} class="virtual-list-viewport" style=${viewportStyle}>
          ${items.slice(drawn.start, drawn.end).map((item, i) => {
            const key = getKey(item)
            return html`<div key=${key} data-vl-key=${key} style=${rowStyle}>${renderItem(item, drawn.start + i)}</div>`
          })}
        </div>
      </div>
    </div>
  `
}
