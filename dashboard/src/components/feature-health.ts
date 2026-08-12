// Feature Health panel — feature flag status and health monitoring.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { Option } from 'effect'
import {
  fetchFeatureHealth,
  type FeatureHealthCategory,
  type FeatureHealthData,
  type FeatureHealthError,
  type FeatureHealthItem,
  type FeatureStatus,
} from '../api/feature-health'
import { dashboardRuntime, type DashboardHttp } from '../api/effect-http'
import { capitalize } from '../lib/format-string'
import { createEffectResource } from '../lib/effect-resource'
import { formatTimeAgo } from '../lib/format-time'
import { SectionCard, SurfaceCard } from './common/card'
import { ErrorState, LoadingState } from './common/feedback-state'
import { FilterChips } from './common/filter-chips'
import { TextInput } from './common/input'
import { SectionCap } from './common/section-cap'
import { StatusChip, type StatusChipTone } from './common/status-chip'
import { KpiStripView, type KpiStripViewData } from './kpi-strip-view'

type StatusFilter = FeatureStatus | 'all'

const featureHealthResource = createEffectResource<
  DashboardHttp,
  FeatureHealthError,
  FeatureHealthData
>(dashboardRuntime)

// Filter state (module-scoped so filter survives re-renders / refreshes).
const statusFilter = signal<StatusFilter>('all')
const searchQuery = signal('')

const STATUS_FILTER_OPTIONS: { value: StatusFilter; label: string }[] = [
  { value: 'all', label: '전체' },
  { value: 'healthy', label: '정상' },
  { value: 'warning', label: '실험적' },
  { value: 'inactive', label: '비활성' },
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
>(features: readonly T[], query: string, status: StatusFilter): readonly T[] {
  const q = query.trim().toLowerCase()
  if (q === '' && status === 'all') return features
  return features.filter(
    (f) => featureMatchesSearch(f, q) && featureMatchesStatus(f, status),
  )
}

function loadFeatureHealth(): Promise<void> {
  return featureHealthResource.load(fetchFeatureHealth())
}

export function refreshFeatureHealth(): Promise<void> {
  return loadFeatureHealth()
}

export function resetFeatureHealthState(): void {
  statusFilter.value = 'all'
  searchQuery.value = ''
  featureHealthResource.reset()
}

/**
 * Feature-health-domain status → 한국어 라벨.
 *
 * Distinct from `statusLabel` in `lib/status-label.ts` (which handles every
 * runtime/agent status enum). FeatureStatus is a closed enum
 * (`'healthy' | 'warning' | 'inactive'`) with feature-flag
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
          </div>
        </div>
      </div>
    <//>
  `
}

function CategorySection({ category, categoryData }: {
  category: string
  categoryData: FeatureHealthCategory
}) {
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

function FeatureCollection({ data }: { data: FeatureHealthData }) {
  const hasFilter =
    statusFilter.value !== 'all' || searchQuery.value.trim() !== ''
  if (!hasFilter) {
    return html`
      <div class="space-y-3">
        ${Object.entries(data.features_by_category).map(
          ([category, categoryData]) => html`
            <${CategorySection}
              category=${category}
              categoryData=${categoryData}
            />
          `,
        )}
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
        ${filtered.map(feature => html`<${FeatureItem} item=${feature} />`)}
      </div>
    </div>
  `
}

function FeatureHealthContent({
  data,
  refreshing = false,
  errorMessage,
}: {
  data: FeatureHealthData
  refreshing?: boolean
  errorMessage?: string
}) {
  const overview = data.overview
  return html`
    <div class="space-y-4">
      ${errorMessage ? html`<${ErrorState} message=${errorMessage} />` : null}
      <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-4">
        <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
          <div class="max-w-3xl">
            <${SectionCap}>기능 플래그 상태<//>
            <div class="mt-2 text-2xl font-semibold text-[var(--color-fg-primary)]">
              ${overview.enabled_count} / ${overview.total_features} 기능 활성화
            </div>
            ${overview.overridden_count > 0 ? html`
              <div class="mt-2 text-sm leading-airy text-[var(--color-fg-secondary)]">
                ${overview.overridden_count}개 플래그가 환경변수로 오버라이드되었습니다.
              </div>
            ` : null}
          </div>
          <button
            type="button"
            class="v2-monitoring-action rounded-[var(--r-1)] border border-[var(--color-border-default)] px-2.5 py-1 text-2xs text-[var(--color-fg-muted)] transition-colors hover:border-[var(--accent)] hover:text-[var(--color-fg-secondary)]"
            onClick=${() => { void loadFeatureHealth() }}
            disabled=${refreshing}
          >${refreshing ? '불러오는 중...' : '새로고침'}</button>
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
            ] satisfies KpiStripViewData['cells']}
          />
        </div>

        <div class="mt-4 text-xs text-[var(--color-fg-disabled)]">
          generated ${formatTimeAgo(data.generated_at)}
        </div>
      </div>

      <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <${FilterChips}
          chips=${STATUS_FILTER_OPTIONS.map(option => ({
            key: option.value,
            label: option.label,
            count: option.value === 'all'
              ? data.all_features.length
              : data.all_features.filter(
                feature => feature.status === option.value,
              ).length,
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
          onInput=${(event: Event) => {
            searchQuery.value = (event.target as HTMLInputElement).value
          }}
        />
      </div>

      <${FeatureCollection} data=${data} />
    </div>
  `
}

function FeatureHealthState() {
  const state = featureHealthResource.state.value
  switch (state._tag) {
    case 'Initial':
      return html`<${LoadingState}>기능 상태 데이터를 불러오는 중...<//>`
    case 'Loading':
      return Option.match(state.previous, {
        onNone: () =>
          html`<${LoadingState}>기능 상태 데이터를 불러오는 중...<//>`,
        onSome: data =>
          html`<${FeatureHealthContent} data=${data} refreshing=${true} />`,
      })
    case 'Failure':
      return Option.match(state.previous, {
        onNone: () => html`<${ErrorState} message=${state.error.message} />`,
        onSome: data => html`
          <${FeatureHealthContent}
            data=${data}
            errorMessage=${state.error.message}
          />
        `,
      })
    case 'Success':
      return html`<${FeatureHealthContent} data=${state.value} />`
  }
}

export function FeatureHealth() {
  useEffect(() => {
    void loadFeatureHealth()
    return () => featureHealthResource.cancel()
  }, [])

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-4">
      <${SectionCard} label="기능 상태" class="section v2-monitoring-panel">
        <${FeatureHealthState} />
      <//>
    </div>
  `
}
