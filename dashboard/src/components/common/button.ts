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
import { isNonEmptyString } from '../../lib/format-string'

export type ButtonVariant = 'primary' | 'ghost' | 'danger' | 'subtle' | 'ok' | 'warn'
export type ButtonSize = 'sm' | 'md' | 'lg'
export type ButtonType = 'button' | 'submit' | 'reset'
export type ButtonPressedState = 'unset' | 'true' | 'false'

export interface ActionButtonSummary {
  readonly variant: ButtonVariant
  readonly size: ButtonSize
  readonly type: ButtonType
  readonly block: boolean
  readonly disabled: boolean
  readonly busy: boolean
  readonly pressedState: ButtonPressedState
  readonly hasCustomClass: boolean
  readonly classNameLength: number
  readonly hasId: boolean
  readonly idLength: number
  readonly hasAriaLabel: boolean
  readonly ariaLabelLength: number
  readonly hasTitle: boolean
  readonly titleLength: number
  readonly hasTestId: boolean
  readonly testIdLength: number
  readonly hasOnClick: boolean
  readonly hasChildren: boolean
}

const SIZE_CLASSES: Record<ButtonSize, string> = {
  sm: 'py-1 px-2 text-[14px] font-medium rounded-md',
  md: 'py-1.5 px-2.5 text-[14px] font-medium rounded-md',
  lg: 'py-2 px-4 text-[18px] font-semibold rounded-lg',
}

// Component-level token slots (button-{variant}-bg/fg/border/bg-hover/bg-pressed).
// Defined in dashboard/design-system/tokens/source.ts §"Component-level role
// tokens". Each alias resolves to the same hex via var() chain; swapping
// the slot at the token layer (e.g. shipping a brand re-skin) propagates
// here without touching this file.
//
// All 6 variants now map to component-level aliases (#11898 added the
// remaining warn/subtle slots). border-none is preserved as an explicit
// utility for the variants whose `--button-{warn,subtle}-border` slot
// is `transparent` (rendering-as-none for layout-grid stability).
const VARIANT_CLASSES: Record<ButtonVariant, string> = {
  primary: 'border border-solid border-brand bg-brand text-white hover:bg-brand-hover',
  ghost: 'border border-solid border-border bg-transparent text-text-primary hover:bg-surface-subtle',
  danger: 'border border-solid border-destructive/40 bg-transparent text-destructive hover:bg-destructive/10',
  subtle: 'border-none bg-transparent text-text-secondary hover:text-text-primary hover:bg-surface-subtle',
  ok: 'border border-solid border-success/40 bg-success/10 text-success hover:bg-success/20',
  warn: 'border-none bg-warning/10 text-warning hover:bg-warning/20',
}

// Pressed-state overrides per variant. Applied when `pressed=true` so the
// button visually conveys the "selected" / "active filter" / "active tab"
// state that aria-pressed announces to assistive tech.
const PRESSED_CLASSES: Record<ButtonVariant, string> = {
  primary: 'bg-brand-hover',
  ghost: 'bg-surface-muted border-brand text-brand',
  danger: 'bg-destructive/10',
  subtle: 'bg-surface-muted text-text-primary',
  ok: 'bg-success/20',
  warn: 'bg-warning/20',
}

const BASE = `cursor-pointer transition-[background-color,border-color,box-shadow,opacity] duration-150 font-medium focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2`

export interface ActionButtonProps {
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

function pressedState(pressed: boolean | undefined): ButtonPressedState {
  if (pressed === true) return 'true'
  if (pressed === false) return 'false'
  return 'unset'
}

export function summarizeActionButton({
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
}: ActionButtonProps): ActionButtonSummary {
  return {
    variant,
    size,
    type,
    block: block === true,
    disabled: disabled === true,
    busy: ariaBusy === true,
    pressedState: pressedState(pressed),
    hasCustomClass: isNonEmptyString(cx),
    classNameLength: cx?.length ?? 0,
    hasId: isNonEmptyString(id),
    idLength: id?.length ?? 0,
    hasAriaLabel: isNonEmptyString(ariaLabel),
    ariaLabelLength: ariaLabel?.length ?? 0,
    hasTitle: isNonEmptyString(title),
    titleLength: title?.length ?? 0,
    hasTestId: isNonEmptyString(testId),
    testIdLength: testId?.length ?? 0,
    hasOnClick: typeof onClick === 'function',
    hasChildren: children !== undefined && children !== null,
  }
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
  const summary = summarizeActionButton({
    variant,
    size,
    type,
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
  })
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
      data-action-button
      data-action-button-variant=${summary.variant}
      data-action-button-size=${summary.size}
      data-action-button-type=${summary.type}
      data-action-button-block=${summary.block}
      data-action-button-disabled=${summary.disabled}
      data-action-button-busy=${summary.busy}
      data-action-button-pressed-state=${summary.pressedState}
      data-action-button-has-custom-class=${summary.hasCustomClass}
      data-action-button-class-length=${summary.classNameLength}
      data-action-button-has-id=${summary.hasId}
      data-action-button-id-length=${summary.idLength}
      data-action-button-has-aria-label=${summary.hasAriaLabel}
      data-action-button-aria-label-length=${summary.ariaLabelLength}
      data-action-button-has-title=${summary.hasTitle}
      data-action-button-title-length=${summary.titleLength}
      data-action-button-has-test-id=${summary.hasTestId}
      data-action-button-test-id-length=${summary.testIdLength}
      data-action-button-has-click-handler=${summary.hasOnClick}
      data-action-button-has-children=${summary.hasChildren}
    >${children}</button>
  `
}
