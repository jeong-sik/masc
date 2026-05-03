// FeatureMatrix — 15 features × 13 providers with live provider overlay.
// Features grouped by sec01 §1.3 categories (Tool Use, Thinking, etc.).

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import {
  FEATURES,
  PROVIDER_IDS,
  PROVIDER_LABELS,
  PROVIDER_CATEGORY,
  FEATURE_CATEGORIES,
  supportCellClass,
  computeMatrixSummary,
  runtimeProviderToMatrixId,
} from './data'
import { StatusDot } from '../common/status-dot'
import { StatTile } from '../common/stat-tile'
import { HeartbeatStrip } from '../common/heartbeat-strip'
import { statusLabel } from '../../lib/status-label'
import type { DashboardRuntimeProviderSnapshot } from '../../api/dashboard'
import type { HeartbeatState } from '../../lib/heartbeat-history'

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

const HB_SLOTS = 12

function statusToSlots(status: LiveStatus | null): HeartbeatState[] {
  if (status === null || status === 'neutral') return Array<HeartbeatState>(HB_SLOTS).fill('unknown')
  switch (status) {
    case 'ok':   return Array<HeartbeatState>(HB_SLOTS).fill('up')
    case 'bad':  return Array<HeartbeatState>(HB_SLOTS).fill('down')
    case 'warn': return Array<HeartbeatState>(HB_SLOTS).fill('down')
  }
}

function providerCategoryBadge(cat: string): string {
  switch (cat) {
    case 'cloud': return 'bg-[var(--ok-10)] text-[var(--color-status-ok)]'
    case 'cli':   return 'bg-[var(--warn-10)] text-[var(--color-status-warn)]'
    case 'local': return 'bg-[var(--white-4)] text-[var(--color-fg-muted)]'
    default:      return ''
  }
}

function providerCategoryLabel(cat: string): string {
  switch (cat) {
    case 'cloud': return 'Cloud'
    case 'cli':   return 'CLI'
    case 'local': return 'Local'
    default:      return ''
  }
}

const featById = new Map(FEATURES.map(f => [f.id, f]))

export function FeatureMatrix({ liveProviders }: { liveProviders: DashboardRuntimeProviderSnapshot[] }) {
  const summary = useMemo(() => computeMatrixSummary(), [])
  const cloudCount = Object.values(PROVIDER_CATEGORY).filter(c => c === 'cloud').length
  const localCount = Object.values(PROVIDER_CATEGORY).filter(c => c === 'local').length
  const cliCount = Object.values(PROVIDER_CATEGORY).filter(c => c === 'cli').length

  return html`
    <div class="flex flex-col gap-2">
      <div class="grid grid-cols-6 gap-2">
        <${StatTile} label="네이티브" value=${summary.native} variant="gold" hint=${`${((summary.native / summary.total) * 100).toFixed(0)}%`} />
        <${StatTile} label="부분 지원" value=${summary.partial} hint="◐" />
        <${StatTile} label="미지원" value=${summary.unsupported} variant="warn" hint="○" />
        <${StatTile} label="Cloud API" value=${cloudCount} hint="direct" />
        <${StatTile} label="Local" value=${localCount} hint="self-host" />
        <${StatTile} label="CLI Wrapper" value=${cliCount} hint="usage: strip" />
      </div>

      <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
        <table class="w-full text-xs border-collapse">
          <thead>
            <tr class="bg-[var(--white-4)]">
              <th class="sticky left-0 z-10 bg-[var(--shell-rail-bg)] border-b border-r border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] min-w-[140px]">
                기능
              </th>
              ${PROVIDER_IDS.map(pid => {
                const dot = liveStatusDot(pid, liveProviders)
                const cat = PROVIDER_CATEGORY[pid] ?? 'cloud'
                return html`
                  <th key=${pid} class="border-b border-[var(--color-border-default)] px-1.5 py-1.5 text-center font-medium text-[var(--color-fg-secondary)] min-w-[60px]">
                    <div class="flex flex-col items-center gap-0.5">
                      ${dot ? html`<${StatusDot} size="xs" class=${liveStatusDotClass(dot)} />` : null}
                      <span>${PROVIDER_LABELS[pid] ?? pid}</span>
                      <span class="inline-block rounded px-1 py-px text-[7px] font-mono font-bold ${providerCategoryBadge(cat)}">${providerCategoryLabel(cat)}</span>
                    </div>
                  </th>
                `
              })}
            </tr>
            <tr class="bg-[var(--white-4)]">
              <th class="sticky left-0 z-10 bg-[var(--shell-rail-bg)] border-b border-r border-[var(--color-border-default)]"></th>
              ${PROVIDER_IDS.map(pid => {
                const dot = liveStatusDot(pid, liveProviders)
                const hb = statusToSlots(dot)
                const label = dot ? `${PROVIDER_LABELS[pid] ?? pid}: ${statusLabel(dot)}` : `${PROVIDER_LABELS[pid] ?? pid}: 데이터 없음`
                return html`
                  <th key=${pid} class="border-b border-[var(--color-border-default)] px-1 py-0.5">
                    <${HeartbeatStrip} history=${hb} slots=${HB_SLOTS} ariaLabel=${label} />
                  </th>
                `
              })}
            </tr>
          </thead>
        <tbody>
          ${FEATURE_CATEGORIES.map(cat => {
            const catFeatures = cat.featureIds.map(id => featById.get(id)).filter(Boolean)
            return html`
              <tr key=${`cat-${cat.id}`} class="bg-[var(--white-4)]">
                <td class="sticky left-0 z-10 bg-[var(--white-4)] border-r border-b border-[var(--color-border-default)] px-2 py-1 text-[10px] font-semibold text-[var(--color-fg-muted)] uppercase tracking-wider" colSpan=${PROVIDER_IDS.length + 1}>
                  ${cat.label}
                </td>
              </tr>
              ${catFeatures.map((feat, j) => {
                if (!feat) return null
                return html`
                  <tr key=${feat.id} class="${j % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
                    <td class="sticky left-0 z-10 ${j % 2 === 0 ? 'bg-[var(--shell-rail-bg)]' : 'bg-[var(--white-2)]'} border-r border-b border-[var(--color-border-default)] px-2 py-1 pl-4 font-medium text-[var(--color-fg-primary)]">
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
                `
              })}
            `
          })}
        </tbody>
      </table>
      </div>
    </div>
  `
}

export function MatrixLegend() {
  return html`
    <div class="flex items-center gap-4 text-[10px] font-mono text-[var(--color-fg-muted)] px-1 flex-wrap">
      <span class="flex items-center gap-1"><span class="inline-block w-4 h-3 rounded bg-[var(--ok-10)] text-center text-[var(--color-status-ok)]">●</span> 네이티브</span>
      <span class="flex items-center gap-1"><span class="inline-block w-4 h-3 rounded bg-[var(--warn-10)] text-center text-[var(--color-status-warn)]">◐</span> 부분 지원</span>
      <span class="flex items-center gap-1"><span class="inline-block w-4 h-3 rounded bg-[var(--bad-10)] text-center text-[var(--bad-light)]">○</span> 미지원</span>
      <span class="text-[var(--color-border-default)]">|</span>
      <span class="flex items-center gap-1"><${StatusDot} size="xs" class="bg-[var(--color-status-ok)]" /> 런타임 활성</span>
      <span class="flex items-center gap-1"><${StatusDot} size="xs" class="bg-[var(--color-status-err)]" /> 런타임 오류</span>
      <span class="text-[var(--color-border-default)]">|</span>
      <span class="flex items-center gap-1"><span class="inline-block rounded px-1 py-px text-[7px] font-bold ${providerCategoryBadge('cloud')}">Cloud</span> API 직접</span>
      <span class="flex items-center gap-1"><span class="inline-block rounded px-1 py-px text-[7px] font-bold ${providerCategoryBadge('cli')}">CLI</span> Subprocess</span>
      <span class="flex items-center gap-1"><span class="inline-block rounded px-1 py-px text-[7px] font-bold ${providerCategoryBadge('local')}">Local</span> Self-hosted</span>
    </div>
  `
}
