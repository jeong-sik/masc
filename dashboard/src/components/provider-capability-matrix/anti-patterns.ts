// AntiPatternList — 32 anti-patterns with category filter and risk counts.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import {
  ANTI_PATTERNS,
  riskBucket,
  riskLabel,
  categoryLabel,
  categoryColor,
  SOURCE_LABEL,
  sourceColor,
} from './data'
import type { AntiPatternCategory } from './data'

const RISK_COLORS: Record<string, string> = {
  C: 'var(--color-status-err)',
  H: 'var(--rose-light)',
  M: 'var(--amber-bright)',
  L: 'var(--color-status-ok)',
}

function RiskDistBar({ counts }: { counts: { C: number; H: number; M: number; L: number } }) {
  const total = counts.C + counts.H + counts.M + counts.L
  if (total === 0) return null
  const entries = (['C', 'H', 'M', 'L'] as const).filter(k => counts[k] > 0)
  return html`
    <div class="flex w-full h-2 rounded-[var(--r-0)] overflow-hidden bg-[var(--color-bg-elevated)]">
      ${entries.map(key => html`
        <div style="width: ${(counts[key] / total * 100).toFixed(1)}%; background: ${RISK_COLORS[key]}"
             title="${riskLabel(key)}: ${counts[key]}건" class="h-full"></div>
      `)}
    </div>
  `
}

function CategoryRiskRow({ category }: { category: AntiPatternCategory }) {
  const items = ANTI_PATTERNS.filter(ap => ap.category === category)
  const counts = { C: 0, H: 0, M: 0, L: 0 }
  items.forEach(ap => counts[ap.risk]++)
  const total = items.length
  const highPct = total > 0 ? (counts.C + counts.H) / total : 0
  return html`
    <div class="flex items-center gap-2 py-0.5 px-2 rounded-[var(--r-1)] text-2xs bg-[var(--color-bg-surface)]">
      <span class="chip sm ${categoryColor(category)}">${categoryLabel(category)}</span>
      <span class="font-mono text-[var(--color-status-err)] w-4 text-right">${counts.C || '—'}</span>
      <span class="font-mono text-[var(--rose-light)] w-4 text-right">${counts.H || '—'}</span>
      <span class="font-mono text-[var(--amber-bright)] w-4 text-right">${counts.M || '—'}</span>
      <span class="font-mono w-4 text-right">${counts.L || '—'}</span>
      <div class="flex-1 h-1.5 rounded-[var(--r-0)] bg-[var(--color-bg-elevated)] overflow-hidden">
        <div style="width: ${(highPct * 100).toFixed(0)}%; background: linear-gradient(90deg, var(--color-status-err), var(--amber-bright))"
             class="h-full rounded-[var(--r-0)]"></div>
      </div>
      <span class="font-mono text-[var(--color-fg-muted)] w-4 text-right">${total}</span>
    </div>
  `
}

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
            class="pm-filter ${categoryFilter.value === 'all' ? 'is-active' : ''}"
            onClick=${() => { categoryFilter.value = 'all' }}
          >전체 (${ANTI_PATTERNS.length})</button>
          ${categories.map(cat => html`
            <button
              key=${cat}
              type="button"
              class="pm-filter ${categoryFilter.value === cat ? 'is-active' : ''}"
              onClick=${() => { categoryFilter.value = cat }}
            >${categoryLabel(cat)} (${ANTI_PATTERNS.filter(ap => ap.category === cat).length})</button>
          `)}
        </div>
        <div class="flex gap-2 t-caption">
          <span>C:<strong class="t-err">${riskCounts.C}</strong></span>
          <span>H:<strong class="t-err">${riskCounts.H}</strong></span>
          <span>M:<strong class="t-warn">${riskCounts.M}</strong></span>
          <span>L:<strong>${riskCounts.L}</strong></span>
        </div>
      </div>

      <div class="flex flex-col gap-2">
        <div class="flex items-center gap-3">
          <span class="text-3xs text-[var(--color-fg-muted)] w-16">리스크 분포</span>
          <div class="flex-1"><${RiskDistBar} counts=${riskCounts} /></div>
        </div>
        <div class="space-y-0.5">
          ${categories.map(cat => html`<${CategoryRiskRow} key=${cat} category=${cat} />`)}
        </div>
      </div>

      <div class="pm-scroll">
        <table class="pm-table">
          <thead class="pm-thead">
            <tr>
              <th class="pm-th w-[50px]">ID</th>
              <th class="pm-th w-[100px]">분류</th>
              <th class="pm-th">설명</th>
              <th class="pm-th w-[160px]">위치</th>
              <th class="pm-th w-[60px]">리스크</th>
              <th class="pm-th w-[60px]">출처</th>
              <th class="pm-th">개선 방향</th>
            </tr>
          </thead>
          <tbody>
            ${filtered.map((ap) => html`
              <tr key=${ap.id} class="pm-row-alt">
                <td class="pm-td pm-td--mono">${ap.id}</td>
                <td class="pm-td">
                  <span class="chip sm ${categoryColor(ap.category)}">
                    ${categoryLabel(ap.category)}
                  </span>
                </td>
                <td class="pm-td t-meta">${ap.description}</td>
                <td class="pm-td t-caption">${ap.location}</td>
                <td class="pm-td pm-td--center">
                  <span class="pm-cell-badge ${riskBucket(ap.risk)}" title=${[
                    ap.impact ? `영향: ${ap.impact}` : '',
                    ap.likelihood ? `발생: ${ap.likelihood}` : '',
                  ].filter(Boolean).join('\n') || riskLabel(ap.risk)}>${riskLabel(ap.risk)}</span>
                </td>
                <td class="pm-td">
                  <span class="chip sm ${sourceColor(ap.source)}">
                    ${SOURCE_LABEL[ap.source]}
                  </span>
                </td>
                <td class="pm-td t-micro t-meta">${ap.improvement}</td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    </div>
  `
}
