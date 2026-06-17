import { useEffect, useState } from 'preact/hooks'

export interface UseIsMobileOptions {
  /**
   * Viewport width threshold in pixels. Widths at or below this value are
   * considered mobile. Defaults to 760px to align with the dashboard's
   * mobile chrome breakpoint.
   */
  breakpoint?: number
}

/**
 * Tracks whether the viewport width is at or below the given breakpoint.
 * Defaults to 760px. Safe to call in SSR / test environments where
   * `window` may be undefined.
 */
export function useIsMobile(options: UseIsMobileOptions = {}): boolean {
  const { breakpoint = 760 } = options

  const [isMobile, setIsMobile] = useState<boolean>(() => {
    if (typeof window === 'undefined') return false
    return window.innerWidth <= breakpoint
  })

  useEffect(() => {
    if (typeof window === 'undefined') return

    const update = () => {
      setIsMobile(window.innerWidth <= breakpoint)
    }

    update()
    window.addEventListener('resize', update)
    return () => window.removeEventListener('resize', update)
  }, [breakpoint])

  return isMobile
}
