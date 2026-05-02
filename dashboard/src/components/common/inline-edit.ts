// InlineEdit — click-to-edit atom with save/cancel semantics.
//
// Kimi design system sec02 2.3.1 reference: Atlassian ADS inline-edit pattern.
// Translated to Preact + htm/preact + Tailwind v4 dashboard conventions.

import { html } from 'htm/preact'
import { useRef, useState } from 'preact/hooks'

interface InlineEditProps {
  value: string
  onSave: (v: string) => void
  onCancel?: () => void
  placeholder?: string
  testId?: string
}

export function InlineEdit({
  value,
  onSave,
  onCancel,
  placeholder = '클릭하여 편집',
  testId,
}: InlineEditProps) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(value)
  const inputRef = useRef<HTMLInputElement>(null)

  const startEdit = () => {
    setEditing(true)
    setDraft(value)
    // focus after render
    requestAnimationFrame(() => {
      inputRef.current?.focus()
      inputRef.current?.select()
    })
  }

  const commit = () => {
    onSave(draft)
    setEditing(false)
  }

  const revert = () => {
    onCancel?.()
    setEditing(false)
    setDraft(value)
  }

  const onKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault()
      commit()
    } else if (e.key === 'Escape') {
      e.preventDefault()
      revert()
    }
  }

  if (!editing) {
    return html`
      <span
        class="inline-block cursor-text rounded px-1 py-0.5 text-sm text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--white-6)]"
        onClick=${startEdit}
        data-testid=${testId}
        role="button"
        tabindex="0"
        aria-label="편집: ${value || placeholder}"
        onKeyDown=${(e: KeyboardEvent) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            startEdit()
          }
        }}
      >
        ${value || html`<span class="italic text-[var(--color-fg-muted)]">${placeholder}</span>`}
      </span>
    `
  }

  return html`
    <input
      ref=${inputRef}
      type="text"
      value=${draft}
      onInput=${(e: InputEvent) => setDraft((e.currentTarget as HTMLInputElement).value)}
      onBlur=${commit}
      onKeyDown=${onKeyDown}
      class="inline-block w-full rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--color-bg-page)] px-2 py-0.5 text-sm text-[var(--color-fg-primary)] outline-none focus:ring-1 focus:ring-[var(--accent-30)]"
      data-testid=${testId ? `${testId}-input` : undefined}
      aria-label="편집 중"
    />
  `
}
