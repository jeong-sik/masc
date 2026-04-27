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

type ButtonVariant = 'primary' | 'ghost' | 'danger' | 'subtle' | 'ok'
type ButtonSize = 'sm' | 'md' | 'lg'
type ButtonType = 'button' | 'submit' | 'reset'

const SIZE_CLASSES: Record<ButtonSize, string> = {
  sm: 'py-1 px-2 text-2xs',
  md: 'py-1.5 px-2.5 text-2xs',
  lg: 'py-2 px-4 text-sm',
}

const VARIANT_CLASSES: Record<ButtonVariant, string> = {
  primary: 'border border-solid border-[var(--accent-30)] bg-[var(--accent-12)] text-[var(--color-fg-secondary)] hover:bg-[var(--accent-20)]',
  ghost: 'border border-solid border-[var(--color-border-default)] bg-[var(--white-4)] text-[var(--color-fg-primary)] hover:bg-[var(--white-8)]',
  danger: 'border border-solid border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--bad-light)] hover:bg-[var(--bad-20)]',
  subtle: 'border-none bg-transparent text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)] hover:bg-[var(--white-6)]',
  ok: 'border border-solid border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--color-status-ok)] hover:bg-[var(--ok-20)]',
}

// Pressed-state overrides per variant. Applied when `pressed=true` so the
// button visually conveys the "selected" / "active filter" / "active tab"
// state that aria-pressed announces to assistive tech. Without this the
// button can be aria-pressed but visually identical to unpressed, which
// is a confusing mismatch.
const PRESSED_CLASSES: Record<ButtonVariant, string> = {
  primary: 'bg-[var(--accent-20)]',
  ghost: 'bg-[var(--accent-12)] border-[var(--accent-30)] text-[var(--color-fg-secondary)]',
  danger: 'bg-[var(--bad-20)]',
  subtle: 'bg-[var(--white-6)] text-[var(--color-fg-primary)]',
  ok: 'bg-[var(--ok-20)]',
}

const BASE = 'rounded cursor-pointer transition-all duration-200 font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--color-bg-surface)] active:scale-[0.97] active:opacity-90'

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
