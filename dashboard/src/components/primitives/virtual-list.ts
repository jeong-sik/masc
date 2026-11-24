/**
 * Lean Preact wrapper over `@tanstack/virtual-core` for high-density lists & tables.
 */

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import {
  Virtualizer,
  elementScroll,
  observeElementOffset,
  observeElementRect,
  type ScrollToOptions,
  type VirtualItem,
} from '@tanstack/virtual-core'

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

  useEffect(() => virtualizer._didMount(), [virtualizer])

  virtualizer._willUpdate()

  return {
    virtualItems: virtualizer.getVirtualItems(),
    totalSize: virtualizer.getTotalSize(),
    scrollToIndex: (index, options) => virtualizer.scrollToIndex(index, options),
    scrollToOffset: (offset, options) => virtualizer.scrollToOffset(offset, options),
    measureElement: (el) => virtualizer.measureElement(el),
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
  const estimateFn = typeof props.estimateSize === 'function'
    ? props.estimateSize
    : () => props.estimateSize as number

  const { virtualItems, totalSize } = useVirtualList({
    count: props.items.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: estimateFn,
    overscan: props.overscan,
    initialHeight: typeof props.height === 'number' ? props.height : 480,
    getItemKey: props.getItemKey
      ? (index) => props.getItemKey!(props.items[index]!, index)
      : undefined,
  })

  if (props.items.length === 0 && props.empty !== undefined) {
    return html`<div class=${props.className ?? ''}>${props.empty}</div>`
  }

  const containerStyle = props.height !== undefined
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
