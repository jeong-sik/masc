// Full inventory view with filters, search, and virtual list

import { html } from 'htm/preact'
import { useEffect, useRef, useCallback } from 'preact/hooks'
import { ActionButton } from '../common/button'
import { VirtualList } from '../common/virtual-list'
import { EmptyState } from '../common/empty-state'
import { ErrorState } from '../common/feedback-state'
import { TextInput } from '../common/input'
import { Select } from '../common/select'
import { Checkbox } from '../common/checkbox'
import { route } from '../../router'
import type { DashboardToolInventoryItem } from '../../api'
import { InventoryRow } from './tool-inventory-row'
import {
  type SurfaceFilter,
  searchQuery,
  categoryFilter,
  directOnly,
  showHidden,
  showDeprecated,
  surfaceFilter,
  SURFACE_MAP,
  SURFACE_LABELS,
  hasSurface,
  loadTools,
  toolMatchesQuery,
  surfaceCountForFilter,
  showBackToTop,
} from './tool-state'

function StatCard({ value, label }: { value: number; label: string }) {
  return html`
    <div class="p-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--white-3)] flex flex-col gap-1.5">
      <span class="text-[var(--color-fg-secondary)] text-3xl font-bold leading-none tabular-nums">${value}</span>
      <span class="text-2xs text-[var(--color-fg-muted)] uppercase tracking-wider font-medium">${label}</span>
    </div>
  `
}

export function FullInventoryView({
  inventory,
  loading,
  error,
}: {
  inventory: DashboardToolInventoryItem[]
  loading: boolean
  error: string | null
}) {
  const listContainerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (route.value.tab !== 'lab' || route.value.params.section !== 'tools') return
    const q = route.value.params.q?.trim()
    searchQuery.value = q ?? ''
  }, [route.value.tab, route.value.params.section, route.value.params.q])

  const handleScroll = useCallback(() => {
    const el = listContainerRef.current
    if (!el) return
    showBackToTop.value = el.scrollTop > 500
  }, [])

  useEffect(() => {
    const el = listContainerRef.current
    if (!el) return
    el.addEventListener('scroll', handleScroll, { passive: true })
    return () => el.removeEventListener('scroll', handleScroll)
  }, [handleScroll])

  const scrollToTop = useCallback(() => {
    const el = listContainerRef.current
    if (el) el.scrollTo({ top: 0, behavior: 'smooth' })
  }, [])

  const categories = Array.from(new Set(inventory.map(item => item.category))).sort((left, right) => left.localeCompare(right))
  const filtered = inventory.filter(item => {
    if (!toolMatchesQuery(item, searchQuery.value)) return false
    if (categoryFilter.value !== 'all' && item.category !== categoryFilter.value) return false
    if (directOnly.value && !item.direct_call_allowed) return false
    if (!showHidden.value && item.visibility === 'hidden') return false
    if (!showDeprecated.value && item.lifecycle === 'deprecated') return false
    if (surfaceFilter.value !== 'all') {
      const targets = SURFACE_MAP[surfaceFilter.value]
      if (!(item.surfaces ?? []).some(s => targets.includes(s))) return false
    }
    return true
  })

  const totalCount = inventory.length
  const publicCount = inventory.filter(item => hasSurface(item, 'public_mcp')).length
  const hiddenCount = inventory.filter(item => item.visibility === 'hidden').length
  const deprecatedCount = inventory.filter(item => item.lifecycle === 'deprecated').length
  const directCallCount = inventory.filter(item => item.direct_call_allowed).length

  return html`
    <div class="sticky top-[var(--header-h)] z-[var(--z-tab-sticky)] bg-[var(--backdrop-modal)] backdrop-blur-[8px] py-3 border-b border-[var(--color-border-default)]">
      <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-3 my-4">
        <${StatCard} value=${totalCount} label="전체 도구" />
        <${StatCard} value=${publicCount} label="MCP 공개" />
        <${StatCard} value=${hiddenCount} label="숨김" />
        <${StatCard} value=${deprecatedCount} label="지원 중단" />
        <${StatCard} value=${directCallCount} label="직접 호출" />
        <${StatCard} value=${filtered.length} label="필터 결과" />
      </div>

      <div class="text-xs text-[var(--color-fg-muted)] mb-4">
        카드 숫자는 서로 다른 축이다. MCP 공개는 surface, 숨김은 visibility, 직접 호출은 hidden direct-call policy 기준이다.
      </div>

      <div class="flex flex-wrap gap-2 mb-4">
        ${(Object.keys(SURFACE_LABELS) as SurfaceFilter[]).map(key => html`
          <${ActionButton}
            variant="ghost"
            size="md"
            class="!text-sm !px-3 !py-1.5"
            pressed=${surfaceFilter.value === key}
            ariaLabel=${`surface filter ${SURFACE_LABELS[key]}`}
            onClick=${() => { surfaceFilter.value = key }}
          >
            ${SURFACE_LABELS[key]}
            <span class="inline-flex items-center justify-center min-w-5 h-[18px] px-[5px] text-3xs font-semibold bg-[var(--white-8)] text-[var(--color-fg-muted)] rounded-sm ml-1">${surfaceCountForFilter(inventory, key)}</span>
          <//>
        `)}
      </div>

      <div class="flex flex-wrap gap-3 items-center">
        <${TextInput}
          class="max-w-80"
          name="tool_inventory_query"
          ariaLabel="도구 인벤토리 검색"
          autoComplete="off"
          placeholder="도구, 문서, 권한, 대체 도구 검색..."
          value=${searchQuery.value}
          onInput=${(e: Event) => {
            searchQuery.value = (e.target as HTMLInputElement).value
          }}
        />
        <${Select}
          class="px-3 py-2 text-sm"
          name="tool_inventory_category"
          ariaLabel="도구 카테고리 필터"
          value=${categoryFilter.value}
          options=${[
            { value: 'all', label: '전체 카테고리' },
            ...categories.map(category => ({
              value: category,
              label: category === 'uncategorized' ? '미분류' : category,
            })),
          ]}
          onInput=${(v: string) => { categoryFilter.value = v }}
        />
        <label class="inline-flex items-center gap-2 text-xs text-[var(--color-fg-primary)]">
          <${Checkbox}
            checked=${directOnly.value}
            ariaLabel="직접 호출만"
            onChange=${(checked: boolean) => { directOnly.value = checked }}
          />
          <span>직접 호출만</span>
        </label>
        <label class="inline-flex items-center gap-2 text-xs text-[var(--color-fg-primary)]">
          <${Checkbox}
            checked=${showHidden.value}
            ariaLabel="숨김 표시"
            onChange=${(checked: boolean) => { showHidden.value = checked }}
          />
          <span>숨김 표시</span>
        </label>
        <label class="inline-flex items-center gap-2 text-xs text-[var(--color-fg-primary)]">
          <${Checkbox}
            checked=${showDeprecated.value}
            ariaLabel="지원 중단 표시"
            onChange=${(checked: boolean) => { showDeprecated.value = checked }}
          />
          <span>지원 중단 표시</span>
        </label>
        <${ActionButton}
          variant="ghost"
          size="md"
          class="!px-3 !text-sm"
          onClick=${() => { void loadTools() }}
          disabled=${loading}
          ariaBusy=${loading}
        >
          ${loading ? '새로고침 중...' : '새로고침'}
        <//>
      </div>
    </div>

    ${error ? html`<${ErrorState} message=${error} class="mt-2" />` : null}

    <div ref=${listContainerRef} class="overflow-y-auto max-h-[calc(100vh-420px)] min-h-75">
      ${filtered.length > 0
        ? html`<${VirtualList}
            items=${filtered}
            itemHeight=${130}
            renderItem=${(item: DashboardToolInventoryItem) => html`<${InventoryRow} item=${item} />`}
            getKey=${(item: DashboardToolInventoryItem) => item.name}
            className="flex flex-col gap-3"
          />`
        : html`<${EmptyState} message="조건에 맞는 도구가 없습니다." compact />`}
    </div>

    <button type="button"
      class=${`tool-back-to-top${showBackToTop.value ? ' visible' : ''}`}
      onClick=${scrollToTop}
      aria-label="목록 맨 위로 이동"
      title="맨 위로"
    >
      <svg aria-hidden="true" width="20" height="20" viewBox="0 0 20 20" fill="none">
        <path d="M10 15V5M10 5L5 10M10 5L15 10" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
    </button>
  `
}
