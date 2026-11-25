/**
 * Lean Preact wrapper over `@tanstack/virtual-core` for high-density lists & tables.
 */

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useCallback, useLayoutEffect, useRef, useState } from 'preact/hooks'
import {
  Virtualizer,
  elementScroll,
  observeElementOffset,
  observeElementRect,
  type ScrollToOptions,
  type VirtualItem,
} from '@tanstack/virtual-core'

const HEIGHT_100_STYLE = Object.freeze({ height: '100%' })

export interface UseVirtualListOptions<TScrollElement extends Element = HTMLDivElement> {
  readonly count: number
  readonly getScrollElement: () => TScrollElement | null
  readonly estimateSize: (index: number) => number
  readonly overscan?: number
  readonly initialHeight?: number
  readonly getItemKey?: (index: number) => string | number
}

export interface UseVirtualListResult {
  readonly virtualItems: readonly VirtualItem[]
  readonly totalSize: number
  readonly scrollToIndex: (index: number, options?: ScrollToOptions) => void
  readonly scrollToOffset: (offset: number, options?: ScrollToOptions) => void
  readonly measureElement: (el: Element | null) => void
}

/**
 * The drawn height of a row, to the fraction of a pixel: rows placed by a
 * rounded height drift apart by the rounding (a 64.59 px row kept as 65 px
 * leaves 0.41 px of the list showing under it).
 *
 * A row without a layout box (a hidden ancestor, or a DOM that does no layout)
 * reports 0. That is no height, so the row keeps the size it already has.
 */
function measureRow<TScrollElement extends Element>(
  element: Element,
  entry: ResizeObserverEntry | undefined,
  instance: Virtualizer<TScrollElement, Element>,
): number {
  const index = instance.indexFromElement(element)
  const known = instance.itemSizeCache.get(instance.options.getItemKey(index))
  // Registered again without a resize: its observer reports every later change.
  if (!entry && known !== undefined) return known
  const drawn = entry?.borderBoxSize[0]?.blockSize ?? element.getBoundingClientRect().height
  return drawn > 0 ? drawn : known ?? instance.options.estimateSize(index)
}

/**
 * Windows a long list over `getScrollElement()`. To have a row measured, give
 * its element `data-index` and `ref=${measureElement}`; a row drawn without them
 * keeps `estimateSize`.
 */
export function useVirtualList<TScrollElement extends Element = HTMLDivElement>(
  opts: UseVirtualListOptions<TScrollElement>,
): UseVirtualListResult {
  const [, setTick] = useState(0)
  const virtualizerRef = useRef<Virtualizer<TScrollElement, Element> | null>(null)

  const resolvedOptions = {
    count: opts.count,
    getScrollElement: opts.getScrollElement,
    estimateSize: opts.estimateSize,
    overscan: opts.overscan ?? 6,
    initialRect: { width: 0, height: opts.initialHeight ?? 480 },
    scrollToFn: elementScroll,
    measureElement: measureRow,
    observeElementRect,
    observeElementOffset,
    ...(opts.getItemKey ? { getItemKey: opts.getItemKey } : {}),
    onChange: () => {
      setTick((n) => (n + 1) % 1_000_000)
    },
  }

  if (!virtualizerRef.current) {
    virtualizerRef.current = new Virtualizer<TScrollElement, Element>(resolvedOptions)
  } else {
    virtualizerRef.current.setOptions(resolvedOptions)
  }

  const virtualizer = virtualizerRef.current

  useLayoutEffect(() => virtualizer._didMount(), [virtualizer])

  // The scroll element is in the document only once a render has committed, so
  // the virtualizer attaches to it here. Attached while rendering, it finds no
  // element on the first render, and a list that is drawn once never hears its
  // own scrolling.
  useLayoutEffect(() => {
    virtualizer._willUpdate()
  })

  return {
    virtualItems: virtualizer.getVirtualItems(),
    totalSize: virtualizer.getTotalSize(),
    scrollToIndex: (index, options) => virtualizer.scrollToIndex(index, options),
    scrollToOffset: (offset, options) => virtualizer.scrollToOffset(offset, options),
    // One function for the life of the list: a ref that changes identity is
    // called again for every drawn row on every render.
    measureElement: virtualizer.measureElement,
  }
}

export interface VirtualListProps<T> {
  readonly items: readonly T[]
  readonly estimateSize: number | ((index: number) => number)
  readonly height?: number | string
  readonly overscan?: number
  readonly getItemKey?: (item: T, index: number) => string | number
  readonly renderItem: (item: T, index: number) => ComponentChildren
  readonly empty?: ComponentChildren
  readonly className?: string
  readonly ariaLabel?: string
}

export function VirtualList<T>(props: VirtualListProps<T>) {
  const scrollRef = useRef<HTMLDivElement>(null)
  const estimateRef = useRef(props.estimateSize)
  estimateRef.current = props.estimateSize
  const itemsRef = useRef(props.items)
  itemsRef.current = props.items
  const getItemKeyRef = useRef(props.getItemKey)
  getItemKeyRef.current = props.getItemKey

  const getScrollElement = useCallback(() => scrollRef.current, [])
  const estimateSize = useCallback(
    (index: number) => {
      const est = estimateRef.current
      return typeof est === 'function' ? est(index) : est
    },
    [],
  )
  const stableGetItemKey = useCallback(
    (index: number) => getItemKeyRef.current!(itemsRef.current[index]!, index),
    [],
  )

  const { virtualItems, totalSize, measureElement: measureRowElement } = useVirtualList({
    count: props.items.length,
    getScrollElement,
    estimateSize,
    overscan: props.overscan,
    initialHeight: typeof props.height === 'number' ? props.height : 480,
    getItemKey: props.getItemKey ? stableGetItemKey : undefined,
  })

  if (props.items.length === 0 && props.empty !== undefined) {
    return html`<div class=${props.className ?? ''}>${props.empty}</div>`
  }

  const containerStyle = props.height === '100%'
    ? HEIGHT_100_STYLE
    : props.height !== undefined
      ? { height: typeof props.height === 'number' ? `${props.height}px` : props.height }
      : undefined

  return html`
    <div
      ref=${scrollRef}
      class=${`vlist ${props.className ?? ''}`.trim()}
      role="list"
      aria-label=${props.ariaLabel}
      style=${containerStyle}
    >
      <div class="vlist-inner" style=${{ height: `${totalSize}px` }}>
        ${virtualItems.map((vItem) => {
          const item = props.items[vItem.index]
          if (item === undefined) return null
          return html`
            <div
              key=${String(vItem.key)}
              ref=${measureRowElement}
              role="listitem"
              class="vlist-row"
              data-index=${vItem.index}
              style=${{ transform: `translateY(${vItem.start}px)` }}
            >
              ${props.renderItem(item, vItem.index)}
            </div>
          `
        })}
      </div>
    </div>
  `
}
