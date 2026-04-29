/**
 * useSplitPane — Preact adapter over headless-core/SplitPane.
 *
 * Per RFC 0004 §3.2. Owns a ResizeObserver on the container ref to
 * feed setContainerSize, subscribes to ratio changes, and exposes
 * splitter prop bundle + first/second pane flex-basis style helpers.
 */

import type { RefObject } from 'preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  createSplitPane,
  type SplitDirection,
  type SplitPane,
  type SplitterProps,
  type SplitKeyEvent,
  type SplitPointerEvent,
  type SplitStorage,
} from '../headless-core/split-pane'

export interface UseSplitPaneArgs {
  containerRef: RefObject<HTMLElement | null>
  direction: SplitDirection
  defaultRatio?: number
  minRatio?: number
  maxRatio?: number
  persistKey?: string
  storage?: SplitStorage
  onResize?: (ratio: number) => void
  ariaLabel?: string
}

export interface UseSplitPaneResult {
  readonly ratio: number
  readonly collapsed: boolean
  setRatio(value: number): void
  collapse(side: 'first' | 'second'): void
  expand(): void
  splitterProps: SplitterProps & {
    readonly onPointerDown: (e: SplitPointerEvent) => void
    readonly onPointerMove: (e: SplitPointerEvent) => void
    readonly onPointerUp: () => void
    readonly onKeyDown: (e: SplitKeyEvent) => void
  }
  readonly firstPaneStyle: { readonly flexBasis: string }
  readonly secondPaneStyle: { readonly flexBasis: string }
}

export function useSplitPane(args: UseSplitPaneArgs): UseSplitPaneResult {
  const splitRef = useRef<SplitPane | null>(null)
  const [ratio, setRatio] = useState<number>(() => args.defaultRatio ?? 0.5)
  const [collapsed, setCollapsed] = useState<boolean>(false)

  if (splitRef.current === null) {
    splitRef.current = createSplitPane({
      direction: args.direction,
      defaultRatio: args.defaultRatio,
      minRatio: args.minRatio,
      maxRatio: args.maxRatio,
      persistKey: args.persistKey,
      storage: args.storage,
      onResize: args.onResize,
      ariaLabel: args.ariaLabel,
    })
    setRatio(splitRef.current.getRatio())
  }

  useEffect(() => {
    const sp = splitRef.current
    if (sp === null) return undefined
    const dispose = sp.subscribe((r, c) => {
      setRatio(r)
      setCollapsed(c)
    })
    return dispose
  }, [])

  // ResizeObserver wiring.
  useEffect(() => {
    const sp = splitRef.current
    const el = args.containerRef.current
    if (sp === null || el === null) return undefined
    if (typeof ResizeObserver === 'undefined') return undefined
    const ro = new ResizeObserver((entries) => {
      const entry = entries[0]
      if (entry === undefined) return
      const px =
        args.direction === 'horizontal'
          ? entry.contentRect.width
          : entry.contentRect.height
      sp.setContainerSize(px)
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [args.containerRef, args.direction])

  return useMemo<UseSplitPaneResult>(() => {
    const sp = splitRef.current!
    return {
      ratio,
      collapsed,
      setRatio: (v: number) => sp.setRatio(v),
      collapse: (side: 'first' | 'second') => sp.collapse(side),
      expand: () => sp.expand(),
      splitterProps: {
        ...sp.getSplitterProps(),
        onPointerDown: (e: SplitPointerEvent) => sp.handlePointerDown(e),
        onPointerMove: (e: SplitPointerEvent) => sp.handlePointerMove(e),
        onPointerUp: () => sp.handlePointerUp(),
        onKeyDown: (e: SplitKeyEvent) => sp.handleKeyDown(e),
      },
      firstPaneStyle: { flexBasis: `${Math.round(ratio * 100)}%` },
      secondPaneStyle: { flexBasis: `${Math.round((1 - ratio) * 100)}%` },
    }
  }, [ratio, collapsed])
}
