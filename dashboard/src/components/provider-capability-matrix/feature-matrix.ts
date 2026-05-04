// FeatureMatrix — 15 features × 13 providers with live provider overlay.
// Features grouped by sec01 §1.3 categories (Tool Use, Thinking, etc.).

import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import {
  FEATURES,
  PROVIDER_IDS,
  PROVIDER_LABELS,
  PROVIDER_CATEGORY,
  FEATURE_CATEGORIES,
  supportHeatBucket,
  computeMatrixSummary,
  runtimeProviderToMatrixId,
} from './data'
import { StatusDot } from '../common/status-dot'
import { StatTile } from '../common/stat-tile'
import { HeartbeatStrip } from '../common/heartbeat-strip'
import { statusLabel } from '../../lib/status-label'
import type { DashboardRuntimeProviderSnapshot } from '../../api/dashboard'
import {
  recordHeartbeat,
  useHeartbeatHistory,
  type HeartbeatState,
} from '../../lib/heartbeat-history'

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

function providerHeartbeatId(providerId: string): string {
  return `provider-capability:${providerId}`
}

function statusToHeartbeatSample(status: LiveStatus | null): HeartbeatState {
  if (status === null || status === 'neutral' || status === 'warn') return 'unknown'
  switch (status) {
    case 'ok':  return 'up'
    case 'bad': return 'down'
  }
}

function providerCategoryBadge(cat: string): string {
  switch (cat) {
    case 'cloud': return 'chip sm is-ok'
    case 'cli':   return 'chip sm is-warn'
    case 'local': return 'chip sm is-ghost'
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

function ProviderHeartbeatCell({
  providerId,
  status,
}: {
  providerId: string
  status: LiveStatus | null
}) {
  const history = useHeartbeatHistory(providerHeartbeatId(providerId))
  const label = status
    ? `${PROVIDER_LABELS[providerId] ?? providerId}: ${statusLabel(status)}`
    : `${PROVIDER_LABELS[providerId] ?? providerId}: 데이터 없음`
  return html`<${HeartbeatStrip} history=${history} slots=${HB_SLOTS} ariaLabel=${label} />`
}

export function FeatureMatrix({ liveProviders }: { liveProviders: DashboardRuntimeProviderSnapshot[] }) {
  const summary = useMemo(() => computeMatrixSummary(), [])
  const cloudCount = Object.values(PROVIDER_CATEGORY).filter(c => c === 'cloud').length
  const localCount = Object.values(PROVIDER_CATEGORY).filter(c => c === 'local').length
  const cliCount = Object.values(PROVIDER_CATEGORY).filter(c => c === 'cli').length

  useEffect(() => {
    const sampled = new Set<string>()
    for (const p of liveProviders) {
      const matrixId = runtimeProviderToMatrixId(p.provider, p.runtime_kind ?? p.kind)
      if (!matrixId || sampled.has(matrixId)) continue
      sampled.add(matrixId)
      recordHeartbeat(providerHeartbeatId(matrixId), statusToHeartbeatSample(liveProviderStatus(p)))
    }
  }, [liveProviders])

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

      <div class="pm-scroll">
        <table class="pm-table">
          <thead class="pm-thead">
            <tr>
              <th class="pm-th pm-th--sticky min-w-[140px]">
                기능
              </th>
              ${PROVIDER_IDS.map(pid => {
                const dot = liveStatusDot(pid, liveProviders)
                const cat = PROVIDER_CATEGORY[pid] ?? 'cloud'
                return html`
                  <th key=${pid} class="pm-th pm-th--center min-w-[60px]">
                    <div class="flex flex-col items-center gap-0.5">
                      ${dot ? html`<${StatusDot} size="xs" class=${liveStatusDotClass(dot)} />` : null}
                      <span>${PROVIDER_LABELS[pid] ?? pid}</span>
                      <span class="${providerCategoryBadge(cat)}">${providerCategoryLabel(cat)}</span>
                    </div>
                  </th>
                `
              })}
            </tr>
            <tr>
              <th class="pm-th pm-th--sticky"></th>
              ${PROVIDER_IDS.map(pid => {
                const dot = liveStatusDot(pid, liveProviders)
                return html`
                  <th key=${pid} class="pm-th pm-th--center">
                    <${ProviderHeartbeatCell} providerId=${pid} status=${dot} />
                  </th>
                `
              })}
            </tr>
          </thead>
        <tbody>
          ${FEATURE_CATEGORIES.map(cat => {
            const catFeatures = cat.featureIds.map(id => featById.get(id)).filter(Boolean)
            return html`
              <tr key=${`cat-${cat.id}`} class="pm-cat-row">
                <td class="pm-th--sticky" colSpan=${PROVIDER_IDS.length + 1}>
                  ${cat.label}
                </td>
              </tr>
              ${catFeatures.map((feat, j) => {
                if (!feat) return null
                const rowClass = j % 2 !== 0 ? 'pm-row--alt' : ''
                return html`
                  <tr key=${feat.id} class="${rowClass}">
                    <td class="pm-td pm-td--sticky pm-td--indent">
                      ${feat.label}
                    </td>
                    ${PROVIDER_IDS.map(pid => {
                      const v = feat.providers[pid] ?? '—'
                      return html`
                        <td key=${pid} class="pm-td pm-td--center">
                          <span class="pm-cell-badge ${supportHeatBucket(v)}">
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
    <div class="flex items-center gap-4 t-caption px-1 flex-wrap">
      <span class="flex items-center gap-1"><span class="chip sm is-ok">●</span> 네이티브</span>
      <span class="flex items-center gap-1"><span class="chip sm is-warn">◐</span> 부분 지원</span>
      <span class="flex items-center gap-1"><span class="chip sm is-err">○</span> 미지원</span>
      <span class="text-[var(--color-border-default)]">|</span>
      <span class="flex items-center gap-1"><${StatusDot} size="xs" class="bg-[var(--color-status-ok)]" /> 런타임 활성</span>
      <span class="flex items-center gap-1"><${StatusDot} size="xs" class="bg-[var(--color-status-err)]" /> 런타임 오류</span>
      <span class="text-[var(--color-border-default)]">|</span>
      <span class="flex items-center gap-1"><span class="${providerCategoryBadge('cloud')}">Cloud</span> API 직접</span>
      <span class="flex items-center gap-1"><span class="${providerCategoryBadge('cli')}">CLI</span> Subprocess</span>
      <span class="flex items-center gap-1"><span class="${providerCategoryBadge('local')}">Local</span> Self-hosted</span>
    </div>
  `
}
