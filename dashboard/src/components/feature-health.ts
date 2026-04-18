// Feature Health panel — feature flag status and health monitoring.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { get } from '../api/core'
import { createAsyncResource, type AsyncResource } from '../lib/async-state'
import { formatTimeAgo } from '../lib/format-time'
import { AsyncContainer } from './common/async-container'
import { Card } from './common/card'
import { FilterChips } from './common/filter-chips'
import { TextInput } from './common/input'
import { SectionCap } from './common/section-cap'
import { StatCard } from './common/stat-card'

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
export function featureMatchesSearch(
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

export function featureMatchesStatus(
  item: Pick<FeatureHealthItem, 'status'>,
  status: StatusFilter,
): boolean {
  if (status === 'all') return true
  return item.status === status
}

export function filterFeatures<
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

function statusLabel(status: FeatureStatus): string {
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

function statusChipClass(status: FeatureStatus): string {
  switch (status) {
    case 'healthy':
      return 'border-[var(--ok-30)] bg-[var(--ok-12)] text-[var(--ok)]'
    case 'warning':
      return 'border-[var(--warn-30)] bg-[var(--warn-12)] text-[var(--warn)]'
    case 'inactive':
      return 'border-[var(--white-12)] bg-[var(--white-4)] text-[var(--text-muted)]'
    case 'deprecated':
    default:
      return 'border-[var(--bad-30)] bg-[var(--bad-12)] text-[var(--bad)]'
  }
}

function StatusPill({ status }: { status: FeatureStatus }) {
  return html`
    <span class=${`inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${statusChipClass(status)}`}>
      ${statusLabel(status)}
    </span>
  `
}

function FeatureItem({ item }: { item: FeatureHealthItem }) {
  return html`
    <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
      <div class="flex items-start justify-between gap-3">
        <div class="flex-1">
          <div class="flex items-center gap-2">
            <code class="text-xs font-medium text-[var(--text-strong)]">${item.env_name}</code>
            <${StatusPill} status=${item.status} />
            ${item.is_enabled ? html`
              <span class="inline-flex items-center rounded border border-[var(--ok-30)] bg-[var(--ok-12)] px-1.5 py-0.5 text-[10px] font-semibold text-[var(--ok)]">
                ON
              </span>
            ` : html`
              <span class="inline-flex items-center rounded border border-[var(--white-12)] bg-[var(--white-4)] px-1.5 py-0.5 text-[10px] font-semibold text-[var(--text-muted)]">
                OFF
              </span>
            `}
          </div>
          <div class="mt-1.5 text-sm text-[var(--text-body)]">${item.description}</div>
          <div class="mt-1 flex items-center gap-3 text-xs text-[var(--text-muted)]">
            <span>source: ${item.source}</span>
            <span>since: v${item.since}</span>
          </div>
        </div>
      </div>
    </div>
  `
}

function CategorySection({ category, categoryData }: { category: string; categoryData: { total: number; enabled: number; features: FeatureHealthItem[] } }) {
  const categoryLabel = category.charAt(0).toUpperCase() + category.slice(1)
  const enabledRatio = categoryData.total > 0 ? Math.round((categoryData.enabled / categoryData.total) * 100) : 0

  return html`
    <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-3)] p-4">
      <div class="mb-3 flex items-center justify-between">
        <div>
          <div class="text-sm font-medium text-[var(--text-strong)]">${categoryLabel}</div>
          <div class="mt-0.5 text-xs text-[var(--text-muted)]">
            ${categoryData.enabled} / ${categoryData.total} enabled (${enabledRatio}%)
          </div>
        </div>
        <div class="rounded-full border border-[var(--white-8)] bg-[var(--white-6)] px-3 py-1 text-xs font-semibold text-[var(--text-body)]">
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
    <div class="space-y-4">
      <${Card} title="Feature Health" class="section">
        <${AsyncContainer}
          state=${featureHealth.state}
          loadingMessage="Feature health 데이터를 불러오는 중..."
          emptyMessage="Feature health 데이터가 없습니다."
          render=${(data: FeatureHealthData) => {
            const overview = data.overview
            return html`
              <div class="space-y-4">
                <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] p-4">
                  <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                    <div class="max-w-3xl">
                      <${SectionCap}>Feature Flags Health<//>
                      <div class="mt-2 text-2xl font-semibold text-[var(--text-strong)]">
                        ${overview.enabled_count} / ${overview.total_features} 기능 활성화
                      </div>
                      <div class="mt-2 text-sm leading-[1.7] text-[var(--text-body)]">
                        시스템 기능 플래그 상태를 실시간으로 모니터링합니다.
                        ${overview.overridden_count ? `${overview.overridden_count}개 플래그가 환경변수로 오버라이드되었습니다.` : ''}
                      </div>
                    </div>
                    <button
                      type="button"
                      class="rounded border border-[var(--white-8)] px-2.5 py-1 text-[11px] text-[var(--text-muted)] transition-colors hover:border-[var(--accent)] hover:text-[var(--text-body)]"
                      onClick=${() => { void loadFeatureHealth() }}
                    >새로고침</button>
                  </div>

                  <div class="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-6">
                    <${StatCard} label="총 기능" value=${overview.total_features} />
                    <${StatCard} label="활성화" value=${overview.enabled_count} />
                    <${StatCard} label="정상" value=${overview.healthy_count} />
                    <${StatCard} label="실험적" value=${overview.warning_count} />
                    <${StatCard} label="비활성" value=${overview.inactive_count} />
                    <${StatCard} label="폐기 예정" value=${overview.deprecated_count} />
                  </div>

                  <div class="mt-4 text-xs text-[var(--text-dim)]">
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
                    class="sm:max-w-[260px]"
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
                      <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-3)] p-4 text-xs text-[var(--text-dim)]">
                        조건에 맞는 기능이 없습니다.
                      </div>
                    `
                  }
                  return html`
                    <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-3)] p-4">
                      <div class="mb-3 text-xs text-[var(--text-muted)]">
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
