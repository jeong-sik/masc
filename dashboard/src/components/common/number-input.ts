// NumberInput — numeric-only input primitive with Number() coercion in onInput.
//
// Props are a strict whitelist — htm/preact function components do NOT
// implicitly spread unlisted props. Without `id`, `<label for="...">`
// can't resolve; without `ariaLabel`/`ariaLabelledby`, screen readers
// read "number input" with no accessible name. Missing keyboard hooks
// (`onKeyDown`/`onBlur`) block Enter-to-submit and validation-on-blur
// flows. If you add a prop to the interface, add it to the JSX too.
// (Pattern mirrors input.ts / button.ts / checkbox.ts.)

import { html } from 'htm/preact'
import { ringFocusClasses } from './ring'

const INPUT_BASE = `w-full rounded bg-[var(--white-4)] border border-[var(--color-border-default)] text-[var(--color-fg-primary)] placeholder:text-[var(--color-fg-muted)] transition-colors hover:bg-[var(--white-6)] focus-visible:bg-[var(--color-bg-page)] focus-visible:border-[rgba(71,184,255,0.6)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'surface' })}`

interface NumberInputProps {
  value?: number | string
  placeholder?: string
  disabled?: boolean
  class?: string
  step?: number | 'any'
  min?: number
  max?: number
  /** Forwarded to DOM id so `<label for="...">` resolves. */
  id?: string
  /** Form field name for native submit + FormData. */
  name?: string
  /** Accessible name when no visible <label> is associated via `for`. */
  ariaLabel?: string
  /** Reference an external label by id (e.g. a shared heading). */
  ariaLabelledby?: string
  /** Browser autofill hint — "off" for sensitive fields, or a token
      like "one-time-code". */
  autoComplete?: string
  /** Rendered as `data-testid` so E2E / unit tests can target this
      input without coupling to DOM position. */
  testId?: string
  onInput?: (value: number | undefined) => void
  /** Raw keyboard handler — lets callers implement Enter-to-submit,
      arrow-key steppers, Escape-to-cancel without re-deriving them. */
  onKeyDown?: (e: KeyboardEvent) => void
  /** Fires when the input loses focus — the natural hook for
      validation-on-blur ("must be ≥ 0"), snap-to-step, etc. */
  onBlur?: (e: FocusEvent) => void
}

export function NumberInput({
  value,
  placeholder,
  disabled,
  class: cx,
  step,
  min,
  max,
  id,
  name,
  ariaLabel,
  ariaLabelledby,
  autoComplete,
  testId,
  onInput,
  onKeyDown,
  onBlur,
}: NumberInputProps) {
  const handleInput = (e: Event) => {
    const raw = (e.target as HTMLInputElement).value
    if (raw === '') { onInput?.(undefined); return }
    const num = Number(raw)
    if (!Number.isNaN(num)) onInput?.(num)
  }
  return html`
    <input
      type="number"
      id=${id}
      name=${name}
      class="${INPUT_BASE} px-3 py-2 text-sm ${cx ?? ''}"
      value=${value}
      placeholder=${placeholder}
      disabled=${disabled}
      step=${step}
      min=${min}
      max=${max}
      aria-label=${ariaLabel}
      aria-labelledby=${ariaLabelledby}
      autocomplete=${autoComplete}
      data-testid=${testId}
      onInput=${handleInput}
      onKeyDown=${onKeyDown}
      onBlur=${onBlur}
    />
  `
}
