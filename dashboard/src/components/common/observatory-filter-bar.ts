// Observatory Global Filter Bar (RFC-MASC-006 Phase 1)
//
// Compact chip display shown in dashboard header when any observatory filter
// is active. Each chip is clearable independently + a "clear all" link.
//
// The bar is hidden when no filter is active — zero visual noise.

import { html } from 'htm/preact'
import { X } from 'lucide-preact'
import {
  currentKeeperFilter,
  currentNamespaceFilter,
  currentOperationFilter,
  currentTimeRangeFilter,
  hasActiveObservatoryFilter,
  setObservatoryFilter,
  clearObservatoryFilters,
  timeRangeLabel,
} from '../../observatory-filter-store'

function Chip({
  label,
  value,
  onClear,
}: {
  label: string
  value: string
  onClear: () => void
}) {
  return html`
    <span class="inline-flex items-center gap-1.5 rounded-full border border-card-border bg-card/50 px-2.5 py-1 text-[11px]">
      <span class="text-text-dim font-medium">${label}:</span>
      <span class="font-mono text-text-strong">${value}</span>
      <button
        type="button"
        class="ml-0.5 rounded-full p-0.5 text-text-muted hover:bg-white/10 hover:text-text-strong transition-colors"
        onClick=${onClear}
        aria-label=${`${label} 필터 제거`}
      >
        <${X} size=${10} />
      </button>
    </span>
  `
}

export function ObservatoryFilterBar() {
  if (!hasActiveObservatoryFilter()) return null

  const keeper = currentKeeperFilter()
  const namespace = currentNamespaceFilter()
  const operation = currentOperationFilter()
  const range = currentTimeRangeFilter()

  return html`
    <div
      class="mb-3 flex flex-wrap items-center gap-2 rounded border border-card-border bg-bg-1/60 px-3 py-2"
      role="region"
      aria-label="활성 관찰 필터"
    >
      <span class="text-[10px] uppercase tracking-wider text-text-dim font-semibold">필터</span>
      ${keeper ? html`
        <${Chip}
          label="Keeper"
          value=${keeper}
          onClear=${() => setObservatoryFilter({ keeper: null })}
        />
      ` : null}
      ${namespace ? html`
        <${Chip}
          label="Namespace"
          value=${namespace}
          onClear=${() => setObservatoryFilter({ namespace: null })}
        />
      ` : null}
      ${operation ? html`
        <${Chip}
          label="Operation"
          value=${operation}
          onClear=${() => setObservatoryFilter({ operation: null })}
        />
      ` : null}
      ${range ? html`
        <${Chip}
          label="Range"
          value=${timeRangeLabel(range)}
          onClear=${() => setObservatoryFilter({ range: null })}
        />
      ` : null}
      <button
        type="button"
        class="ml-auto rounded text-[11px] font-medium text-text-muted underline decoration-dotted underline-offset-2 hover:text-text-strong transition-colors"
        onClick=${() => clearObservatoryFilters()}
      >
        모두 해제
      </button>
    </div>
  `
}
