// MASC Dashboard — I0-B · Cross-zone keeper filter (chip multi-select)
//
// Design-system-only atom retained for `design-system/preview/cb-group-i.jsx`.
// Not mounted in production routes after the fleet-board control cleanup.
// Mount intentionally deferred; current consumer is the design-system preview.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import {
  keepers,
  selectedKeeperFilter,
  toggleKeeperInFilter,
  clearKeeperFilter,
  setKeeperFilterToAll,
} from '../store'

interface KeeperOption {
  name: string
  displayName: string
  emoji: string
}

const options = computed<KeeperOption[]>(() => {
  return keepers.value
    .map(k => ({
      name: k.name,
      displayName: k.koreanName ?? k.name,
      emoji: k.emoji ?? '',
    }))
    .sort((a, b) => a.name.localeCompare(b.name))
})

export function KeeperMultiSelect({
  label = 'keeper filter',
  hint,
}: {
  label?: string
  hint?: string
} = {}) {
  const all = options.value
  const selected = selectedKeeperFilter.value
  const allNames = all.map(o => o.name)
  const selectedCount = selected.size
  const hasSelection = selectedCount > 0
  const isAll = !hasSelection

  return html`
    <section
      class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-3 v2-monitoring-panel"
      role="group"
      aria-label=${label}
    >
      <header class="mb-2 flex flex-wrap items-baseline gap-2 v2-monitoring-toolbar">
        <span class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">
          ${label}
        </span>
        <span class="text-2xs text-text-disabled" aria-live="polite">
          ${isAll
            ? `전체 (${all.length}명)`
            : `${selectedCount} / ${all.length} 선택`}
        </span>
        <div class="ml-auto flex gap-1">
          <button
            type="button"
            class="rounded-[var(--r-1)] border border-card-border/40 px-2 py-0.5 text-2xs text-text-muted transition-colors hover:border-card-border/70 hover:text-text-strong v2-monitoring-action"
            disabled=${!hasSelection}
            onClick=${() => clearKeeperFilter()}
          >
            clear
          </button>
          <button
            type="button"
            class="rounded-[var(--r-1)] border border-card-border/40 px-2 py-0.5 text-2xs text-text-muted transition-colors hover:border-card-border/70 hover:text-text-strong v2-monitoring-action"
            onClick=${() => setKeeperFilterToAll(allNames)}
          >
            all
          </button>
        </div>
      </header>
      ${all.length === 0 ? html`
        <p class="text-2xs text-text-disabled">아직 등록된 keeper 가 없습니다.</p>
      ` : html`
        <div
          class="flex flex-wrap gap-1.5 v2-monitoring-row"
          role="group"
          aria-label=${`${all.length}명 keeper · multi-select`}
        >
          ${all.map(o => {
            const on = selected.has(o.name)
            return html`
              <button
                key=${o.name}
                type="button"
                role="checkbox"
                aria-checked=${on}
                aria-label=${o.name}
                class="inline-flex items-center gap-1 rounded-[var(--r-1)] border px-2 py-0.5 text-2xs font-mono transition-colors v2-monitoring-action ${on
                  ? 'border-[var(--accent-40)] bg-[var(--accent-15)] text-accent-fg'
                  : 'border-card-border/40 bg-[var(--color-bg-surface)] text-text-muted hover:border-card-border/70 hover:text-text-strong'}"
                onClick=${() => toggleKeeperInFilter(o.name)}
              >
                <span aria-hidden="true">${o.emoji}</span>
                <span>${o.displayName}</span>
                <span aria-hidden="true" class="text-text-disabled">${on ? '×' : '+'}</span>
              </button>
            `
          })}
        </div>
      `}
      ${hint ? html`
        <p class="mt-2 text-2xs text-text-disabled">${hint}</p>
      ` : null}
    </section>
  `
}
