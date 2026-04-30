// use-press.ts — touch/mouse/keyboard unified press detection
//
// Kimi design system sec01 1.5.1: usePress abstracts mousedown/touchstart/keydown
// into a single onPress callback. Exposes pressed state via data-pressed.

import { useState } from 'preact/hooks'

export interface PressResult {
  pressed: boolean
  pressProps: {
    onPointerDown: () => void
    onPointerUp: () => void
    onPointerLeave: () => void
    onKeyDown: (e: KeyboardEvent) => void
    onKeyUp: (e: KeyboardEvent) => void
    'data-pressed': string | undefined
  }
}

export function usePress(onPress?: () => void): PressResult {
  const [pressed, setPressed] = useState(false)
  return {
    pressed,
    pressProps: {
      onPointerDown: () => setPressed(true),
      onPointerUp: () => {
        setPressed(false)
        onPress?.()
      },
      onPointerLeave: () => setPressed(false),
      onKeyDown: (e: KeyboardEvent) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          setPressed(true)
        }
      },
      onKeyUp: (e: KeyboardEvent) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          setPressed(false)
          onPress?.()
        }
      },
      'data-pressed': pressed ? 'true' : undefined,
    },
  }
}
