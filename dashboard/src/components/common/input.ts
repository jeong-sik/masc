// TextInput / TextArea — consistent form inputs
// Replaces 6+ inline input patterns with consistent styling.
//
// Props are whitelisted (no implicit spread), so EVERY prop a caller
// expects to reach the DOM must be listed here explicitly. A missing
// entry silently drops the attribute — most painfully for `id`, which
// `<label for="...">` callers rely on for focus routing and screen
// readers. If you add a new prop to the interface, add it to the JSX
// below too.

import { html } from 'htm/preact'
import { ringFocusClasses } from './ring'

// Form input surface — bg/fg/border + hover/focus state slots resolve
// from the input-* component-level token family (#11917). Future field
// retune (e.g. brand re-skin, dark/light) ripples to all 4 form
// primitives (TextInput/TextArea/NumberInput/Select) via these aliases.
// `placeholder` color and `focus-visible` border color remain inline
// pending follow-up token slots (input-placeholder, input-border-focus).
const INPUT_BASE = `w-full rounded bg-[var(--input-bg)] border border-[var(--input-border)] text-[var(--input-fg)] placeholder:text-[var(--color-fg-muted)] transition-colors hover:bg-[var(--input-bg-hover)] focus-visible:bg-[var(--input-bg-focus)] focus-visible:border-[rgba(71,184,255,0.6)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'surface' })}`

interface TextInputProps {
  id?: string
  value?: string
  placeholder?: string
  disabled?: boolean
  required?: boolean
  class?: string
  type?: string
  name?: string
  ariaLabel?: string
  autoComplete?: string
  /** Rendered as `data-testid` so E2E / unit tests can target this
      <input> without coupling to placeholder text (which may be i18n'd).
      Mirrors the same prop on Select. */
  testId?: string
  /** Native autofocus — applied on initial mount. */
  autoFocus?: boolean
  /** Forwards a Preact ref to the inner <input>. Distinct from `id` —
      use this when callers need imperative focus control (e.g. an
      external "edit" button that focuses this field) or when a parent
      dialog component takes `initialFocusRef`. Pass a `useRef` result. */
  inputRef?: { current: HTMLInputElement | null }
  onInput?: (e: Event) => void
  onKeyDown?: (e: KeyboardEvent) => void
  /** Fires when the input loses focus. Common pattern: commit pending
      filter/search value when the user tabs away (mirrors Enter handling
      in onKeyDown). Accepts FocusEvent so callers can use relatedTarget
      without a cast. */
  onBlur?: (e: FocusEvent) => void
}

export function TextInput({
  id,
  value,
  placeholder,
  disabled,
  required,
  class: cx,
  type = 'text',
  name,
  ariaLabel,
  autoComplete,
  testId,
  autoFocus,
  inputRef,
  onInput,
  onKeyDown,
  onBlur,
}: TextInputProps) {
  return html`
    <input
      ref=${inputRef}
      id=${id}
      type=${type}
      class="${INPUT_BASE} px-3 py-2 text-sm ${cx ?? ''}"
      value=${value}
      placeholder=${placeholder}
      disabled=${disabled}
      required=${required}
      name=${name}
      aria-label=${ariaLabel}
      autocomplete=${autoComplete}
      data-testid=${testId}
      autofocus=${autoFocus}
      onInput=${onInput}
      onKeyDown=${onKeyDown}
      onBlur=${onBlur}
    />
  `
}

interface TextAreaProps {
  id?: string
  value?: string
  placeholder?: string
  rows?: number
  class?: string
  name?: string
  ariaLabel?: string
  disabled?: boolean
  required?: boolean
  /** Forwards a Preact ref to the inner <textarea>. Mirrors TextInput —
      see that component's docstring for when this is needed (imperative
      focus, dialog `initialFocusRef`, etc.). */
  inputRef?: { current: HTMLTextAreaElement | null }
  onInput?: (e: Event) => void
}

export function TextArea({
  id,
  value,
  placeholder,
  rows,
  class: cx,
  name,
  ariaLabel,
  disabled,
  required,
  inputRef,
  onInput,
}: TextAreaProps) {
  return html`
    <textarea
      ref=${inputRef}
      id=${id}
      class="${INPUT_BASE} px-3 py-2 text-sm min-h-20 resize-y ${cx ?? ''}"
      placeholder=${placeholder}
      rows=${rows}
      name=${name}
      aria-label=${ariaLabel}
      disabled=${disabled}
      required=${required}
      value=${value}
      onInput=${onInput}
    ></textarea>
  `
}
