// Select — native <select> primitive with string-or-{value,label} options.
//
// Props are a strict whitelist — htm/preact function components do NOT
// implicitly spread unlisted props. Without `id`, `<label for="...">`
// can't resolve; without `ariaLabel`/`ariaLabelledby`, screen readers
// read "combobox" / "select" with no accessible name. Missing `onBlur`
// blocks validate-on-blur flows. Missing `testId` forces E2E tests to
// couple to visible option text (which may be i18n'd).
// If you add a prop to the interface, add it to the JSX too.
// (Pattern mirrors input.ts / button.ts / checkbox.ts / number-input.ts.)

import { html } from 'htm/preact'
import { ringFocusClasses } from './ring'

const SELECT_BASE = `w-full rounded-[var(--r-1)] bg-[var(--white-4)] border border-[var(--color-border-default)] text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--white-6)] focus-visible:bg-[var(--color-bg-page)] focus-visible:border-[var(--info-border)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'surface' })} appearance-none cursor-pointer`

interface SelectOption { value: string; label: string }

interface SelectProps {
  value?: string
  options: Array<string | SelectOption>
  placeholder?: string
  disabled?: boolean
  class?: string
  /** Forwarded to DOM id so `<label for="...">` resolves. */
  id?: string
  /** Form field name for native submit + FormData. */
  name?: string
  /** Accessible name when no visible <label> is associated via `for`. */
  ariaLabel?: string
  /** Reference an external label by id. */
  ariaLabelledby?: string
  /** Rendered as `data-testid` so E2E / unit tests can target this
      <select> without coupling to option text (which may be i18n'd). */
  testId?: string
  /** Native required flag — participates in form validation. */
  required?: boolean
  onInput?: (value: string) => void
  /** Fires when the select loses focus — the natural hook for
      validate-on-blur ("you must pick one"). */
  onBlur?: (e: FocusEvent) => void
}

export function Select({
  value,
  options,
  placeholder,
  disabled,
  class: cx,
  id,
  name,
  ariaLabel,
  ariaLabelledby,
  testId,
  required,
  onInput,
  onBlur,
}: SelectProps) {
  const handleChange = (e: Event) => { onInput?.((e.target as HTMLSelectElement).value) }
  const currentValue = value ?? ''
  return html`
    <select
      id=${id}
      name=${name}
      class="${SELECT_BASE} px-3 py-2 text-sm ${cx ?? ''}"
      value=${currentValue}
      disabled=${disabled}
      aria-label=${ariaLabel}
      aria-labelledby=${ariaLabelledby}
      data-testid=${testId}
      required=${required}
      onChange=${handleChange}
      onBlur=${onBlur}
    >
      ${placeholder ? html`<option value="" disabled hidden>${placeholder}</option>` : null}
      ${options.map(opt => {
        const v = typeof opt === 'string' ? opt : opt.value
        const label = typeof opt === 'string' ? opt : opt.label
        return html`<option value=${v}>${label}</option>`
      })}
    </select>
  `
}
