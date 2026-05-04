// WiringGaps — OAS wiring mismatches vs official API support.
// Severity-sorted (HIGH → MEDIUM → LOW) with summary stat tiles
// and per-provider gap count chips.

import { html } from 'htm/preact'
import { StatusChip } from '../common/status-chip'
import { StatTile } from '../common/stat-tile'
import { WIRING_GAPS, impactTone } from './data'

const SEVERITY_ORDER: Record<string, number> = { high: 0, medium: 1, low: 2, correct: 3 }
const severityRank = (impact: string): number => SEVERITY_ORDER[impact] ?? 99

export function WiringGaps() {
  const sorted = [...WIRING_GAPS].sort((a, b) => severityRank(a.impact) - severityRank(b.impact))
  const gaps = sorted.filter(g => g.impact !== 'correct')
  const correct = sorted.filter(g => g.impact === 'correct')
  const high = gaps.filter(g => g.impact === 'high').length
  const medium = gaps.filter(g => g.impact === 'medium').length
  const low = gaps.filter(g => g.impact === 'low').length

  const providerCountMap = new Map<string, number>()
  for (const g of gaps) providerCountMap.set(g.provider, (providerCountMap.get(g.provider) ?? 0) + 1)
  const providerCounts = [...providerCountMap.entries()].sort((a, b) => b[1] - a[1])

  return html`
    <div class="flex flex-col gap-3">
      <div class="grid grid-cols-4 gap-2">
        <${StatTile} label="HIGH" value=${high} variant="warn" hint="tool calling 직접 영향" />
        <${StatTile} label="MEDIUM" value=${medium} hint="기능 제한" />
        <${StatTile} label="LOW" value=${low} hint="사소한 불일치" />
        <${StatTile} label="정확" value=${correct.length} variant="gold" hint=${`${WIRING_GAPS.length} 중`} />
      </div>

      <div class="flex items-center gap-2 flex-wrap t-micro mono t-dim px-1">
        ${providerCounts.map(([prov, cnt]) => html`
          <span key=${prov} class="inline-flex items-center gap-1">
            <span class="font-semibold t-meta">${prov}</span>
            <span class="t-dim">${cnt}건</span>
          </span>
        `)}
      </div>

      <div class="pm-scroll">
        <table class="pm-table">
          <thead class="pm-thead">
            <tr>
              <th class="pm-th">ID</th>
              <th class="pm-th">프로바이더</th>
              <th class="pm-th">기능</th>
              <th class="pm-th">OAS 선언</th>
              <th class="pm-th">실제 동작</th>
              <th class="pm-th">영향도</th>
            </tr>
          </thead>
          <tbody>
            ${gaps.map((gap) => {
              return html`
                <tr key=${gap.id} class="pm-row-alt">
                  <td class="pm-td pm-td--mono t-dim">${gap.id}</td>
                  <td class="pm-td font-semibold">${gap.provider}</td>
                  <td class="pm-td t-meta">${gap.capability}</td>
                  <td class="pm-td pm-td--mono t-dim">${gap.oasDeclares}</td>
                  <td class="pm-td t-meta">${gap.actualBehavior}</td>
                  <td class="pm-td">
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
