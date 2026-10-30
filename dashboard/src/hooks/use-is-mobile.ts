import { useEffect, useState } from 'preact/hooks'

export interface UseIsMobileOptions {
  /**
   * Viewport width threshold in pixels. Widths at or below this value are
   * considered mobile. Defaults to 900px to align with the keeper-v2 shell
   * rail/bottom-tab breakpoint.
   */
  breakpoint?: number
}

export const DEFAULT_MOBILE_BREAKPOINT = 900

/**
 * Tracks whether the viewport width is at or below the given breakpoint.
 * Defaults to 900px. Safe to call in SSR / test environments where
 * `window` may be undefined.
 */
export function useIsMobile(options: UseIsMobileOptions = {}): boolean {
  const { breakpoint = DEFAULT_MOBILE_BREAKPOINT } = options

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
