// use-media-query.ts — reactive CSS media query hook
//
// Kimi design system sec01 1.5: useMediaQuery enables responsive
// behavior in headless primitives (e.g. collapsible sidebar).

import { useState, useEffect } from 'preact/hooks'

export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(() => {
    if (typeof window === 'undefined') return false
    return window.matchMedia(query).matches
  })

  useEffect(() => {
    const mql = window.matchMedia(query)
    const handler = (e: MediaQueryListEvent) => setMatches(e.matches)
    setMatches(mql.matches)
    mql.addEventListener('change', handler)
    return () => mql.removeEventListener('change', handler)
  }, [query])

  return matches
}
