// HeadlessBtn — headless button primitive with press / focus / hover states.
//
// Kimi design system sec01 1.5: usePress + useFocusRing + useHover hooks.
// Exposes state through data-attributes so Tailwind data-[state] selectors
// can style without prop-drilling. Touch-device hover is skipped.

import { html } from 'htm/preact'
import { useRef, useState } from 'preact/hooks'
import type { ComponentChildren } from 'preact'

// ── Hooks ──

interface PressResult {
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

function usePress(onPress?: () => void): PressResult {
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

interface FocusRingResult {
  focused: boolean
  focusVisible: boolean
  focusRingProps: {
    onFocus: (e: FocusEvent) => void
    onBlur: () => void
    'data-focused': string | undefined
    'data-focus-visible': string | undefined
  }
}

function useFocusRing(): FocusRingResult {
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

interface HoverResult {
  hovered: boolean
  hoverProps: {
    onPointerEnter: (e: PointerEvent) => void
    onPointerLeave: () => void
    'data-hovered': string | undefined
  }
}

function useHover(): HoverResult {
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

// ── Component ──

interface HeadlessBtnProps {
  children: ComponentChildren
  onPress?: () => void
  class?: string
  ariaLabel?: string
  disabled?: boolean
  testId?: string
}

export function HeadlessBtn({
  children,
  onPress,
  class: cx,
  ariaLabel,
  disabled,
  testId,
}: HeadlessBtnProps) {
  const { pressProps, pressed } = usePress(disabled ? undefined : onPress)
  const { focusRingProps, focusVisible } = useFocusRing()
  const { hoverProps, hovered } = useHover()

  // Precompute class string — htm/preact forbids `+` inside html`` templates.
  const base =
    'inline-flex items-center justify-center rounded-md px-3 py-1.5 text-sm font-medium transition-all'
  const focusCls = focusVisible
    ? 'ring-2 ring-[var(--color-accent)] ring-offset-2 ring-offset-[var(--color-bg-surface)]'
    : ''
  const hoverCls = hovered && !pressed ? 'bg-[var(--white-4)]' : ''
  const pressedCls = pressed ? 'scale-95 opacity-80' : ''
  const disabledCls = disabled ? 'opacity-50 pointer-events-none' : ''

  const cls = [base, focusCls, hoverCls, pressedCls, disabledCls, cx]
    .filter(Boolean)
    .join(' ')

  return html`
    <button
      class=${cls}
      aria-label=${ariaLabel}
      disabled=${disabled}
      data-testid=${testId}
      data-headless-btn
      data-pressed=${pressed ? 'true' : undefined}
      data-focused=${focusVisible ? 'true' : undefined}
      data-hovered=${hovered ? 'true' : undefined}
      ...${pressProps}
      ...${focusRingProps}
      ...${hoverProps}
    >
      ${children}
    </button>
  `
}
