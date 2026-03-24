// FilterChips — reusable filter chip bar
// Replaces 15+ inline filter implementations across the dashboard.

import { html } from 'htm/preact'
import type { Signal } from '@preact/signals'

interface FilterChip<T extends string> {
  key: T
  label: string
}

interface FilterChipsProps<T extends string> {
  chips: FilterChip<T>[]
  active: Signal<T>
  onChange?: (key: T) => void
}

export function FilterChips<T extends string>({ chips, active, onChange }: FilterChipsProps<T>) {
  return html`
    <div class="flex flex-wrap gap-1.5">
      ${chips.map(chip => html`
        <button type="button"
          key=${chip.key}
          class="rounded-lg border px-2 py-1 text-[length:var(--fs-xs)] cursor-pointer transition-all duration-150 ${active.value === chip.key
            ? 'border-[rgba(200,168,78,0.5)] bg-[rgba(200,168,78,0.12)] text-[#e8d48b]'
            : 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:border-[rgba(200,168,78,0.4)]'}"
          onClick=${() => { active.value = chip.key; onChange?.(chip.key) }}
        >
          ${chip.label}
        </button>
      `)}
    </div>
  `
}
