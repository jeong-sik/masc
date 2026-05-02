// FeatureMatrix — 15 features × 13 providers with live provider overlay.

import { html } from 'htm/preact'
import {
  FEATURES,
  PROVIDER_IDS,
  PROVIDER_LABELS,
  supportCellClass,
  runtimeProviderToMatrixId,
} from './data'
import { StatusDot } from '../common/status-dot'
import type { DashboardRuntimeProviderSnapshot } from '../../api/dashboard'

type LiveStatus = 'ok' | 'bad' | 'warn' | 'neutral'

function liveProviderStatus(provider: DashboardRuntimeProviderSnapshot): LiveStatus {
  const advertised = provider.status?.trim().toLowerCase()
  if (
    provider.available === false ||
    advertised === 'error' ||
    advertised === 'failed' ||
    advertised === 'missing_auth' ||
    advertised === 'unsupported' ||
    advertised === 'offline'
  ) {
    return 'bad'
  }
  if (advertised === 'vertex_adc' || provider.discovery?.healthy === false) return 'warn'
  if (provider.available === true) return 'ok'
  return 'neutral'
}

function liveStatusDotClass(status: LiveStatus): string {
  switch (status) {
    case 'ok': return 'bg-[var(--color-status-ok)]'
    case 'bad': return 'bg-[var(--color-status-err)]'
    case 'warn': return 'bg-[var(--color-status-warn)]'
    case 'neutral': return 'bg-[var(--white-25)]'
  }
}

export function liveStatusDot(
  providerId: string,
  liveProviders: DashboardRuntimeProviderSnapshot[],
): LiveStatus | null {
  for (const p of liveProviders) {
    const matrixId = runtimeProviderToMatrixId(p.provider, p.runtime_kind ?? p.kind)
    if (matrixId === providerId) {
      return liveProviderStatus(p)
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
              return html`
                <th key=${pid} class="border-b border-[var(--color-border-default)] px-1.5 py-1.5 text-center font-medium text-[var(--color-fg-secondary)] min-w-[60px]">
                  <div class="flex flex-col items-center gap-0.5">
                    ${dot ? html`<${StatusDot} size="xs" class=${liveStatusDotClass(dot)} />` : null}
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
      <span class="flex items-center gap-1"><span class="inline-block w-4 h-3 rounded bg-[var(--ok-10)] text-center text-[var(--color-status-ok)]">●</span> 네이티브</span>
      <span class="flex items-center gap-1"><span class="inline-block w-4 h-3 rounded bg-[var(--warn-10)] text-center text-[var(--color-status-warn)]">◐</span> 부분 지원</span>
      <span class="flex items-center gap-1"><span class="inline-block w-4 h-3 rounded bg-[var(--bad-10)] text-center text-[var(--bad-light)]">○</span> 미지원</span>
      <span class="flex items-center gap-1"><${StatusDot} size="xs" class="bg-[var(--color-status-ok)]" /> 런타임 활성</span>
      <span class="flex items-center gap-1"><${StatusDot} size="xs" class="bg-[var(--color-status-err)]" /> 런타임 오류</span>
    </div>
  `
}
