// Feature Health panel — feature flag status and health monitoring.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { capitalize } from '../lib/format-string'
import { get } from '../api/core'
import { createAsyncResource, type AsyncResource } from '../lib/async-state'
import { formatTimeAgo } from '../lib/format-time'
import { AsyncContainer } from './common/async-container'
import { SectionCard, SurfaceCard } from './common/card'
import { FilterChips } from './common/filter-chips'
import { TextInput } from './common/input'
import { SectionCap } from './common/section-cap'
import { StatusChip, type StatusChipTone } from './common/status-chip'
import { KpiStripView, type KpiStripViewData } from './kpi-strip-view'

type FeatureStatus = 'healthy' | 'warning' | 'inactive' | 'deprecated'
type StatusFilter = FeatureStatus | 'all'

interface FeatureHealthItem {
  env_name: string
  description: string
  category: string
  lifecycle: string
  is_enabled: boolean
  source: string
  status: FeatureStatus
  since: string
}

interface FeatureHealthOverview {
  total_features: number
  healthy_count: number
  warning_count: number
  inactive_count: number
  deprecated_count: number
  enabled_count: number
  overridden_count: number
}

interface FeatureHealthData {
  generated_at: number
  overview: FeatureHealthOverview
  features_by_category: {
    [category: string]: {
      total: number
      enabled: number
      features: FeatureHealthItem[]
    }
  }
  all_features: FeatureHealthItem[]
}

const featureHealth: AsyncResource<FeatureHealthData> = createAsyncResource()

// Filter state (module-scoped so filter survives re-renders / refreshes).
const statusFilter = signal<StatusFilter>('all')
const searchQuery = signal('')

const STATUS_FILTER_OPTIONS: { value: StatusFilter; label: string }[] = [
  { value: 'all', label: '전체' },
  { value: 'healthy', label: '정상' },
  { value: 'warning', label: '실험적' },
  { value: 'inactive', label: '비활성' },
  { value: 'deprecated', label: '폐기 예정' },
]

// Pure filter helpers — exported for isolated testing.
function featureMatchesSearch(
  item: Pick<FeatureHealthItem, 'env_name' | 'description'>,
  query: string,
): boolean {
  const q = query.trim().toLowerCase()
  if (q === '') return true
  return (
    item.env_name.toLowerCase().includes(q) ||
    item.description.toLowerCase().includes(q)
  )
}

function featureMatchesStatus(
  item: Pick<FeatureHealthItem, 'status'>,
  status: StatusFilter,
): boolean {
  if (status === 'all') return true
  return item.status === status
}

function filterFeatures<
  T extends Pick<FeatureHealthItem, 'env_name' | 'description' | 'status'>,
>(features: T[], query: string, status: StatusFilter): T[] {
  const q = query.trim().toLowerCase()
  if (q === '' && status === 'all') return features
  return features.filter(
    (f) => featureMatchesSearch(f, q) && featureMatchesStatus(f, status),
  )
}

function loadFeatureHealth(): Promise<void> {
  return featureHealth.load(() => get<FeatureHealthData>('/api/v1/dashboard/feature-health'))
}

export async function refreshFeatureHealth(): Promise<void> {
  await loadFeatureHealth()
}

/**
 * Feature-health-domain status → 한국어 라벨.
 *
 * Distinct from `statusLabel` in `lib/status-label.ts` (which handles every
 * runtime/agent status enum). FeatureStatus is a closed 4-enum
 * (`'healthy' | 'warning' | 'inactive' | 'deprecated'`) with feature-flag
 * semantics — 'warning' here means "실험적 (experimental)", not "경고"
 * which is what lib/status-label maps it to.
 *
 * Renamed from `statusLabel` to `featureStatusLabel` on 2026-05-27 to close
 * the SSOT collision: same function name with incompatible semantics across
 * two modules was an operator-confusion source.
 */
export function featureStatusLabel(status: FeatureStatus): string {
  switch (status) {
    case 'healthy':
      return '정상'
    case 'warning':
      return '실험적'
    case 'inactive':
      return '비활성'
    case 'deprecated':
    default:
      return '폐기 예정'
  }
}

type FeatureHealthTone = Extract<StatusChipTone, 'ok' | 'warn' | 'neutral' | 'bad'>

function statusChipTone(status: FeatureStatus): FeatureHealthTone {
  switch (status) {
    case 'healthy':
      return 'ok'
    case 'warning':
      return 'warn'
    case 'inactive':
      return 'neutral'
    case 'deprecated':
    default:
      return 'bad'
  }
}

function StatusPill({ status }: { status: FeatureStatus }) {
  return html`
    <${StatusChip} tone=${statusChipTone(status)}>${featureStatusLabel(status)}<//>
  `
}

function FeatureItem({ item }: { item: FeatureHealthItem }) {
  return html`
    <${SurfaceCard} variant="compact">
      <div class="flex items-start justify-between gap-3">
        <div class="flex-1">
          <div class="flex items-center gap-2">
            <code class="text-xs font-medium text-[var(--color-fg-primary)]">${item.env_name}</code>
            <${StatusPill} status=${item.status} />
            <${StatusChip} tone=${item.is_enabled ? 'ok' : 'neutral'}>${item.is_enabled ? 'ON' : 'OFF'}<//>
          </div>
          <div class="mt-1.5 text-sm text-[var(--color-fg-secondary)]">${item.description}</div>
          <div class="mt-1 flex items-center gap-3 text-xs text-[var(--color-fg-muted)]">
            <span>source: ${item.source}</span>
            <span>since: v${item.since}</span>
          </div>
        </div>
      </div>
    <//>
  `
}

function CategorySection({ category, categoryData }: { category: string; categoryData: { total: number; enabled: number; features: FeatureHealthItem[] } }) {
  const categoryLabel = capitalize(category)
  const enabledRatio = categoryData.total > 0 ? Math.round((categoryData.enabled / categoryData.total) * 100) : 0

  return html`
    <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
      <div class="mb-3 flex items-center justify-between">
        <div>
          <div class="text-sm font-medium text-[var(--color-fg-primary)]">${categoryLabel}</div>
          <div class="mt-0.5 text-xs text-[var(--color-fg-muted)]">
            ${categoryData.enabled} / ${categoryData.total} enabled (${enabledRatio}%)
          </div>
        </div>
        <div class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-hover)] px-3 py-1 text-xs font-semibold text-[var(--color-fg-secondary)]">
          ${categoryData.total}
        </div>
      </div>
      <div class="space-y-2">
        ${categoryData.features.map(feature => html`<${FeatureItem} item=${feature} />`)}
      </div>
    </div>
  `
}

export function FeatureHealth() {
  useEffect(() => {
    void loadFeatureHealth()
  }, [])

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-4">
      <${SectionCard} label="기능 상태" class="section v2-monitoring-panel">
        <${AsyncContainer}
          state=${featureHealth.state}
          loadingMessage="기능 상태 데이터를 불러오는 중..."
          emptyMessage="기능 상태 데이터가 없습니다."
          render=${(data: FeatureHealthData) => {
            const overview = data.overview
            return html`
              <div class="space-y-4">
                <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-4">
                  <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                    <div class="max-w-3xl">
                      <${SectionCap}>기능 플래그 상태<//>
                      <div class="mt-2 text-2xl font-semibold text-[var(--color-fg-primary)]">
                        ${overview.enabled_count} / ${overview.total_features} 기능 활성화
                      </div>
                      ${overview.overridden_count ? html`
                        <div class="mt-2 text-sm leading-airy text-[var(--color-fg-secondary)]">
                          ${overview.overridden_count}개 플래그가 환경변수로 오버라이드되었습니다.
                        </div>
                      ` : null}
                    </div>
                    <button
                      type="button"
                      class="v2-monitoring-action rounded-[var(--r-1)] border border-[var(--color-border-default)] px-2.5 py-1 text-2xs text-[var(--color-fg-muted)] transition-colors hover:border-[var(--accent)] hover:text-[var(--color-fg-secondary)]"
                      onClick=${() => { void loadFeatureHealth() }}
                    >새로고침</button>
                  </div>

                  <div class="mt-4">
                    <${KpiStripView}
                      ariaLabel="기능 상태 요약"
                      variant="standard"
                      cells=${[
                        { variant: 'stacked', label: '총 기능', value: overview.total_features },
                        { variant: 'stacked', label: '활성화', value: overview.enabled_count },
                        { variant: 'stacked', label: '정상', value: overview.healthy_count, kind: 'ok' },
                        { variant: 'stacked', label: '실험적', value: overview.warning_count, kind: 'warn' },
                        { variant: 'stacked', label: '비활성', value: overview.inactive_count },
                        { variant: 'stacked', label: '폐기 예정', value: overview.deprecated_count, kind: 'err' },
                      ] satisfies KpiStripViewData['cells']}
                    />
                  </div>

                  <div class="mt-4 text-xs text-[var(--color-fg-disabled)]">
                    generated ${formatTimeAgo(data.generated_at)}
                  </div>
                </div>

                <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                  <${FilterChips}
                    chips=${STATUS_FILTER_OPTIONS.map((opt) => ({
                      key: opt.value,
                      label: opt.label,
                      count:
                        opt.value === 'all'
                          ? data.all_features.length
                          : data.all_features.filter((f) => f.status === opt.value).length,
                    }))}
                    active=${statusFilter}
                  />
                  <${TextInput}
                    class="sm:max-w-65"
                    name="feature_health_search"
                    ariaLabel="기능 플래그 검색"
                    autoComplete="off"
                    placeholder="기능 이름 또는 설명 검색..."
                    value=${searchQuery.value}
                    onInput=${(e: Event) => {
                      searchQuery.value = (e.target as HTMLInputElement).value
                    }}
                  />
                </div>

                ${(() => {
                  const hasFilter = statusFilter.value !== 'all' || searchQuery.value.trim() !== ''
                  if (!hasFilter) {
                    return html`
                      <div class="space-y-3">
                        ${Object.entries(data.features_by_category).map(([category, categoryData]) => html`
                          <${CategorySection} category=${category} categoryData=${categoryData} />
                        `)}
                      </div>
                    `
                  }
                  const filtered = filterFeatures(
                    data.all_features,
                    searchQuery.value,
                    statusFilter.value,
                  )
                  if (filtered.length === 0) {
                    return html`
                      <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 text-xs text-[var(--color-fg-disabled)]">
                        조건에 맞는 기능이 없습니다.
                      </div>
                    `
                  }
                  return html`
                    <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
                      <div class="mb-3 text-xs text-[var(--color-fg-muted)]">
                        ${filtered.length} / ${data.all_features.length}개 기능
                      </div>
                      <div class="space-y-2">
                        ${filtered.map((feature) => html`<${FeatureItem} item=${feature} />`)}
                      </div>
                    </div>
                  `
                })()}
              </div>
            `
          }}
        />
      <//>
    </div>
  `
}
