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
  SOURCE_LABEL,
  sourceColor,
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
                <td class="pm-td">
                  <${StatusChip} tone=${riskTone(ap.risk)}>${riskLabel(ap.risk)}<//>
                </td>
                <td class="pm-td">
                  <span class="chip sm ${sourceColor(ap.source)}">
                    ${SOURCE_LABEL[ap.source]}
                  </span>
                </td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    </div>
  `
}
