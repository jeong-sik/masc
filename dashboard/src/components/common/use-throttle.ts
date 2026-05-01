// use-throttle.ts — limit execution to at most once per interval
//
// Kimi design system sec01 1.5: useThrottle limits high-frequency
// events (scroll, resize) to a fixed cadence.

import { useRef, useCallback } from 'preact/hooks'

export function useThrottle<T extends (...args: any[]) => void>(
  fn: T,
  interval: number
): (...args: Parameters<T>) => void {
  const lastRunRef = useRef<number>(0)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const throttled = useCallback(
    (...args: Parameters<T>) => {
      const now = Date.now()
      const elapsed = now - lastRunRef.current

      if (elapsed >= interval) {
        lastRunRef.current = now
        fn(...args)
      } else if (!timerRef.current) {
        timerRef.current = setTimeout(() => {
          lastRunRef.current = Date.now()
          timerRef.current = null
          fn(...args)
        }, interval - elapsed)
      }
    },
    [fn, interval]
  )

  return throttled
}
