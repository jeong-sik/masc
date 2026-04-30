/**
 * useToolbar — SolidJS adapter over headless-core/Toolbar
 * (RFC 0016 §3.2, RFC 0017 PR #2.8).
 *
 * Cached controller via createRoot, subscribe → multi-field setSignal
 * for reactive snapshot reads. Optional containerRef getter wires up
 * ResizeObserver for width-driven overflow split.
 */

import { createEffect, createSignal, onCleanup, type Accessor } from 'solid-js'
import {
  createToolbar,
  type ToolbarController,
  type ToolbarItem,
  type ToolbarItemProps,
  type ToolbarOptions,
  type ToolbarRootProps,
} from '../headless-core/toolbar'

export interface UseToolbarArgs extends ToolbarOptions {
  /** Container element getter; pass `() => containerEl` for ResizeObserver wiring. */
  containerRef?: () => HTMLElement | null
}

export interface UseToolbarResult {
  readonly visibleItems: Accessor<ReadonlyArray<ToolbarItem>>
  readonly overflowItems: Accessor<ReadonlyArray<ToolbarItem>>
  readonly hasOverflow: Accessor<boolean>
  readonly activeId: Accessor<string | null>
  readonly overflowMenuOpen: Accessor<boolean>
  readonly controller: ToolbarController
  getRootProps(): ToolbarRootProps
  getItemProps(id: string): ToolbarItemProps
  getOverflowMenuTriggerProps(): {
    readonly 'aria-haspopup': 'menu'
    readonly 'aria-expanded': Accessor<boolean>
    readonly onClick: () => void
  }
  setItemWidth(id: string, px: number): void
  setContainerSize(px: number): void
  toggle(id: string): void
  selectRadio(id: string): void
  activate(id: string): void
  openOverflowMenu(): void
  closeOverflowMenu(): void
}

export function useToolbar(args: UseToolbarArgs): UseToolbarResult {
  const { containerRef: _ignored, ...opts } = args
  const controller = createToolbar(opts)

  const [visibleItems, setVisibleItems] = createSignal<ReadonlyArray<ToolbarItem>>(
    controller.visibleItems,
  )
  const [overflowItems, setOverflowItems] = createSignal<ReadonlyArray<ToolbarItem>>(
    controller.overflowItems,
  )
  const [hasOverflow, setHasOverflow] = createSignal<boolean>(controller.hasOverflow)
  const [activeId, setActiveId] = createSignal<string | null>(controller.activeId)
  const [overflowMenuOpen, setOverflowMenuOpen] = createSignal<boolean>(
    controller.overflowMenuOpen,
  )

  const dispose = controller.subscribe(() => {
    setVisibleItems(controller.visibleItems)
    setOverflowItems(controller.overflowItems)
    setHasOverflow(controller.hasOverflow)
    setActiveId(controller.activeId)
    setOverflowMenuOpen(controller.overflowMenuOpen)
  })
  onCleanup(dispose)

  // ResizeObserver wiring for containerRef.
  if (args.containerRef !== undefined) {
    createEffect(() => {
      const el = args.containerRef!()
      if (el === null) return
      controller.setContainerSize(el.getBoundingClientRect().width)
      if (typeof ResizeObserver === 'undefined') return
      const ro = new ResizeObserver((entries) => {
        const last = entries[entries.length - 1]
        if (last !== undefined) controller.setContainerSize(last.contentRect.width)
      })
      ro.observe(el)
      onCleanup(() => ro.disconnect())
    })
  }

  return {
    visibleItems,
    overflowItems,
    hasOverflow,
    activeId,
    overflowMenuOpen,
    controller,
    getRootProps: () => controller.getRootProps(),
    getItemProps: (id) => controller.getItemProps(id),
    getOverflowMenuTriggerProps: () => ({
      'aria-haspopup': 'menu' as const,
      'aria-expanded': overflowMenuOpen,
      onClick: () =>
        overflowMenuOpen()
          ? controller.closeOverflowMenu()
          : controller.openOverflowMenu(),
    }),
    setItemWidth: (id, px) => controller.setItemWidth(id, px),
    setContainerSize: (px) => controller.setContainerSize(px),
    toggle: (id) => controller.toggle(id),
    selectRadio: (id) => controller.selectRadio(id),
    activate: (id) => controller.activate(id),
    openOverflowMenu: () => controller.openOverflowMenu(),
    closeOverflowMenu: () => controller.closeOverflowMenu(),
  }
}
