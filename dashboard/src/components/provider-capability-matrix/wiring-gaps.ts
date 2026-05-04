// WiringGaps — OAS wiring mismatches vs official API support.
// Severity-sorted (HIGH → MEDIUM → LOW) with summary stat tiles
// and per-provider gap count chips.

import { html } from 'htm/preact'
import { StatusChip } from '../common/status-chip'
import { StatTile } from '../common/stat-tile'
import { WIRING_GAPS, impactTone, impactBucket } from './data'

const SEVERITY_ORDER: Record<string, number> = { high: 0, medium: 1, low: 2, correct: 3 }
const severityRank = (impact: string): number => SEVERITY_ORDER[impact] ?? 99

const IMPACT_COLORS: Record<string, string> = {
  high: 'var(--color-status-err)',
  medium: 'var(--amber-bright)',
  low: 'var(--color-fg-muted)',
}

function SeverityDistBar({ high, medium, low }: { high: number; medium: number; low: number }) {
  const total = high + medium + low
  if (total === 0) return null
  const entries = ([['high', high], ['medium', medium], ['low', low]] as const).filter(([, c]) => c > 0)
  return html`
    <div class="flex w-full h-2 rounded-[var(--r-0)] overflow-hidden bg-[var(--color-bg-elevated)]">
      ${entries.map(([key, count]) => html`
        <div style="width: ${(count / total * 100).toFixed(1)}%; background: ${IMPACT_COLORS[key]}"
             title="${key}: ${count}건" class="h-full"></div>
      `)}
    </div>
  `
}

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
  const maxProviderGaps = providerCounts[0]?.[1] ?? 1

  return html`
    <div class="flex flex-col gap-3">
      <div class="grid grid-cols-4 gap-2">
        <${StatTile} label="HIGH" value=${high} status="crit" delta=${{ direction: 'down', text: 'tool calling 직접 영향' }} />
        <${StatTile} label="MEDIUM" value=${medium} status="warn" delta=${{ direction: 'flat', text: '기능 제한' }} />
        <${StatTile} label="LOW" value=${low} delta=${{ direction: 'flat', text: '사소한 불일치' }} />
        <${StatTile} label="정확" value=${correct.length} status="ok" delta=${{ direction: 'up', text: `${WIRING_GAPS.length} 중` }} />
      </div>

      <div class="flex items-center gap-3">
        <span class="text-3xs text-[var(--color-fg-muted)] w-16">심각도 분포</span>
        <div class="flex-1"><${SeverityDistBar} high=${high} medium=${medium} low=${low} /></div>
      </div>

      <div class="flex flex-col gap-1">
        <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">프로바이더별 갭</div>
        ${providerCounts.map(([prov, cnt]) => {
          const barWidth = (cnt / maxProviderGaps) * 100
          return html`
            <div class="flex items-center gap-2 py-0.5" key=${prov}>
              <span class="w-28 flex-shrink-0 text-2xs font-medium truncate" title=${prov}>${prov}</span>
              <div class="flex-1 h-2 rounded-[var(--r-0)] bg-[var(--color-bg-elevated)] overflow-hidden">
                <div class="h-full rounded-[var(--r-0)]" style="width: ${barWidth}%; background: var(--color-accent-fg); opacity: 0.6"></div>
              </div>
              <span class="w-4 text-right text-2xs font-mono text-[var(--color-fg-muted)]">${cnt}</span>
            </div>
          `
        })}
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
                <tr key=${gap.id} class="pm-wg-row pm-wg-row--${impactBucket(gap.impact)}">
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
