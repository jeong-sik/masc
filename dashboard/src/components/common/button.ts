// ActionButton — reusable button with variant styles
// Replaces repeated inline button patterns across dashboard.
//
// Props are a strict whitelist — htm/preact function components do not
// implicitly spread unlisted props to children (see the parallel note
// in ../common/input.ts). If you want a new attribute to reach the
// <button>, add it to the interface AND forward it below. Missing
// entries silently drop, which is how the pre-refactor callers that
// passed `aria-busy` / `data-*` ended up rendering plain buttons and
// forced a couple of sites to fall back to raw <button>.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { ringFocusClasses } from './ring'

type ButtonVariant = 'primary' | 'ghost' | 'danger' | 'subtle' | 'ok' | 'warn'
type ButtonSize = 'sm' | 'md' | 'lg'
type ButtonType = 'button' | 'submit' | 'reset'

const SIZE_CLASSES: Record<ButtonSize, string> = {
  sm: 'py-1 px-2 text-2xs',
  md: 'py-1.5 px-2.5 text-2xs',
  lg: 'py-2 px-4 text-sm',
}

// Component-level token slots (button-{variant}-bg/fg/border/bg-hover/bg-pressed).
// Defined in dashboard/design-system/tokens/source.ts §"Component-level role
// tokens". Each alias resolves to the same hex via var() chain; swapping
// the slot at the token layer (e.g. shipping a brand re-skin) propagates
// here without touching this file.
//
// subtle/warn keep inline literals — their token slots haven't been
// authored yet (see #11876 follow-up). When they land, swap inline.
const VARIANT_CLASSES: Record<ButtonVariant, string> = {
  primary: 'border border-solid border-[var(--button-primary-border)] bg-[var(--button-primary-bg)] text-[var(--button-primary-fg)] hover:bg-[var(--button-primary-bg-hover)]',
  ghost: 'border border-solid border-[var(--button-ghost-border)] bg-[var(--button-ghost-bg)] text-[var(--button-ghost-fg)] hover:bg-[var(--button-ghost-bg-hover)]',
  danger: 'border border-solid border-[var(--button-danger-border)] bg-[var(--button-danger-bg)] text-[var(--button-danger-fg)] hover:bg-[var(--button-danger-bg-hover)]',
  subtle: 'border-none bg-transparent text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)] hover:bg-[var(--white-6)]',
  ok: 'border border-solid border-[var(--button-ok-border)] bg-[var(--button-ok-bg)] text-[var(--button-ok-fg)] hover:bg-[var(--button-ok-bg-hover)]',
  warn: 'border-none bg-[var(--warn-14)] text-[var(--color-status-warn)] hover:bg-[var(--warn-24)]',
}

// Pressed-state overrides per variant. Applied when `pressed=true` so the
// button visually conveys the "selected" / "active filter" / "active tab"
// state that aria-pressed announces to assistive tech. Without this the
// button can be aria-pressed but visually identical to unpressed, which
// is a confusing mismatch.
//
// ghost pressed deliberately swaps its border/fg to the primary slots —
// the active state borrows primary's affordance so the user reads it
// as "selected" instead of "still neutral".
const PRESSED_CLASSES: Record<ButtonVariant, string> = {
  primary: 'bg-[var(--button-primary-bg-pressed)]',
  ghost: 'bg-[var(--button-ghost-bg-pressed)] border-[var(--button-primary-border)] text-[var(--button-primary-fg)]',
  danger: 'bg-[var(--button-danger-bg-pressed)]',
  subtle: 'bg-[var(--white-6)] text-[var(--color-fg-primary)]',
  ok: 'bg-[var(--button-ok-bg-pressed)]',
  warn: 'bg-[var(--warn-24)]',
}

// `duration-[var(--t-med)]` reads from the design-token duration scale
// (--t-med = 200ms by default). Token retune (e.g. dampening interaction
// motion for accessibility) propagates without callsite edits.
const BASE = `rounded cursor-pointer transition-all duration-[var(--t-med)] font-medium ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'surface' })} active:scale-[0.97] active:opacity-90`

interface ActionButtonProps {
  variant?: ButtonVariant
  size?: ButtonSize
  type?: ButtonType
  class?: string
  id?: string
  disabled?: boolean
  /** Full width */
  block?: boolean
  ariaLabel?: string
  /** Announce "busy" to assistive tech while an async op backed by
      this button is in flight. Pair with a disabled=${true} to lock
      the UI; the busy role informs AT, the disabled flag handles
      pointer events. */
  ariaBusy?: boolean
  /** Tab-like / toggle-like buttons that convey selection state.
      When true, applies aria-pressed=true plus a variant-specific
      visual override (see PRESSED_CLASSES). Use for tier filters,
      view toggles, and similar selection patterns where multiple
      buttons share a slot and one is "active". */
  pressed?: boolean
  /** Hover tooltip text (native browser title). */
  title?: string
  /** Rendered as `data-testid` so E2E / unit tests can target this
      button without coupling to visible text (which may be i18n'd). */
  testId?: string
  onClick?: (e: Event) => void
  children: ComponentChildren
}

export function ActionButton({
  variant = 'primary',
  size = 'md',
  type = 'button',
  class: cx,
  id,
  disabled,
  block,
  ariaLabel,
  ariaBusy,
  pressed,
  title,
  testId,
  onClick,
  children,
}: ActionButtonProps) {
  const cls = [
    BASE,
    SIZE_CLASSES[size],
    VARIANT_CLASSES[variant],
    pressed ? PRESSED_CLASSES[variant] : '',
    block ? 'w-full' : '',
    disabled ? 'opacity-50 pointer-events-none' : '',
    cx,
  ].filter(Boolean).join(' ')

  return html`
    <button
      type=${type}
      id=${id}
      class=${cls}
      onClick=${onClick}
      disabled=${disabled}
      aria-label=${ariaLabel}
      aria-busy=${ariaBusy === true ? 'true' : undefined}
      aria-pressed=${pressed === true ? 'true' : pressed === false ? 'false' : undefined}
      title=${title}
      data-testid=${testId}
    >${children}</button>
  `
}
