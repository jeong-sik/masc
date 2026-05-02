// Search — ARIA search primitive
// Kimi sec06 ARIA pattern: search. Enter submits query, Escape clears.

import { html } from 'htm/preact'
import type { FunctionComponent } from 'preact'
import { useCallback, useRef, useState } from 'preact/hooks'

interface SearchProps {
  value?: string
  onSearch?: (query: string) => void
  onChange?: (query: string) => void
  placeholder?: string
  'aria-label'?: string
  class?: string
}

const INPUT_CLS =
  'w-full rounded bg-[var(--white-4)] border border-[var(--color-border-default)] ' +
  'text-[var(--color-fg-primary)] px-3 py-2 text-sm transition-colors ' +
  'hover:bg-[var(--white-6)] focus-visible:bg-[var(--color-bg-page)] ' +
  'focus-visible:border-[var(--info-border)] outline-none'

export const Search: FunctionComponent<SearchProps> = ({
  value: controlled,
  onSearch,
  onChange,
  placeholder,
  'aria-label': ariaLabel = 'Search',
  class: cx,
}) => {
  const [uncontrolled, setUncontrolled] = useState('')
  const isControlled = controlled !== undefined
  const query = isControlled ? controlled! : uncontrolled
  const inputRef = useRef<HTMLInputElement>(null)

  const setQuery = useCallback(
    (v: string) => {
      if (!isControlled) setUncontrolled(v)
      onChange?.(v)
    },
    [isControlled, onChange],
  )

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault()
      onSearch?.(query)
    } else if (e.key === 'Escape') {
      e.preventDefault()
      setQuery('')
      onSearch?.('')
      inputRef.current?.focus()
    }
  }

  return html`
    <div role="search" class=${cx ?? ''}>
      <input
        ref=${inputRef}
        type="search"
        aria-label=${ariaLabel}
        value=${query}
        placeholder=${placeholder}
        class=${INPUT_CLS}
        onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
        onKeyDown=${handleKeyDown}
      />
    </div>
  `
}
