// use-resize-observer.ts — observe element size changes
//
// Kimi design system sec01 1.5: useResizeObserver powers responsive
// layouts and virtualized lists.

import { useState, useEffect, useRef } from 'preact/hooks'

export interface Size {
  width: number
  height: number
}

export function useResizeObserver<T extends HTMLElement = HTMLElement>(): {
  ref: { current: T | null }
  size: Size
} {
  const ref = useRef<T | null>(null)
  const [size, setSize] = useState<Size>({ width: 0, height: 0 })

  useEffect(() => {
    const el = ref.current
    if (!el) return

    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const cr = entry.contentRect
        setSize({ width: cr.width, height: cr.height })
      }
    })

    observer.observe(el)
    return () => observer.disconnect()
  }, [])

  return { ref, size }
}
