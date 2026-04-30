/**
 * useMenu — SolidJS adapter over headless-core/Menu
 * (RFC 0005 §3.3, RFC 0017 PR #2.10).
 *
 * Two reactive accessors (isOpen / activeId). Optional triggerRef is a
 * getter `() => HTMLElement | null` (Solid convention). On close
 * transition, focus is restored to the trigger if present.
 */

import { createEffect, createSignal, onCleanup, type Accessor } from 'solid-js'
import {
  createMenu,
  type MenuItemProps,
  type MenuOptions,
  type MenuProps,
  type MenuTriggerProps,
} from '../headless-core/menu'

export interface UseMenuArgs extends MenuOptions {
  /** Trigger element getter for focus restoration on close. */
  triggerRef?: () => HTMLElement | null
}

export interface UseMenuResult {
  readonly isOpen: Accessor<boolean>
  readonly activeId: Accessor<string | null>
  open(): void
  close(): void
  toggle(): void
  focus(itemId: string): void
  select(itemId: string): void
  getTriggerProps(): MenuTriggerProps
  getMenuProps(): MenuProps
  getItemProps(itemId: string): MenuItemProps
}

export function useMenu(args: UseMenuArgs): UseMenuResult {
  const { triggerRef, ...opts } = args
  const controller = createMenu(opts)

  const [isOpen, setIsOpen] = createSignal<boolean>(controller.isOpen)
  const [activeId, setActiveId] = createSignal<string | null>(controller.activeId)

  const dispose = controller.subscribe(() => {
    setIsOpen(controller.isOpen)
    setActiveId(controller.activeId)
  })
  onCleanup(dispose)

  // Restore focus to trigger when menu closes (best-effort).
  let wasOpen = false
  createEffect(() => {
    const open = isOpen()
    if (wasOpen && !open) {
      const el = triggerRef?.()
      if (el !== null && el !== undefined) el.focus()
    }
    wasOpen = open
  })

  return {
    isOpen,
    activeId,
    open: () => controller.open(),
    close: () => controller.close(),
    toggle: () => controller.toggle(),
    focus: (id) => controller.focus(id),
    select: (id) => controller.select(id),
    getTriggerProps: () => controller.getTriggerProps(),
    getMenuProps: () => controller.getMenuProps(),
    getItemProps: (id) => controller.getItemProps(id),
  }
}
