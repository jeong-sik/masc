// FilterChips — reusable filter chip bar
// Replaces 15+ inline filter implementations across the dashboard.

import { html } from 'htm/preact'
import type { Signal } from '@preact/signals'
import { CountBadge } from './badge'

interface FilterChip<T extends string> {
  key: T
  label: string
  count?: number | string | null
  title?: string
}

interface FilterChipsProps<T extends string> {
  chips: FilterChip<T>[]
  active?: Signal<T>
  value?: T
  onChange?: (key: T) => void
  class?: string
  size?: 'sm' | 'md'
  tone?: 'gold' | 'accent'
  ariaLabel?: string
}

export function FilterChips<T extends string>({
  chips,
  active,
  value,
  onChange,
  class: cx,
  size = 'sm',
  tone = 'gold',
  ariaLabel,
}: FilterChipsProps<T>) {
  const activeKey = active?.value ?? value
  const chipClass = size === 'md'
    ? 'inline-flex min-h-9 items-center gap-1.5 rounded border px-3 py-2 text-2xs font-medium'
    : 'inline-flex items-center gap-1.5 rounded border px-2 py-1 text-[length:var(--fs-xs)]'
  const activeToneClass = tone === 'accent'
    ? 'border-[var(--border-slate-22)] bg-[var(--accent-soft)] text-[var(--text-strong)]'
    : 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--warn-bright)]'
  const idleToneClass = tone === 'accent'
    ? 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:border-[var(--border-slate-22)] hover:text-[var(--text-body)]'
    : 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:border-[rgba(200,168,78,0.4)]'

  function handleKeyDown(e: KeyboardEvent) {
    if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return
    const idx = chips.findIndex(c => c.key === activeKey)
    if (idx < 0) return
    const next = e.key === 'ArrowRight'
      ? (idx + 1) % chips.length
      : (idx - 1 + chips.length) % chips.length
    const key = chips[next].key
    if (active) active.value = key
    onChange?.(key)
    ;(e.currentTarget as HTMLElement).querySelectorAll<HTMLElement>('[role="tab"]')[next]?.focus()
    e.preventDefault()
  }

  return html`
    <div class="flex flex-wrap gap-1.5 ${cx ?? ''}" role="tablist" aria-label=${ariaLabel} onKeyDown=${handleKeyDown}>
      ${chips.map(chip => html`
        <button type="button"
          key=${chip.key}
          title=${chip.title}
          role="tab"
          tabIndex=${activeKey === chip.key ? 0 : -1}
          aria-selected=${activeKey === chip.key}
          class="${chipClass} cursor-pointer transition-all duration-150 ${activeKey === chip.key
            ? activeToneClass
            : idleToneClass}"
          onClick=${() => {
            if (active) active.value = chip.key
            onChange?.(chip.key)
          }}
        >
          ${chip.label}
          ${chip.count != null ? html`
            <${CountBadge} class=${activeKey === chip.key
              ? 'bg-[rgba(255,255,255,0.12)] text-current'
              : ''}>${chip.count}<//>
          ` : null}
        </button>
      `)}
    </div>
  `
}
