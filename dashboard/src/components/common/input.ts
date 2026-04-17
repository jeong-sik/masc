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

const INPUT_BASE = 'w-full rounded-lg bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] placeholder:text-[var(--text-muted)] transition-colors hover:bg-[var(--white-6)] focus-visible:bg-[var(--bg-0)] focus-visible:outline-none focus-visible:border-[rgba(71,184,255,0.6)] focus-visible:ring-2 focus-visible:ring-[rgba(71,184,255,0.45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-1)]'

interface TextInputProps {
  id?: string
  value?: string
  placeholder?: string
  disabled?: boolean
  class?: string
  type?: string
  name?: string
  ariaLabel?: string
  autoComplete?: string
  onInput?: (e: Event) => void
  onKeyDown?: (e: KeyboardEvent) => void
}

export function TextInput({
  id,
  value,
  placeholder,
  disabled,
  class: cx,
  type = 'text',
  name,
  ariaLabel,
  autoComplete,
  onInput,
  onKeyDown,
}: TextInputProps) {
  return html`
    <input
      id=${id}
      type=${type}
      class="${INPUT_BASE} px-3 py-2 text-[13px] ${cx ?? ''}"
      value=${value}
      placeholder=${placeholder}
      disabled=${disabled}
      name=${name}
      aria-label=${ariaLabel}
      autocomplete=${autoComplete}
      onInput=${onInput}
      onKeyDown=${onKeyDown}
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
  onInput,
}: TextAreaProps) {
  return html`
    <textarea
      id=${id}
      class="${INPUT_BASE} px-3 py-2 text-[13px] min-h-[80px] resize-y ${cx ?? ''}"
      placeholder=${placeholder}
      rows=${rows}
      name=${name}
      aria-label=${ariaLabel}
      disabled=${disabled}
      value=${value}
      onInput=${onInput}
    ></textarea>
  `
}
