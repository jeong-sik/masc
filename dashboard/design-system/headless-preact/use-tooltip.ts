/**
 * useTooltip — Preact adapter over headless-core/Tooltip + TooltipManager.
 *
 * Per RFC 0006 §3.3. Returns prop bundles for trigger and content
 * elements plus an `isOpen` boolean for conditional rendering. The
 * adapter:
 *   - Lazily creates the controller on first render
 *   - Subscribes to open/close changes and bumps a render counter
 *   - Calls destroy() on unmount (clears timers, unregisters from
 *     manager)
 *   - Generates a stable id via headless-core/IdGenerator if the
 *     caller doesn't supply one (matches use-id.ts pattern)
 *
 * Consumer renders the tooltip body inside a usePortal({ layer:
 * 'dropdown' }) tree to keep it above sticky chrome but below modals.
 */

import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  createTooltip,
  type TooltipController,
  type TooltipKeyEvent,
  type TooltipPlacement,
} from '../headless-core/tooltip'
import type { TooltipManager } from '../headless-core/tooltip-manager'
import { useId } from './use-id'

export interface UseTooltipArgs {
  /** Stable id for aria-describedby. If omitted, allocated via useId. */
  id?: string
  showDelay?: number
  hideDelay?: number
  placement?: TooltipPlacement
  /** Optional one-at-a-time manager; pass via Preact context. */
  manager?: TooltipManager
  /** Controlled mode: parent owns open. */
  open?: boolean
  onOpenChange?: (open: boolean) => void
}

export interface UseTooltipResult {
  readonly isOpen: boolean
  readonly id: string
  readonly placement: TooltipPlacement
  /** Spread onto the trigger element (button, link, etc.). */
  triggerProps: {
    readonly 'aria-describedby': string | undefined
    readonly onMouseEnter: () => void
    readonly onMouseLeave: () => void
    readonly onFocus: () => void
    readonly onBlur: () => void
    readonly onKeyDown: (e: TooltipKeyEvent) => void
  }
  /** Spread onto the content / bubble element. */
  contentProps: {
    readonly id: string
    readonly role: 'tooltip'
    readonly 'data-placement': TooltipPlacement
    readonly 'data-state': 'open' | 'closed'
    readonly onMouseEnter: () => void
    readonly onMouseLeave: () => void
  }
  show: () => void
  hide: () => void
}

export function useTooltip(args: UseTooltipArgs = {}): UseTooltipResult {
  const fallbackId = useId()
  const id = args.id ?? `tip-${fallbackId}`
  const placement = args.placement ?? 'top'

  const controllerRef = useRef<TooltipController | null>(null)
  const [, bumpState] = useState(0)

  if (controllerRef.current === null) {
    controllerRef.current = createTooltip({
      id,
      showDelay: args.showDelay,
      hideDelay: args.hideDelay,
      placement,
      manager: args.manager,
      open: args.open,
      onOpenChange: args.onOpenChange,
    })
  }

  // Subscribe once.
  useEffect(() => {
    const controller = controllerRef.current
    if (controller === null) return undefined
    const dispose = controller.subscribe(() => {
      bumpState((n) => n + 1)
    })
    return () => {
      dispose()
      controller.destroy()
    }
  }, [])

  const result = useMemo<UseTooltipResult>(() => {
    const controller = controllerRef.current!
    return {
      get isOpen() {
        return controller.isOpen
      },
      get id() {
        return controller.id
      },
      placement,
      triggerProps: {
        get 'aria-describedby'() {
          return controller.isOpen ? controller.id : undefined
        },
        onMouseEnter: () => controller.handleTriggerMouseEnter(),
        onMouseLeave: () => controller.handleTriggerMouseLeave(),
        onFocus: () => controller.handleTriggerFocus(),
        onBlur: () => controller.handleTriggerBlur(),
        onKeyDown: (e: TooltipKeyEvent) => controller.handleTriggerKeyDown(e),
      },
      contentProps: {
        id,
        role: 'tooltip',
        'data-placement': placement,
        get 'data-state'(): 'open' | 'closed' {
          return controller.isOpen ? 'open' : 'closed'
        },
        onMouseEnter: () => controller.handleContentMouseEnter(),
        onMouseLeave: () => controller.handleContentMouseLeave(),
      },
      show: () => controller.show(),
      hide: () => controller.hide(),
    }
  }, [id, placement])

  return result
}
