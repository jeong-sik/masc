// FeatureMatrix — 15 features × 13 providers with live provider overlay.

import { html } from 'htm/preact'
import {
  FEATURES,
  PROVIDER_IDS,
  PROVIDER_LABELS,
  supportCellClass,
  runtimeKindToMatrixId,
} from './data'
import type { DashboardRuntimeProviderSnapshot } from '../../api/dashboard'

function liveStatusDot(
  providerId: string,
  liveProviders: DashboardRuntimeProviderSnapshot[],
): string | null {
  for (const p of liveProviders) {
    const matrixId = runtimeKindToMatrixId(p.kind)
    if (matrixId === providerId) {
      if (p.available) return 'available'
      if (p.status === 'error') return 'error'
      return 'unknown'
    }
  }
  return null
}

export function FeatureMatrix({ liveProviders }: { liveProviders: DashboardRuntimeProviderSnapshot[] }) {
  return html`
    <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
      <table class="w-full text-xs border-collapse">
        <thead>
          <tr class="bg-[var(--white-4)]">
            <th class="sticky left-0 z-10 bg-[var(--shell-rail-bg)] border-b border-r border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] min-w-[140px]">
              기능
            </th>
            ${PROVIDER_IDS.map(pid => {
              const dot = liveStatusDot(pid, liveProviders)
              const dotColor = dot === 'available'
                ? 'bg-[#22c55e]'
                : dot === 'error'
                  ? 'bg-[#ef4444]'
                  : dot ? 'bg-[var(--white-25)]' : ''
              return html`
                <th key=${pid} class="border-b border-[var(--color-border-default)] px-1.5 py-1.5 text-center font-medium text-[var(--color-fg-secondary)] min-w-[60px]">
                  <div class="flex flex-col items-center gap-0.5">
                    ${dotColor ? html`<span class="size-1.5 rounded-full ${dotColor}"></span>` : null}
                    <span>${PROVIDER_LABELS[pid] ?? pid}</span>
                  </div>
                </th>
              `
            })}
          </tr>
        </thead>
        <tbody>
          ${FEATURES.map((feat, i) => html`
            <tr key=${feat.id} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
              <td class="sticky left-0 z-10 ${i % 2 === 0 ? 'bg-[var(--shell-rail-bg)]' : 'bg-[var(--white-2)]'} border-r border-[var(--color-border-default)] px-2 py-1 font-medium text-[var(--color-fg-primary)]">
                ${feat.label}
              </td>
              ${PROVIDER_IDS.map(pid => {
                const v = feat.providers[pid] ?? '—'
                return html`
                  <td key=${pid} class="border-b border-[var(--color-border-default)] px-1 py-0.5 text-center">
                    <span class="inline-block w-full rounded px-1 py-0.5 text-[10px] font-mono font-bold ${supportCellClass(v)}">
                      ${v}
                    </span>
                  </td>
                `
              })}
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

export function MatrixLegend() {
  return html`
    <div class="flex items-center gap-4 text-[10px] font-mono text-[var(--color-fg-muted)] px-1">
      <span class="flex items-center gap-1"><span class="inline-block w-4 h-3 rounded bg-[rgba(34,197,94,0.15)] text-center text-[#22c55e]">●</span> 네이티브</span>
      <span class="flex items-center gap-1"><span class="inline-block w-4 h-3 rounded bg-[rgba(234,179,8,0.15)] text-center text-[#eab308]">◐</span> 부분 지원</span>
      <span class="flex items-center gap-1"><span class="inline-block w-4 h-3 rounded bg-[rgba(239,68,68,0.1)] text-center text-[#ef4444]">○</span> 미지원</span>
      <span class="flex items-center gap-1"><span class="inline-block size-1.5 rounded-full bg-[#22c55e]"></span> 런타임 활성</span>
      <span class="flex items-center gap-1"><span class="inline-block size-1.5 rounded-full bg-[#ef4444]"></span> 런타임 오류</span>
    </div>
  `
}
