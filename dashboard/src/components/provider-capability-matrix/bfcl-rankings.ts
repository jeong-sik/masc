// BfclRankings — BFCL Function Calling benchmark rankings.

import { html } from 'htm/preact'
import { BFCL_RANKINGS } from './data'

export function BfclRankings() {
  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-3 text-[10px] font-mono text-[var(--color-fg-muted)] px-1">
        <span>BFCL = 스키마 준수율 측정</span>
        <span class="text-[var(--color-border-default)]">|</span>
        <span>MCPMark = 작업 완료율 측정</span>
        <span class="text-[var(--color-border-default)]">|</span>
        <span>GPT-5: BFCL 7위(59.22%) vs MCPMark 1위(52.6%)</span>
      </div>

      <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
        <table class="w-full text-xs border-collapse">
          <thead>
            <tr class="bg-[var(--white-4)]">
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-center font-medium text-[var(--color-fg-secondary)] w-[40px]">#</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] min-w-[160px]">모델</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-right font-medium text-[var(--color-fg-secondary)] min-w-[90px]">BFCL V3</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-right font-medium text-[var(--color-fg-secondary)] min-w-[90px]">BFCL V4</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">특징</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] w-[90px]">라이선스</th>
            </tr>
          </thead>
          <tbody>
            ${BFCL_RANKINGS.map((entry, i) => {
              const hasV3 = entry.bfclV3 !== '—' && entry.bfclV3 !== '경쟁력' && entry.bfclV3 !== '개선됨'
              const hasV4 = entry.bfclV4 !== '—' && entry.bfclV4 !== '경쟁력'
              return html`
                <tr key=${entry.model} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-center font-mono text-[var(--color-fg-muted)]">${entry.rank}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 font-medium text-[var(--color-fg-primary)]">${entry.model}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-right font-mono ${
                    hasV3 ? 'text-[var(--color-fg-primary)]' : 'text-[var(--color-fg-muted)]'
                  }">
                    ${hasV3 ? html`<span class="font-bold">${entry.bfclV3}</span>` : entry.bfclV3}
                  </td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-right font-mono ${
                    hasV4 ? 'text-[#22c55e] font-bold' : 'text-[var(--color-fg-muted)]'
                  }">
                    ${hasV4 ? html`<span class="font-bold">${entry.bfclV4}</span>` : entry.bfclV4}
                  </td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-[var(--color-fg-secondary)]">${entry.feature}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2">
                    <span class="inline-block rounded px-1.5 py-0.5 text-[10px] font-mono ${
                      entry.license === '오픈웨이트' || entry.license === 'Apache 2.0' || entry.license === 'Modified MIT'
                        ? 'bg-[rgba(34,197,94,0.12)] text-[#22c55e]'
                        : 'bg-[var(--white-4)] text-[var(--color-fg-muted)]'
                    }">
                      ${entry.license}
                    </span>
                  </td>
                </tr>
              `
            })}
          </tbody>
        </table>
      </div>

      <div class="text-[10px] text-[var(--color-fg-muted)] px-1">
        출처: BFCL V3/V4 (UC Berkeley), MCPMark pass@1 (Sam Chon), SWE-Bench Pro (K2.6).
        Harness 패턴: Qwen 3.5 6.75%→100% (Typia 기반 검증-피드백-수정 루프).
      </div>
    </div>
  `
}
