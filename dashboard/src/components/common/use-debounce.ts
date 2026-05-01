// use-debounce.ts — delay execution until pause in input
//
// Kimi design system sec03: useDebounce is used in MemorySearch and
// other input-heavy components to reduce API call frequency.

import { useRef, useCallback } from 'preact/hooks'

export function useDebounce<T extends (...args: any[]) => void>(
  fn: T,
  delay: number
): (...args: Parameters<T>) => void {
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const debounced = useCallback(
    (...args: Parameters<T>) => {
      if (timerRef.current) {
        clearTimeout(timerRef.current)
      }
      timerRef.current = setTimeout(() => {
        fn(...args)
      }, delay)
    },
    [fn, delay]
  )

  return debounced
}
