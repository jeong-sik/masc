// use-long-press.ts — long press detection for ContextMenu
//
// Kimi design system sec01 1.5: useLongPress fires after 500ms+ press.
// Touch and mouse supported. Cancels on pointerleave.

import { useRef, useState, useCallback } from 'preact/hooks'

export interface LongPressResult {
  pressing: boolean
  longPressProps: {
    onPointerDown: (e: PointerEvent) => void
    onPointerUp: () => void
    onPointerLeave: () => void
    'data-pressing': string | undefined
  }
}

export interface LongPressOptions {
  threshold?: number
  onLongPress?: () => void
}

export function useLongPress({
  threshold = 500,
  onLongPress,
}: LongPressOptions = {}): LongPressResult {
  const [pressing, setPressing] = useState(false)
  const timer = useRef<number | null>(null)
  const triggered = useRef(false)

  const clear = useCallback(() => {
    if (timer.current !== null) {
      window.clearTimeout(timer.current)
      timer.current = null
    }
    triggered.current = false
    setPressing(false)
  }, [])

  const handlePointerDown = useCallback(
    (e: PointerEvent) => {
      if (e.button !== 0) return
      triggered.current = false
      setPressing(true)
      timer.current = window.setTimeout(() => {
        triggered.current = true
        onLongPress?.()
      }, threshold)
    },
    [threshold, onLongPress]
  )

  const handlePointerUp = useCallback(() => {
    clear()
  }, [clear])

  const handlePointerLeave = useCallback(() => {
    clear()
  }, [clear])

  return {
    pressing,
    longPressProps: {
      onPointerDown: handlePointerDown,
      onPointerUp: handlePointerUp,
      onPointerLeave: handlePointerLeave,
      'data-pressing': pressing ? 'true' : undefined,
    },
  }
}
