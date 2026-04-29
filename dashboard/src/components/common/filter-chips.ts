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
    ? 'inline-flex min-h-9 items-center gap-1.5 rounded border px-3 py-2 text-2xs font-medium'
    : 'inline-flex items-center gap-1.5 rounded border px-2 py-1 text-[length:var(--fs-xs)]'
  const activeToneClass = tone === 'accent'
    ? 'border-[var(--color-border-default)] bg-[var(--color-accent-soft)] text-[var(--color-fg-secondary)]'
    : 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--warn-bright)]'
  const idleToneClass = tone === 'accent'
    ? 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--color-fg-disabled)] hover:bg-[var(--white-8)] hover:border-[var(--color-border-default)] hover:text-[var(--color-fg-primary)]'
    : 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--color-fg-disabled)] hover:bg-[var(--white-8)] hover:border-[rgba(200,168,78,0.4)]'

  return html`
    <div class="flex flex-wrap gap-1.5 ${cx ?? ''}" role="tablist">
      ${chips.map(chip => html`
        <button type="button"
          key=${chip.key}
          title=${chip.title}
          role="tab"
          aria-selected=${activeKey === chip.key}
          class="${chipClass} cursor-pointer transition-all duration-[var(--t-fast)] ${activeKey === chip.key
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
