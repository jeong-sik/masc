/**
 * Tooltip — framework-agnostic hover-hint primitive (RFC 0006).
 *
 * Replaces inline mouseenter/leave/focus/blur + setTimeout patterns
 * scattered across button hint surfaces. Pairs with the singleton
 * TooltipManager (tooltip-manager.ts) which enforces one-at-a-time
 * across the whole app.
 *
 * MVP scope (RFC 0006 §3, §4):
 *   - showDelay (default 300 ms) / hideDelay (default 0 ms)
 *   - mouse + focus + Esc lifecycle
 *   - content hover cancels pending hide (re-enter from trigger →
 *     content path)
 *   - controlled mode via opts.open (parent owns isOpen)
 *   - destroy() clears all timers and unregisters from manager
 *
 * No DOM access. Pure TS. The adapter (use-tooltip.ts) wires DOM
 * events to the handler methods and renders a portal-mounted bubble.
 *
 * The tooltip body content does NOT receive focus. The trigger keeps
 * focus. Esc on the trigger closes immediately.
 */

import type { TooltipManager } from './tooltip-manager'

export type TooltipPlacement = 'top' | 'bottom' | 'left' | 'right'

export interface TooltipOptions {
  /** ms before showing on hover/focus. Default 300. */
  showDelay?: number
  /** ms before hiding on leave/blur. Default 0 (immediate). */
  hideDelay?: number
  /** Hint for placement; consumer applies via CSS. */
  placement?: TooltipPlacement
  /** Stable id for aria-describedby linkage. Required. */
  id: string
  /** Optional manager reference for one-at-a-time enforcement. */
  manager?: TooltipManager
  /** Controlled mode: parent owns isOpen state. */
  open?: boolean
  /** Fires on open / close. */
  onOpenChange?: (open: boolean) => void
}

export interface TooltipKeyEvent {
  readonly key: string
  preventDefault(): void
}

export interface TooltipController {
  readonly isOpen: boolean
  readonly id: string

  show(): void
  hide(): void

  // Trigger-side handlers
  handleTriggerMouseEnter(): void
  handleTriggerMouseLeave(): void
  handleTriggerFocus(): void
  handleTriggerBlur(): void
  handleTriggerKeyDown(e: TooltipKeyEvent): void

  // Content-side handlers
  handleContentMouseEnter(): void
  handleContentMouseLeave(): void

  subscribe(listener: (open: boolean) => void): () => void
  destroy(): void
}

const DEFAULT_SHOW_DELAY_MS = 300
const DEFAULT_HIDE_DELAY_MS = 0

export function createTooltip(opts: TooltipOptions): TooltipController {
  const showDelay = opts.showDelay ?? DEFAULT_SHOW_DELAY_MS
  const hideDelay = opts.hideDelay ?? DEFAULT_HIDE_DELAY_MS
  const controlled = opts.open !== undefined

  let isOpen = opts.open === true
  let showTimer: ReturnType<typeof setTimeout> | null = null
  let hideTimer: ReturnType<typeof setTimeout> | null = null

  const listeners = new Set<(open: boolean) => void>()

  function clearShowTimer(): void {
    if (showTimer !== null) {
      clearTimeout(showTimer)
      showTimer = null
    }
  }

  function clearHideTimer(): void {
    if (hideTimer !== null) {
      clearTimeout(hideTimer)
      hideTimer = null
    }
  }

  function broadcast(value: boolean): void {
    for (const listener of listeners) listener(value)
    if (opts.onOpenChange !== undefined) opts.onOpenChange(value)
  }

  function setOpen(next: boolean): void {
    if (controlled) {
      // Controlled mode: only parent flips state via opts.open updates;
      // primitive still signals onOpenChange so parent can react.
      // Send the *requested* next value (not the unchanged isOpen).
      if (next !== isOpen) broadcast(next)
      return
    }
    if (next === isOpen) return
    isOpen = next
    if (opts.manager !== undefined) {
      if (next) opts.manager.notifyOpened(controller)
      else opts.manager.notifyClosed(controller)
    }
    broadcast(isOpen)
  }

  // The controller object is created below; we declare it here as a
  // mutable holder so the manager-notify call above can reference it.
  let controller: TooltipController

  function showNow(): void {
    setOpen(true)
  }

  function hideNow(): void {
    setOpen(false)
  }

  function startShowTimer(): void {
    clearHideTimer()
    if (isOpen || showTimer !== null) return
    if (showDelay <= 0) {
      showNow()
      return
    }
    showTimer = setTimeout(() => {
      showTimer = null
      showNow()
    }, showDelay)
  }

  function startHideTimer(): void {
    clearShowTimer()
    if (!isOpen || hideTimer !== null) return
    if (hideDelay <= 0) {
      hideNow()
      return
    }
    hideTimer = setTimeout(() => {
      hideTimer = null
      hideNow()
    }, hideDelay)
  }

  controller = {
    get isOpen() {
      return isOpen
    },
    get id() {
      return opts.id
    },

    show(): void {
      clearShowTimer()
      clearHideTimer()
      showNow()
    },

    hide(): void {
      clearShowTimer()
      clearHideTimer()
      hideNow()
    },

    handleTriggerMouseEnter(): void {
      startShowTimer()
    },

    handleTriggerMouseLeave(): void {
      startHideTimer()
    },

    handleTriggerFocus(): void {
      startShowTimer()
    },

    handleTriggerBlur(): void {
      startHideTimer()
    },

    handleTriggerKeyDown(e: TooltipKeyEvent): void {
      if (e.key === 'Escape' && isOpen) {
        e.preventDefault()
        clearShowTimer()
        clearHideTimer()
        hideNow()
      }
    },

    handleContentMouseEnter(): void {
      // User moved into the tooltip content — cancel any pending hide.
      clearHideTimer()
    },

    handleContentMouseLeave(): void {
      startHideTimer()
    },

    subscribe(listener: (open: boolean) => void): () => void {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },

    destroy(): void {
      clearShowTimer()
      clearHideTimer()
      if (isOpen) {
        isOpen = false
        broadcast(false)
      }
      listeners.clear()
      if (opts.manager !== undefined) {
        opts.manager.notifyClosed(controller)
      }
    },
  }

  // Initial open state could already be true (controlled). If so, the
  // manager wants to know — but only if it knows about us.
  if (isOpen && opts.manager !== undefined) {
    opts.manager.notifyOpened(controller)
  }

  return controller
}
