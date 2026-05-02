// WiringGaps — OAS wiring mismatches vs official API support.

import { html } from 'htm/preact'
import { StatusChip } from '../common/status-chip'
import { WIRING_GAPS, impactTone } from './data'

export function WiringGaps() {
  const gaps = WIRING_GAPS.filter(g => g.impact !== 'correct')
  const correct = WIRING_GAPS.filter(g => g.impact === 'correct')

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-3 text-[10px] font-mono text-[var(--color-fg-muted)] px-1">
        <span>과소선언: ${gaps.length}건</span>
        <span class="text-[var(--color-border-default)]">|</span>
        <span>정확한 선언: ${correct.length}건</span>
      </div>

      <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
        <table class="w-full text-xs border-collapse">
          <thead>
            <tr class="bg-[var(--white-4)]">
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">ID</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">프로바이더</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">기능</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">OAS 선언</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">실제 동작</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">영향도</th>
            </tr>
          </thead>
          <tbody>
            ${WIRING_GAPS.map((gap, i) => {
              const isCorrect = gap.impact === 'correct'
              return html`
                <tr key=${gap.id} class="${isCorrect ? 'opacity-60' : i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 font-mono text-[var(--color-fg-muted)]">${gap.id}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 font-medium text-[var(--color-fg-primary)]">${gap.provider}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-[var(--color-fg-secondary)]">${gap.capability}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 font-mono text-[var(--color-fg-muted)]">${gap.oasDeclares}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-[var(--color-fg-secondary)]">${gap.actualBehavior}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2">
                    <${StatusChip} tone=${impactTone(gap.impact)}>${isCorrect ? 'OK' : gap.impact.toUpperCase()}<//>
                  </td>
                </tr>
              `
            })}
          </tbody>
        </table>
      </div>
    </div>
  `
}
