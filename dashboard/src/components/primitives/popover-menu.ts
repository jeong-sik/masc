/**
 * Reusable Accessible PopoverMenu Primitive.
 *
 * - Supports both structured `items` and custom `children` (or render function receiving `{ close }`).
 * - Supports uncontrolled (`defaultOpen`) and controlled (`open` + `onOpenChange`) modes.
 * - Full keyboard navigation across menu items (`ArrowDown`, `ArrowUp`, `Home`, `End`),
 *   `Escape` dismissal returning focus to trigger, and outside-click dismissal.
 */

import { html } from 'htm/preact'
import { Fragment, type ComponentChildren, type VNode } from 'preact'
import { useEffect, useId, useRef, useState } from 'preact/hooks'
import { isImeComposing } from '../../lib/keyboard'

export interface PopoverMenuItem {
  readonly id: string
  readonly label: string
  readonly description?: string
  readonly icon?: ComponentChildren
  readonly shortcut?: string
  readonly active?: boolean
  readonly disabled?: boolean
  readonly danger?: boolean
  readonly testId?: string
  readonly separatorBefore?: boolean
  readonly onSelect: () => void
}

export interface PopoverMenuControls {
  readonly close: () => void
}

export interface PopoverMenuProps {
  readonly triggerLabel: ComponentChildren
  readonly triggerIcon?: ComponentChildren
  readonly triggerClassName?: string
  readonly triggerTestId?: string
  readonly triggerTitle?: string
  readonly popoverClassName?: string
  readonly popoverTestId?: string
  readonly align?: 'left' | 'right'
  readonly ariaLabel: string
  readonly role?: 'menu' | 'dialog'
  readonly items?: readonly PopoverMenuItem[]
  readonly children?: ComponentChildren | ((controls: PopoverMenuControls) => ComponentChildren)
  readonly open?: boolean
  readonly defaultOpen?: boolean
  readonly onOpenChange?: (open: boolean) => void
  readonly closeOnSelect?: boolean
}

const MENU_ITEM_SELECTOR = [
  '[role="menuitem"]:not([disabled]):not([aria-disabled="true"])',
  '[role="menuitemradio"]:not([disabled]):not([aria-disabled="true"])',
  '[role="menuitemcheckbox"]:not([disabled]):not([aria-disabled="true"])',
  '.pm-item:not([disabled]):not([aria-disabled="true"])',
].join(', ')

function getFocusableMenuItems(root: HTMLElement | null): HTMLElement[] {
  if (!root) return []
  return Array.from(root.querySelectorAll<HTMLElement>(MENU_ITEM_SELECTOR))
}

export function PopoverMenu(props: PopoverMenuProps): VNode {
  const [uncontrolledOpen, setUncontrolledOpen] = useState(props.defaultOpen ?? false)
  const isControlled = props.open !== undefined
  const isOpen = isControlled ? props.open! : uncontrolledOpen

  const wrapRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)
  const popoverRef = useRef<HTMLDivElement>(null)
  const pendingFocusRef = useRef<'first' | 'last' | null>(null)
  const onOpenChangeRef = useRef(props.onOpenChange)
  onOpenChangeRef.current = props.onOpenChange

  const popoverId = useId()
  const menuRole = props.role ?? 'menu'
  const align = props.align ?? 'left'
  const closeOnSelect = props.closeOnSelect ?? true

  const setOpen = (next: boolean) => {
    if (!isControlled) setUncontrolledOpen(next)
    onOpenChangeRef.current?.(next)
  }

  const closeAndRestoreFocus = () => {
    setOpen(false)
    triggerRef.current?.focus?.()
  }

  useEffect(() => {
    if (!isOpen) return
    const pending = pendingFocusRef.current
    pendingFocusRef.current = null
    if (pending) {
      queueMicrotask(() => {
        const items = getFocusableMenuItems(popoverRef.current)
        if (items.length === 0) return
        const target = pending === 'last' ? items[items.length - 1] : items[0]
        target?.focus?.()
      })
    }

    const onOutsideMouseDown = (event: MouseEvent) => {
      if (wrapRef.current && !wrapRef.current.contains(event.target as Node)) {
        setOpen(false)
      }
    }

    const onDocumentKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || isImeComposing(event)) return
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        event.stopImmediatePropagation()
        closeAndRestoreFocus()
      }
    }

    document.addEventListener('mousedown', onOutsideMouseDown)
    document.addEventListener('keydown', onDocumentKeyDown, true)
    return () => {
      document.removeEventListener('mousedown', onOutsideMouseDown)
      document.removeEventListener('keydown', onDocumentKeyDown, true)
    }
  }, [isOpen])

  const onTriggerKeyDown = (event: KeyboardEvent) => {
    if (event.defaultPrevented || isImeComposing(event)) return
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      if (!isOpen) {
        pendingFocusRef.current = 'first'
        setOpen(true)
      } else {
        const items = getFocusableMenuItems(popoverRef.current)
        items[0]?.focus?.()
      }
      return
    }
    if (event.key === 'ArrowUp') {
      event.preventDefault()
      if (!isOpen) {
        pendingFocusRef.current = 'last'
        setOpen(true)
      } else {
        const items = getFocusableMenuItems(popoverRef.current)
        items[items.length - 1]?.focus?.()
      }
    }
  }

  const onPopoverKeyDown = (event: KeyboardEvent) => {
    if (event.defaultPrevented || isImeComposing(event)) return
    if (event.key === 'Escape') {
      event.preventDefault()
      event.stopPropagation()
      event.stopImmediatePropagation()
      closeAndRestoreFocus()
      return
    }
    if (event.key === 'Tab') {
      setOpen(false)
      return
    }
    if (
      event.key !== 'ArrowDown'
      && event.key !== 'ArrowUp'
      && event.key !== 'Home'
      && event.key !== 'End'
    ) {
      return
    }

    const items = getFocusableMenuItems(popoverRef.current)
    if (items.length === 0) return

    const activeEl = typeof document !== 'undefined' ? document.activeElement : null
    const currentIdx = activeEl instanceof HTMLElement ? items.indexOf(activeEl) : -1

    event.preventDefault()
    if (event.key === 'Home') {
      items[0]?.focus?.()
      return
    }
    if (event.key === 'End') {
      items[items.length - 1]?.focus?.()
      return
    }
    if (event.key === 'ArrowDown') {
      const nextIdx = currentIdx < 0 ? 0 : (currentIdx + 1) % items.length
      items[nextIdx]?.focus?.()
      return
    }
    const prevIdx = currentIdx <= 0 ? items.length - 1 : currentIdx - 1
    items[prevIdx]?.focus?.()
  }

  const renderedChildren = typeof props.children === 'function'
    ? props.children({ close: closeAndRestoreFocus })
    : props.children

  return html`
    <div class="pm-wrap" ref=${wrapRef}>
      <button
        ref=${triggerRef}
        type="button"
        class=${`pm-trigger ${props.triggerClassName ?? 'btn-ghost'}`.trim()}
        aria-haspopup=${menuRole === 'dialog' ? 'dialog' : 'menu'}
        aria-expanded=${isOpen ? 'true' : 'false'}
        aria-controls=${isOpen ? popoverId : undefined}
        aria-label=${props.ariaLabel}
        title=${props.triggerTitle ?? props.ariaLabel}
        data-testid=${props.triggerTestId}
        onClick=${() => setOpen(!isOpen)}
        onKeyDown=${onTriggerKeyDown}
      >
        ${props.triggerLabel}
        ${props.triggerIcon}
      </button>

      ${isOpen && html`
        <div
          ref=${popoverRef}
          id=${popoverId}
          class=${`pm-popover ${props.popoverClassName ?? ''}`.trim()}
          role=${menuRole}
          aria-label=${props.ariaLabel}
          data-align=${align}
          data-testid=${props.popoverTestId}
          onKeyDown=${onPopoverKeyDown}
        >
          ${props.items?.map((item) => {
            const isRadio = item.active !== undefined
            return html`
              <${Fragment} key=${item.id}>
                ${item.separatorBefore && html`<div class="pm-sep" role="separator" />`}
                <button
                  type="button"
                  role=${isRadio ? 'menuitemradio' : 'menuitem'}
                  class=${`pm-item${item.active ? ' is-active' : ''}${item.danger ? ' is-danger' : ''}`}
                  disabled=${item.disabled}
                  aria-checked=${isRadio ? (item.active ? 'true' : 'false') : undefined}
                  data-active=${item.active ? 'true' : undefined}
                  data-testid=${item.testId}
                  onClick=${() => {
                    if (item.disabled) return
                    item.onSelect()
                    if (closeOnSelect) {
                      setOpen(false)
                      if (
                        typeof document !== 'undefined'
                        && (document.activeElement === null
                          || document.activeElement === document.body
                          || wrapRef.current?.contains(document.activeElement))
                      ) {
                        triggerRef.current?.focus?.()
                      }
                    }
                  }}
                >
                  <span class="pm-item-main">
                    ${item.icon}
                    <span class="pm-item-text">
                      <span class="pm-item-label">${item.label}</span>
                      ${item.description && html`<span class="pm-item-desc">${item.description}</span>`}
                    </span>
                  </span>
                  ${item.shortcut && html`<kbd class="ap-kbd">${item.shortcut}</kbd>`}
                </button>
              <//>
            `
          })}
          ${renderedChildren}
        </div>
      `}
    </div>
  `
}
