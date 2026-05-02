// AntiPatternList — 32 anti-patterns with category filter and risk counts.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { StatusChip } from '../common/status-chip'
import {
  ANTI_PATTERNS,
  riskTone,
  riskLabel,
  categoryLabel,
  categoryColor,
} from './data'
import type { AntiPatternCategory } from './data'

export function AntiPatternList() {
  const categoryFilter = useSignal<AntiPatternCategory | 'all'>('all')

  const categories: AntiPatternCategory[] = ['silent-failure', 'fake-fallback', 'string-match', 'hardcoding']
  const filtered = categoryFilter.value === 'all'
    ? ANTI_PATTERNS
    : ANTI_PATTERNS.filter(ap => ap.category === categoryFilter.value)

  const riskCounts = { C: 0, H: 0, M: 0, L: 0 }
  for (const ap of ANTI_PATTERNS) riskCounts[ap.risk]++

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-3 flex-wrap">
        <div class="flex gap-1">
          <button
            type="button"
            class="px-2 py-0.5 rounded text-[10px] font-mono border transition-colors ${
              categoryFilter.value === 'all'
                ? 'border-[var(--color-border-strong)] bg-[var(--white-8)] text-[var(--color-fg-primary)]'
                : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)] hover:border-[var(--color-border-strong)]'
            }"
            onClick=${() => { categoryFilter.value = 'all' }}
          >전체 (${ANTI_PATTERNS.length})</button>
          ${categories.map(cat => html`
            <button
              key=${cat}
              type="button"
              class="px-2 py-0.5 rounded text-[10px] font-mono border transition-colors ${
                categoryFilter.value === cat
                  ? 'border-[var(--color-border-strong)] bg-[var(--white-8)] text-[var(--color-fg-primary)]'
                  : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)] hover:border-[var(--color-border-strong)]'
              }"
              onClick=${() => { categoryFilter.value = cat }}
            >${categoryLabel(cat)} (${ANTI_PATTERNS.filter(ap => ap.category === cat).length})</button>
          `)}
        </div>
        <div class="flex gap-2 text-[10px] font-mono text-[var(--color-fg-muted)]">
          <span>C:<strong class="text-[var(--color-status-err)]">${riskCounts.C}</strong></span>
          <span>H:<strong class="text-[var(--color-status-err)]">${riskCounts.H}</strong></span>
          <span>M:<strong class="text-[var(--color-status-warn)]">${riskCounts.M}</strong></span>
          <span>L:<strong class="text-[var(--color-fg-muted)]">${riskCounts.L}</strong></span>
        </div>
      </div>

      <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
        <table class="w-full text-xs border-collapse">
          <thead>
            <tr class="bg-[var(--white-4)]">
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] w-[50px]">ID</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] w-[100px]">분류</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">설명</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] w-[160px]">위치</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] w-[60px]">리스크</th>
            </tr>
          </thead>
          <tbody>
            ${filtered.map((ap, i) => html`
              <tr key=${ap.id} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
                <td class="border-b border-[var(--color-border-default)] px-3 py-1.5 font-mono text-[var(--color-fg-muted)]">${ap.id}</td>
                <td class="border-b border-[var(--color-border-default)] px-3 py-1.5">
                  <span class="inline-block rounded border px-1.5 py-0.5 text-[10px] font-mono ${categoryColor(ap.category)}">
                    ${categoryLabel(ap.category)}
                  </span>
                </td>
                <td class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-[var(--color-fg-secondary)]">${ap.description}</td>
                <td class="border-b border-[var(--color-border-default)] px-3 py-1.5 font-mono text-[10px] text-[var(--color-fg-muted)]">${ap.location}</td>
                <td class="border-b border-[var(--color-border-default)] px-3 py-1.5">
                  <${StatusChip} tone=${riskTone(ap.risk)}>${riskLabel(ap.risk)}<//>
                </td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    </div>
  `
}
