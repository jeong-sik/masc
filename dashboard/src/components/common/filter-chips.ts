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
}

export function FilterChips<T extends string>({
  chips,
  active,
  value,
  onChange,
  class: cx,
  size = 'sm',
  tone = 'gold',
}: FilterChipsProps<T>) {
  const activeKey = active?.value ?? value
  const chipClass = size === 'md'
    ? 'inline-flex min-h-9 items-center gap-1.5 rounded-md border px-3 py-2 text-[12px] font-medium'
    : 'inline-flex items-center gap-1.5 rounded-md border px-2 py-1 text-[12px] font-medium'
  const activeToneClass = tone === 'accent'
    ? 'border-border bg-brand/10 text-brand'
    : 'border-warning/20 bg-warning/10 text-warning'
  const idleToneClass = tone === 'accent'
    ? 'border-border bg-card text-text-disabled hover:bg-surface-subtle hover:border-border hover:text-text-primary'
    : 'border-border bg-card text-text-disabled hover:bg-surface-subtle hover:border-brand/30'

  return html`
    <div class="flex flex-wrap gap-1.5 ${cx ?? ''}" role="tablist">
      ${chips.map(chip => html`
        <button type="button"
          key=${chip.key}
          title=${chip.title}
          role="tab"
          aria-selected=${activeKey === chip.key}
          class="${chipClass} cursor-pointer transition-[background-color,border-color,box-shadow] duration-[var(--t-fast)] ${activeKey === chip.key
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
              ? 'bg-surface-muted text-current'
              : ''}>${chip.count}<//>
          ` : null}
        </button>
      `)}
    </div>
  `
}
