import { useEffect, useState } from 'preact/hooks'

export interface UseIsMobileOptions {
  /**
   * Viewport width threshold in pixels. Widths at or below this value are
   * considered mobile. Defaults to 767px so tablet/desktop viewports (`>=768px`)
   * keep the rail layout per the 360 / 768 / 1024 / 1440 breakpoint ladder.
   */
  breakpoint?: number
}

export const DEFAULT_MOBILE_BREAKPOINT = 767

/**
 * Tracks whether the viewport width is at or below the given breakpoint.
 * Defaults to 767px (`<768px` mobile). Safe to call in SSR / test environments where
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
