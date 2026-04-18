// Checkbox — consistent checkbox primitive for forms and toggles.
//
// Props are a strict whitelist — htm/preact function components do NOT
// implicitly spread unlisted props to children. This matters more for
// <input type="checkbox"> than for most primitives: without `id` a
// `<label for="...">` can't resolve, and without `ariaLabel` /
// `ariaLabelledby` a screen reader reading the checkbox alone has no
// accessible name at all. If you add a new prop to the interface below,
// also add it to the JSX — missing entries silently drop, which is how
// two earlier callers (ActionButton pre-refactor, TextInput pre-refactor)
// ended up shipping orphan labels.

import { html } from 'htm/preact'

const CHECKBOX_BASE = 'w-4 h-4 rounded border border-[var(--card-border)] bg-[var(--white-4)] cursor-pointer transition-colors hover:bg-[var(--white-8)] hover:border-[var(--white-20)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-1)] accent-[var(--accent)]'

interface CheckboxProps {
  checked?: boolean
  disabled?: boolean
  class?: string
  /** Forwarded to the DOM id so `<label for="...">` can resolve. Without
      this, external labels are orphan and screen readers read "checkbox"
      with no name. */
  id?: string
  /** Form field name for native submit + FormData serialization. */
  name?: string
  /** Accessible name when no visible label is associated via `for`. */
  ariaLabel?: string
  /** Reference another element's id as the accessible name. Useful when
      the label sits near the checkbox but isn't wrapped around it. */
  ariaLabelledby?: string
  /** The submitted form value when the checkbox is checked. Distinct
      from `checked`: `value` is the string that ends up in FormData. */
  value?: string
  /** Rendered as `data-testid` so E2E / unit tests can target this
      checkbox without coupling to DOM position. */
  testId?: string
  onChange?: (checked: boolean) => void
}

export function Checkbox({
  checked,
  disabled,
  class: cx,
  id,
  name,
  ariaLabel,
  ariaLabelledby,
  value,
  testId,
  onChange,
}: CheckboxProps) {
  const handleChange = (e: Event) => { onChange?.((e.target as HTMLInputElement).checked) }
  return html`
    <input
      type="checkbox"
      id=${id}
      name=${name}
      value=${value}
      class="${CHECKBOX_BASE} ${cx ?? ''}"
      checked=${checked}
      disabled=${disabled}
      aria-label=${ariaLabel}
      aria-labelledby=${ariaLabelledby}
      data-testid=${testId}
      onChange=${handleChange}
    />
  `
}
