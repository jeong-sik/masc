// use-intersection-observer.ts — detect element visibility in viewport
//
// Kimi design system sec01 1.5: useIntersectionObserver enables
// lazy loading and scroll-triggered animations.

import { useState, useEffect, useRef } from 'preact/hooks'

export interface IntersectionOptions {
  threshold?: number | number[]
  rootMargin?: string
  root?: HTMLElement | null
}

export function useIntersectionObserver<T extends HTMLElement = HTMLElement>(
  options: IntersectionOptions = {}
): {
  ref: { current: T | null }
  isIntersecting: boolean
  entry: IntersectionObserverEntry | null
} {
  const ref = useRef<T | null>(null)
  const [entry, setEntry] = useState<IntersectionObserverEntry | null>(null)

  useEffect(() => {
    const el = ref.current
    if (!el) return

    const observer = new IntersectionObserver(
      ([observedEntry]) => {
        if (observedEntry) setEntry(observedEntry)
      },
      {
        threshold: options.threshold,
        rootMargin: options.rootMargin,
        root: options.root,
      }
    )

    observer.observe(el)
    return () => observer.disconnect()
  }, [options.threshold, options.rootMargin, options.root])

  return {
    ref,
    isIntersecting: entry?.isIntersecting ?? false,
    entry,
  }
}
