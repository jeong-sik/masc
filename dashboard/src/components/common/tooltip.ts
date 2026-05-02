// Tooltip — ARIA tooltip atom (sec06 6.1.1).
// Uses role="tooltip" + aria-describedby linkage.
// Trigger events are composed so existing handlers are preserved.

import { cloneElement } from 'preact'
import { html } from 'htm/preact'
import { useCallback, useEffect, useId, useRef, useState } from 'preact/hooks'
import type { ComponentChildren, FunctionComponent, VNode } from 'preact'

interface TooltipProps {
  children?: ComponentChildren
  content: string
  testId?: string
}

function compose<T extends Event>(a?: (e: T) => void, b?: (e: T) => void) {
  return (e: T) => {
    a?.(e)
    b?.(e)
  }
}

function isVNode(child: ComponentChildren): child is VNode {
  return typeof child === 'object' && child !== null && 'props' in child && 'type' in child
}

export const Tooltip: FunctionComponent<TooltipProps> = ({ children, content, testId }) => {
  const id = useId()
  const [visible, setVisible] = useState(false)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const show = useCallback(() => {
    if (timerRef.current) clearTimeout(timerRef.current)
    timerRef.current = setTimeout(() => setVisible(true), 150)
  }, [])

  const hide = useCallback(() => {
    if (timerRef.current) clearTimeout(timerRef.current)
    timerRef.current = setTimeout(() => setVisible(false), 50)
  }, [])

  const onKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === 'Escape') hide()
    },
    [hide],
  )

  useEffect(() => {
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current)
    }
  }, [])

  if (!isVNode(children)) return null

  const childProps = (children.props as Record<string, unknown>) || {}
  const trigger = cloneElement(children, {
    'aria-describedby': visible ? id : undefined,
    onMouseEnter: compose(
      childProps.onMouseEnter as (e: MouseEvent) => void,
      show,
    ),
    onMouseLeave: compose(
      childProps.onMouseLeave as (e: MouseEvent) => void,
      hide,
    ),
    onFocus: compose(childProps.onFocus as (e: FocusEvent) => void, show),
    onBlur: compose(childProps.onBlur as (e: FocusEvent) => void, hide),
    onKeyDown: compose(
      childProps.onKeyDown as (e: KeyboardEvent) => void,
      onKeyDown,
    ),
  })

  return html`
    <span class="relative inline-flex">
      ${trigger}
      ${visible
        ? html`<span
            id=${id}
            role="tooltip"
            data-testid=${testId}
            class="absolute bottom-full left-1/2 z-50 mb-1 -translate-x-1/2 whitespace-nowrap rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-xs text-[var(--color-fg-primary)] shadow-lg"
          >${content}</span>`
        : null}
    </span>
  `
}
