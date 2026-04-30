// use-focus-ring.ts — keyboard-focus-only visual ring
//
// Kimi design system sec01 1.5.2: useFocusRing distinguishes keyboard focus
// (focus-visible) from mouse focus. Exposes data-focused / data-focus-visible.

import { useState } from 'preact/hooks'

export interface FocusRingResult {
  focused: boolean
  focusVisible: boolean
  focusRingProps: {
    onFocus: (e: FocusEvent) => void
    onBlur: () => void
    'data-focused': string | undefined
    'data-focus-visible': string | undefined
  }
}

export function useFocusRing(): FocusRingResult {
  const [focused, setFocused] = useState(false)
  const [focusVisible, setFocusVisible] = useState(false)
  return {
    focused,
    focusVisible,
    focusRingProps: {
      onFocus: (e: FocusEvent) => {
        setFocused(true)
        const related = e.relatedTarget as HTMLElement | null
        setFocusVisible(!related || related.tabIndex === -1)
      },
      onBlur: () => {
        setFocused(false)
        setFocusVisible(false)
      },
      'data-focused': focused ? 'true' : undefined,
      'data-focus-visible': focusVisible ? 'true' : undefined,
    },
  }
}
