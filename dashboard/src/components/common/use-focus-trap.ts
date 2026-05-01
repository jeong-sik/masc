// use-focus-trap.ts — Preact hook wrapping createFocusScope
//
// Kimi design system sec07 7.1.1 / sec08 8.1.2: useFocusTrap encapsulates
// focus scope creation, Escape handling, and focus restoration.
// Returns a ref and props to spread on the container element.

import { useEffect, useRef } from 'preact/hooks'
import { createFocusScope } from './focus-scope'

export interface UseFocusTrapOptions {
  active: boolean
  onClose?: () => void
  restoreFocus?: boolean
}

export interface FocusTrapResult {
  ref: { current: HTMLElement | null }
  focusTrapProps: {
    tabIndex: number
    'data-focus-trap': string | undefined
  }
}

export function useFocusTrap({
  active,
  onClose,
  restoreFocus = true,
}: UseFocusTrapOptions): FocusTrapResult {
  const containerRef = useRef<HTMLElement | null>(null)
  const previouslyFocusedRef = useRef<HTMLElement | null>(null)

  useEffect(() => {
    if (!active || !containerRef.current) return

    previouslyFocusedRef.current = document.activeElement as HTMLElement | null
    const scope = createFocusScope(containerRef.current)
    scope.focusFirst()

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose?.()
        return
      }
      scope.cycle(e)
    }

    const el = containerRef.current
    el.addEventListener('keydown', handleKeyDown)
    return () => {
      el.removeEventListener('keydown', handleKeyDown)
      if (restoreFocus) previouslyFocusedRef.current?.focus()
    }
  }, [active, onClose, restoreFocus])

  return {
    ref: containerRef,
    focusTrapProps: {
      tabIndex: -1,
      'data-focus-trap': active ? 'true' : undefined,
    },
  }
}
