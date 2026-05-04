// CommandBar — inline fuzzy-search command input molecule.
//
// Kimi design system sec09 Phase 1 reference: fuzzy search, windowing,
// split pane. This is the inline command bar (not the modal CommandPalette
// which uses ninja-keys).

import { html } from 'htm/preact'
import { useMemo, useRef, useState } from 'preact/hooks'

interface CommandBarAction {
  id: string
  title: string
  keywords?: string
  handler: () => void
}

interface CommandBarProps {
  actions: CommandBarAction[]
  placeholder?: string
  onSelect?: (action: CommandBarAction) => void
  testId?: string
}

function fuzzyScore(query: string, text: string): number {
  const q = query.toLowerCase()
  const t = text.toLowerCase()
  if (t.startsWith(q)) return 3
  if (t.includes(q)) return 2
  // character-by-character match
  let ti = 0
  for (const ch of q) {
    ti = t.indexOf(ch, ti)
    if (ti === -1) return 0
    ti++
  }
  return 1
}

function filterActions(actions: CommandBarAction[], query: string): CommandBarAction[] {
  if (!query.trim()) return actions.slice(0, 8)
  const scored = actions
    .map((a) => {
      const text = `${a.title} ${a.keywords ?? ''}`
      return { action: a, score: fuzzyScore(query, text) }
    })
    .filter((s) => s.score > 0)
    .sort((a, b) => b.score - a.score)
  return scored.map((s) => s.action).slice(0, 8)
}

export function CommandBar({
  actions,
  placeholder = '명령어 검색...',
  onSelect,
  testId,
}: CommandBarProps) {
  const [query, setQuery] = useState('')
  const [open, setOpen] = useState(false)
  const [activeIndex, setActiveIndex] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)
  const listId = useMemo(() => `cmdbar-list-${Math.random().toString(36).slice(2, 8)}`, [])

  const filtered = useMemo(() => filterActions(actions, query), [actions, query])

  const handleInput = (e: Event) => {
    const value = (e.target as HTMLInputElement).value
    setQuery(value)
    setOpen(true)
    setActiveIndex(0)
  }

  const handleKeyDown = (e: KeyboardEvent) => {
    if (!open) return
    switch (e.key) {
      case 'ArrowDown': {
        e.preventDefault()
        setActiveIndex((i) => (i + 1) % filtered.length)
        break
      }
      case 'ArrowUp': {
        e.preventDefault()
        setActiveIndex((i) => (i - 1 + filtered.length) % filtered.length)
        break
      }
      case 'Enter': {
        e.preventDefault()
        const action = filtered[activeIndex]
        if (action) {
          action.handler()
          onSelect?.(action)
          setQuery('')
          setOpen(false)
          setActiveIndex(0)
        }
        break
      }
      case 'Escape': {
        setOpen(false)
        inputRef.current?.blur()
        break
      }
    }
  }

  const handleBlur = () => {
    // Delay so click on list item can fire first
    setTimeout(() => setOpen(false), 150)
  }

  const handleFocus = () => {
    if (query.trim() || actions.length > 0) setOpen(true)
  }

  const handleItemClick = (action: CommandBarAction) => {
    action.handler()
    onSelect?.(action)
    setQuery('')
    setOpen(false)
    setActiveIndex(0)
  }

  return html`
    <div class="relative w-full" data-command-bar data-testid=${testId}>
      <input
        ref=${inputRef}
        type="text"
        class="w-full rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-sm text-[var(--color-fg-primary)] outline-none transition-colors focus:border-[var(--color-accent)] focus:ring-1 focus:ring-[var(--color-accent)]"
        placeholder=${placeholder}
        value=${query}
        onInput=${handleInput}
        onKeyDown=${handleKeyDown}
        onFocus=${handleFocus}
        onBlur=${handleBlur}
        role="combobox"
        aria-expanded=${open}
        aria-autocomplete="list"
        aria-controls=${listId}
        aria-activedescendant=${open && filtered[activeIndex] ? `cmdbar-item-${filtered[activeIndex].id}` : undefined}
      />
      ${open && filtered.length > 0
        ? html`
            <ul
              id=${listId}
              class="absolute z-10 mt-1 max-h-64 w-full overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] py-1 shadow-[var(--shadow-panel)]"
              role="listbox"
            >
              ${filtered.map((action, index) => {
                const isActive = index === activeIndex
                const base =
                  'flex cursor-pointer items-center px-3 py-2 text-sm'
                const activeCls = isActive
                  ? 'bg-[var(--color-bg-hover)] text-[var(--color-fg-primary)]'
                  : 'text-[var(--color-fg-secondary)]'
                return html`
                  <li
                    id=${`cmdbar-item-${action.id}`}
                    class="${base} ${activeCls}"
                    role="option"
                    aria-selected=${isActive}
                    onMouseEnter=${() => setActiveIndex(index)}
                    onMouseDown=${() => handleItemClick(action)}
                  >
                    ${action.title}
                  </li>
                `
              })}
            </ul>
          `
        : null}
    </div>
  `
}
