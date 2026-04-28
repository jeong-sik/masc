// MASC Dashboard — I0-B · Cross-zone keeper filter (chip multi-select)
//
// Phase 2 spec (`design-system/preview/cb-group-i.jsx:KeeperMultiSelect`)
// renders a horizontal chip group for selecting a keeper subset that
// downstream zones (token stats, board, telemetry, etc.) honor as a
// filter. The cross-cutting nature is the point — this is the IDE
// backbone's filter affordance.
//
// State lives in `selectedKeeperFilter` (store.ts) so other zones can
// read it without prop-drilling. Empty set = "all keepers" (default
// unconstrained view).
//
// Mount: any zone that benefits from a per-keeper scope. First
// use-site: cross-keeper TokenStats panel (#11532).

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
      class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-3"
      role="group"
      aria-label=${label}
    >
      <header class="mb-2 flex flex-wrap items-baseline gap-2">
        <span class="text-2xs font-semibold uppercase tracking-1 text-text-muted">
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
            class="rounded border border-card-border/40 px-2 py-0.5 text-2xs text-text-muted transition-colors hover:border-card-border/70 hover:text-text-strong"
            disabled=${!hasSelection}
            onClick=${() => clearKeeperFilter()}
          >
            clear
          </button>
          <button
            type="button"
            class="rounded border border-card-border/40 px-2 py-0.5 text-2xs text-text-muted transition-colors hover:border-card-border/70 hover:text-text-strong"
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
          class="flex flex-wrap gap-1.5"
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
                class="inline-flex items-center gap-1 rounded border px-2 py-0.5 text-2xs font-mono transition-colors ${on
                  ? 'border-accent/40 bg-[var(--accent-15)] text-accent'
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
