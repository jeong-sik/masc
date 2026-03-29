// TextInput / TextArea — consistent form inputs
// Replaces 6+ inline input patterns with consistent styling

import { html } from 'htm/preact'

const INPUT_BASE = 'w-full rounded-lg bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] placeholder:text-[var(--text-muted)] transition-colors focus-visible:outline-none focus-visible:border-[rgba(71,184,255,0.5)] focus-visible:ring-1 focus-visible:ring-[rgba(71,184,255,0.35)]'

interface TextInputProps {
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
