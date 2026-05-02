// Popover — non-modal floating panel primitive
// Kimi sec09 Phase 1: Headless Popover. Distinct from Dialog (modal) and
// Tooltip (hover-only). Popover is click-triggered, non-modal, and may
// contain interactive content.
//
// ARIA: trigger has aria-haspopup="dialog", aria-expanded, aria-controls.
// Panel has role="dialog" without aria-modal.

import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'
import { useEffect, useId, useLayoutEffect, useRef, useState } from 'preact/hooks'
import { cloneElement } from 'preact'

interface PopoverProps {
  /** The trigger element — must be a single VNode. */
  trigger: VNode
  children: ComponentChildren
  /** Preferred placement. Only "bottom" implemented; others fall back. */
  placement?: 'bottom' | 'top' | 'left' | 'right'
  /** Called when the popover requests to close (ESC, outside click). */
  onClose?: () => void
  testId?: string
  /** Accessible name for the popover panel. */
  'aria-label'?: string
}

export function Popover({
  trigger,
  children,
  placement = 'bottom',
  onClose,
  testId,
  'aria-label': ariaLabel,
}: PopoverProps) {
  const id = useId()
  const [open, setOpen] = useState(false)
  const panelRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLElement>(null)

  const toggle = () => {
    setOpen((prev) => {
      if (prev && onClose) onClose()
      return !prev
    })
  }

  const close = () => {
    setOpen(false)
    onClose?.()
  }

  // Click outside to dismiss
  useEffect(() => {
    if (!open) return
    const onDocClick = (e: MouseEvent) => {
      const target = e.target as Node
      if (
        panelRef.current?.contains(target) ||
        triggerRef.current?.contains(target)
      ) {
        return
      }
      close()
    }
    document.addEventListener('click', onDocClick, true)
    return () => document.removeEventListener('click', onDocClick, true)
  }, [open])

  // ESC to close
  useLayoutEffect(() => {
    if (!open) return
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        close()
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [open])

  const childProps = (trigger.props as Record<string, unknown>) || {}

  const triggerNode = cloneElement(trigger, {
    'aria-haspopup': 'dialog',
    'aria-expanded': open,
    'aria-controls': open ? id : undefined,
    ref: triggerRef,
    onClick: (e: MouseEvent) => {
      ;(childProps.onClick as ((e: MouseEvent) => void) | undefined)?.(e)
      toggle()
    },
  })

  const placementCls =
    placement === 'top'
      ? 'bottom-full mb-1'
      : placement === 'left'
        ? 'right-full mr-1'
        : placement === 'right'
          ? 'left-full ml-1'
          : 'top-full mt-1'

  return html`
    <div class="relative inline-block">
      ${triggerNode}
      ${open
        ? html`<div
            ref=${panelRef}
            id=${id}
            role="dialog"
            aria-label=${ariaLabel}
            data-testid=${testId}
            class=${
              'absolute z-50 ' +
              placementCls +
              ' left-0 min-w-48 max-w-80 ' +
              'bg-[var(--dialog-panel-bg)] rounded-md ' +
              'border border-[var(--dialog-panel-border)] ' +
              'shadow-[var(--shadow-panel)] p-3'
            }
          >
            ${children}
          </div>`
        : null}
    </div>
  `
}
