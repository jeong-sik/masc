// use-hover.ts — touch-aware hover detection
//
// Kimi design system sec01 1.5.3: useHover skips hover effects on touch devices
// by checking pointerType. Exposes hovered state via data-hovered.

import { useRef, useState } from 'preact/hooks'

export interface HoverResult {
  hovered: boolean
  hoverProps: {
    onPointerEnter: (e: PointerEvent) => void
    onPointerLeave: () => void
    'data-hovered': string | undefined
  }
}

export function useHover(): HoverResult {
  const [hovered, setHovered] = useState(false)
  const isTouch = useRef(false)
  return {
    hovered,
    hoverProps: {
      onPointerEnter: (e: PointerEvent) => {
        if (e.pointerType !== 'touch') {
          isTouch.current = false
          setHovered(true)
        } else {
          isTouch.current = true
        }
      },
      onPointerLeave: () => {
        if (!isTouch.current) setHovered(false)
      },
      'data-hovered': hovered ? 'true' : undefined,
    },
  }
}
