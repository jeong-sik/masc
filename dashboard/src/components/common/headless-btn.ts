// HeadlessBtn — headless button primitive with press / focus / hover states.
//
// Kimi design system sec01 1.5: usePress + useFocusRing + useHover hooks.
// Exposes state through data-attributes so Tailwind data-[state] selectors
// can style without prop-drilling. Touch-device hover is skipped.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { usePress } from './use-press'
import { useFocusRing } from './use-focus-ring'
import { useHover } from './use-hover'

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
  const hoverCls = hovered && !pressed ? 'bg-[var(--color-bg-elevated)]' : ''
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
