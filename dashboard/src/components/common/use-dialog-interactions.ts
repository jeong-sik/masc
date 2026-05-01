// use-dialog-interactions.ts — integrated dialog hook (focus trap + ESC + scroll lock)
//
// Kimi design system sec01 1.2.3: useDialogInteractions combines focus trap,
// Escape key handling, scroll lock, and focus restoration for modal dialogs.

import { useEffect, useRef, useCallback } from 'preact/hooks'
import { createFocusScope } from './focus-scope'

export interface UseDialogInteractionsOptions {
  open: boolean
  onClose?: () => void
  restoreFocus?: boolean
}

export interface DialogInteractionsResult {
  ref: { current: HTMLElement | null }
  dialogProps: {
    role: 'dialog'
    'aria-modal': 'true'
    'data-state': 'open' | 'closed'
    tabIndex: number
  }
}

export function useDialogInteractions({
  open,
  onClose,
  restoreFocus = true,
}: UseDialogInteractionsOptions): DialogInteractionsResult {
  const containerRef = useRef<HTMLElement | null>(null)
  const previouslyFocusedRef = useRef<HTMLElement | null>(null)
  const scrollYRef = useRef<number>(0)

  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose?.()
        return
      }
      const el = containerRef.current
      if (!el) return
      const scope = createFocusScope(el)
      scope.cycle(e)
    },
    [onClose]
  )

  useEffect(() => {
    if (!open || !containerRef.current) return

    previouslyFocusedRef.current = document.activeElement as HTMLElement | null
    scrollYRef.current = window.scrollY

    const scope = createFocusScope(containerRef.current)
    scope.focusFirst()

    document.body.style.position = 'fixed'
    document.body.style.top = `-${scrollYRef.current}px`
    document.body.style.left = '0'
    document.body.style.right = '0'

    const el = containerRef.current
    el.addEventListener('keydown', handleKeyDown)

    return () => {
      el.removeEventListener('keydown', handleKeyDown)
      document.body.style.position = ''
      document.body.style.top = ''
      document.body.style.left = ''
      document.body.style.right = ''
      window.scrollTo(0, scrollYRef.current)
      if (restoreFocus) previouslyFocusedRef.current?.focus()
    }
  }, [open, handleKeyDown, restoreFocus])

  return {
    ref: containerRef,
    dialogProps: {
      role: 'dialog',
      'aria-modal': 'true',
      'data-state': open ? 'open' : 'closed',
      tabIndex: -1,
    },
  }
}
