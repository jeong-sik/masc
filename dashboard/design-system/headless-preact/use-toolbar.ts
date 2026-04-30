/**
 * useToolbar — Preact adapter over headless-core/Toolbar (RFC 0016 §3.2).
 *
 * Mirrors useRovingTabindex shape. Consumer supplies a containerRef;
 * when present and ResizeObserver is available, the adapter wires up
 * width tracking automatically. Item width tracking remains the
 * consumer's responsibility (per-item refs vary by render strategy).
 */

import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import type { RefObject } from 'preact'
import {
  createToolbar,
  type ToolbarController,
  type ToolbarItem,
  type ToolbarItemProps,
  type ToolbarOptions,
  type ToolbarRootProps,
} from '../headless-core/toolbar'

export interface UseToolbarArgs extends ToolbarOptions {
  containerRef?: RefObject<HTMLElement>
}

export interface UseToolbarResult {
  readonly visibleItems: ReadonlyArray<ToolbarItem>
  readonly overflowItems: ReadonlyArray<ToolbarItem>
  readonly hasOverflow: boolean
  readonly activeId: string | null
  readonly overflowMenuOpen: boolean
  getRootProps(): ToolbarRootProps
  getItemProps(id: string): ToolbarItemProps
  getOverflowMenuTriggerProps(): { readonly 'aria-haspopup': 'menu'; readonly 'aria-expanded': boolean; readonly onClick: () => void }
  setItemWidth(id: string, px: number): void
  setContainerSize(px: number): void
  toggle(id: string): void
  selectRadio(id: string): void
  activate(id: string): void
  openOverflowMenu(): void
  closeOverflowMenu(): void
}

export function useToolbar(args: UseToolbarArgs): UseToolbarResult {
  const controllerRef = useRef<ToolbarController | null>(null)
  const [, bump] = useState(0)

  if (controllerRef.current === null) {
    const { containerRef: _ignored, ...opts } = args
    controllerRef.current = createToolbar(opts)
  }

  useEffect(() => {
    controllerRef.current?.setItems(args.items)
  }, [args.items])

  useEffect(() => {
    const c = controllerRef.current
    if (c === null) return undefined
    return c.subscribe(() => bump((n) => n + 1))
  }, [])

  useEffect(() => {
    const ref = args.containerRef
    if (ref === undefined) return undefined
    const el = ref.current
    if (el === null) return undefined
    const c = controllerRef.current
    if (c === null) return undefined
    c.setContainerSize(el.getBoundingClientRect().width)
    if (typeof ResizeObserver === 'undefined') return undefined
    const ro = new ResizeObserver((entries) => {
      const last = entries[entries.length - 1]
      if (last !== undefined) c.setContainerSize(last.contentRect.width)
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [args.containerRef])

  return useMemo<UseToolbarResult>(() => {
    const c = controllerRef.current!
    return {
      get visibleItems() {
        return c.visibleItems
      },
      get overflowItems() {
        return c.overflowItems
      },
      get hasOverflow() {
        return c.hasOverflow
      },
      get activeId() {
        return c.activeId
      },
      get overflowMenuOpen() {
        return c.overflowMenuOpen
      },
      getRootProps: () => c.getRootProps(),
      getItemProps: (id) => c.getItemProps(id),
      getOverflowMenuTriggerProps: () => {
        const open = c.overflowMenuOpen
        return Object.freeze({
          'aria-haspopup': 'menu' as const,
          'aria-expanded': open,
          onClick: () =>
            open ? c.closeOverflowMenu() : c.openOverflowMenu(),
        })
      },
      setItemWidth: (id, px) => c.setItemWidth(id, px),
      setContainerSize: (px) => c.setContainerSize(px),
      toggle: (id) => c.toggle(id),
      selectRadio: (id) => c.selectRadio(id),
      activate: (id) => c.activate(id),
      openOverflowMenu: () => c.openOverflowMenu(),
      closeOverflowMenu: () => c.closeOverflowMenu(),
    }
  }, [])
}
