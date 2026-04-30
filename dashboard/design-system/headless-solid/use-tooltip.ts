/**
 * useTooltip — SolidJS adapter over headless-core/Tooltip + TooltipManager
 * (RFC 0006 §3.3, RFC 0017 PR #2.4).
 *
 * Returns prop bundles for trigger + content elements plus an `isOpen`
 * accessor. Lifecycle:
 *   - Controller created in the hook body (inside createRoot scope)
 *   - subscribe → setSignal on open/close changes
 *   - onCleanup releases subscription AND calls controller.destroy()
 *     (clears timers, unregisters from manager)
 *
 * Consumer renders the tooltip body inside a `usePortal({ layer:
 * 'dropdown' })` tree.
 */

import { createSignal, createUniqueId, onCleanup, type Accessor } from 'solid-js'
import {
  createTooltip,
  type TooltipKeyEvent,
  type TooltipPlacement,
} from '../headless-core/tooltip'
import type { TooltipManager } from '../headless-core/tooltip-manager'

export interface UseTooltipArgs {
  /** Stable id for aria-describedby. If omitted, allocated via createUniqueId. */
  id?: string
  showDelay?: number
  hideDelay?: number
  placement?: TooltipPlacement
  /** Optional one-at-a-time manager; typically passed via Solid context. */
  manager?: TooltipManager
  /** Controlled mode: parent owns open. */
  open?: boolean
  onOpenChange?: (open: boolean) => void
}

export interface UseTooltipResult {
  readonly isOpen: Accessor<boolean>
  readonly id: string
  readonly placement: TooltipPlacement
  /** Spread onto the trigger element (button, link, etc.). */
  triggerProps: {
    readonly 'aria-describedby': Accessor<string | undefined>
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
    readonly 'data-state': Accessor<'open' | 'closed'>
    readonly onMouseEnter: () => void
    readonly onMouseLeave: () => void
  }
  show: () => void
  hide: () => void
}

export function useTooltip(args: UseTooltipArgs = {}): UseTooltipResult {
  const fallbackId = createUniqueId()
  const id = args.id ?? `tip-${fallbackId}`
  const placement = args.placement ?? 'top'

  const controller = createTooltip({
    id,
    showDelay: args.showDelay,
    hideDelay: args.hideDelay,
    placement,
    manager: args.manager,
    open: args.open,
    onOpenChange: args.onOpenChange,
  })

  const [isOpen, setIsOpen] = createSignal<boolean>(controller.isOpen)
  const dispose = controller.subscribe(() => setIsOpen(controller.isOpen))
  onCleanup(() => {
    dispose()
    controller.destroy()
  })

  return {
    isOpen,
    id,
    placement,
    triggerProps: {
      'aria-describedby': () => (isOpen() ? id : undefined),
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
      'data-state': () => (isOpen() ? 'open' : 'closed'),
      onMouseEnter: () => controller.handleContentMouseEnter(),
      onMouseLeave: () => controller.handleContentMouseLeave(),
    },
    show: () => controller.show(),
    hide: () => controller.hide(),
  }
}
