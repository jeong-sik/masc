// WiringGaps — OAS wiring mismatches vs official API support.
// Severity-sorted (HIGH → MEDIUM → LOW) with summary stat tiles
// and per-provider gap count chips.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { StatusChip } from '../common/status-chip'
import { StatTile } from '../common/stat-tile'
import { WIRING_GAPS, impactTone } from './data'

const SEVERITY_ORDER: Record<string, number> = { high: 0, medium: 1, low: 2, correct: 3 }
const severityRank = (impact: string): number => SEVERITY_ORDER[impact] ?? 99

export function WiringGaps() {
  const sorted = useMemo(() =>
    [...WIRING_GAPS].sort((a, b) => severityRank(a.impact) - severityRank(b.impact)),
    [],
  )
  const gaps = sorted.filter(g => g.impact !== 'correct')
  const correct = sorted.filter(g => g.impact === 'correct')
  const high = gaps.filter(g => g.impact === 'high').length
  const medium = gaps.filter(g => g.impact === 'medium').length
  const low = gaps.filter(g => g.impact === 'low').length

  const providerCounts = useMemo(() => {
    const m = new Map<string, number>()
    for (const g of gaps) m.set(g.provider, (m.get(g.provider) ?? 0) + 1)
    return [...m.entries()].sort((a, b) => b[1] - a[1])
  }, [gaps.length])

  return html`
    <div class="flex flex-col gap-3">
      <div class="grid grid-cols-4 gap-2">
        <${StatTile} label="HIGH" value=${high} variant="warn" hint="tool calling 직접 영향" />
        <${StatTile} label="MEDIUM" value=${medium} hint="기능 제한" />
        <${StatTile} label="LOW" value=${low} hint="사소한 불일치" />
        <${StatTile} label="정확" value=${correct.length} variant="gold" hint=${`${WIRING_GAPS.length} 중`} />
      </div>

      <div class="flex items-center gap-2 flex-wrap text-[10px] font-mono text-[var(--color-fg-muted)] px-1">
        ${providerCounts.map(([prov, cnt]) => html`
          <span key=${prov} class="inline-flex items-center gap-1">
            <span class="font-medium text-[var(--color-fg-secondary)]">${prov}</span>
            <span class="text-[var(--color-fg-disabled)]">${cnt}건</span>
          </span>
        `)}
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
            ${gaps.map((gap, i) => {
              return html`
                <tr key=${gap.id} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 font-mono text-[var(--color-fg-muted)]">${gap.id}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 font-medium text-[var(--color-fg-primary)]">${gap.provider}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-[var(--color-fg-secondary)]">${gap.capability}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 font-mono text-[var(--color-fg-muted)]">${gap.oasDeclares}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-[var(--color-fg-secondary)]">${gap.actualBehavior}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2">
                    <${StatusChip} tone=${impactTone(gap.impact)}>${gap.impact.toUpperCase()}<//>
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
