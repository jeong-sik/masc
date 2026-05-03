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
import { ringFocusClasses } from './ring'

const CHECKBOX_BASE = `w-4 h-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] cursor-pointer transition-colors hover:bg-[var(--color-bg-hover)] hover:border-[var(--color-border-strong)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'surface' })} accent-[var(--color-accent-fg)]`

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
  /** Click handler that receives the raw Event. Use this when the
      checkbox sits inside a clickable parent (a row or a card) and
      you need `event.stopPropagation()` to prevent the parent's
      click from also firing. `onChange` runs alongside it for state
      updates; `onClick` is purely for event-flow control. */
  onClick?: (e: Event) => void
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
  onClick,
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
      onClick=${onClick}
    />
  `
}
