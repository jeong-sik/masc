/**
 * useMenu — Preact adapter over headless-core/Menu (RFC 0005 §3.3).
 *
 * Cached controller via useRef, subscribe → bumpState. Optional
 * triggerRef enables future placement / focus restoration; current
 * implementation forwards triggerProps and lets the consumer attach
 * the ref directly.
 */

import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import type { RefObject } from 'preact'
import {
  createMenu,
  type MenuController,
  type MenuItemProps,
  type MenuOptions,
  type MenuProps,
  type MenuTriggerProps,
} from '../headless-core/menu'

export interface UseMenuArgs extends MenuOptions {
  triggerRef?: RefObject<HTMLElement>
}

export interface UseMenuResult {
  readonly isOpen: boolean
  readonly activeId: string | null
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
  const controllerRef = useRef<MenuController | null>(null)
  const [, bump] = useState(0)

  if (controllerRef.current === null) {
    const { triggerRef: _ignored, ...opts } = args
    controllerRef.current = createMenu(opts)
  }

  useEffect(() => {
    const c = controllerRef.current
    if (c === null) return undefined
    return c.subscribe(() => bump((n) => n + 1))
  }, [])

  // Restore focus to trigger when menu closes (best-effort).
  const wasOpenRef = useRef(false)
  useEffect(() => {
    const c = controllerRef.current
    if (c === null) return
    const open = c.isOpen
    if (wasOpenRef.current && !open && args.triggerRef?.current) {
      args.triggerRef.current.focus()
    }
    wasOpenRef.current = open
  })

  return useMemo<UseMenuResult>(() => {
    const c = controllerRef.current!
    return {
      get isOpen() {
        return c.isOpen
      },
      get activeId() {
        return c.activeId
      },
      open: () => c.open(),
      close: () => c.close(),
      toggle: () => c.toggle(),
      focus: (id) => c.focus(id),
      select: (id) => c.select(id),
      getTriggerProps: () => c.getTriggerProps(),
      getMenuProps: () => c.getMenuProps(),
      getItemProps: (id) => c.getItemProps(id),
    }
  }, [])
}
