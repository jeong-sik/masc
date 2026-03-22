// TextInput / TextArea — consistent form inputs
// Replaces 6+ inline input patterns with consistent styling

import { html } from 'htm/preact'

const INPUT_BASE = 'w-full rounded-lg bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] focus:border-[rgba(71,184,255,0.5)] outline-none placeholder:text-[var(--text-muted)] transition-colors'

interface TextInputProps {
  value?: string
  placeholder?: string
  disabled?: boolean
  class?: string
  onInput?: (e: Event) => void
  onKeyDown?: (e: KeyboardEvent) => void
}

export function TextInput({
  value,
  placeholder,
  disabled,
  class: cx,
  onInput,
  onKeyDown,
}: TextInputProps) {
  return html`
    <input
      type="text"
      class="${INPUT_BASE} px-3 py-2 text-[13px] ${cx ?? ''}"
      value=${value}
      placeholder=${placeholder}
      disabled=${disabled}
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
  onInput?: (e: Event) => void
}

export function TextArea({
  value,
  placeholder,
  rows,
  class: cx,
  onInput,
}: TextAreaProps) {
  return html`
    <textarea
      class="${INPUT_BASE} px-3 py-2 text-[13px] min-h-[80px] resize-y ${cx ?? ''}"
      placeholder=${placeholder}
      rows=${rows}
      value=${value}
      onInput=${onInput}
    ></textarea>
  `
}
