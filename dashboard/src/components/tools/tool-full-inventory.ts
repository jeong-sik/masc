// Full inventory view with filters, search, and virtual list

import { html } from 'htm/preact'
import { useEffect, useRef, useCallback } from 'preact/hooks'
import { VirtualList } from '../common/virtual-list'
import { EmptyState } from '../common/empty-state'
import { ErrorState } from '../common/feedback-state'
import { TextInput } from '../common/input'
import { route } from '../../router'
import type { DashboardToolInventoryItem } from '../../api'
import { InventoryRow } from './tool-inventory-row'
import {
  type SurfaceFilter,
  searchQuery,
  categoryFilter,
  enabledOnly,
  directOnly,
  showHidden,
  showDeprecated,
  surfaceFilter,
  SURFACE_MAP,
  SURFACE_LABELS,
  loadTools,
  toolMatchesQuery,
  surfaceCountForFilter,
  showBackToTop,
} from './tool-state'

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
    if (enabledOnly.value && !item.enabled_in_current_mode) return false
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
  const enabledCount = inventory.filter(item => item.enabled_in_current_mode).length
  const hiddenCount = inventory.filter(item => item.visibility === 'hidden').length
  const deprecatedCount = inventory.filter(item => item.lifecycle === 'deprecated').length
  const directCallCount = inventory.filter(item => item.direct_call_allowed).length

  return html`
    <div class="sticky top-[var(--header-h)] z-[var(--z-tab-sticky)] bg-[rgba(11,18,32,0.95)] backdrop-blur-[8px] py-3 border-b border-[var(--card-border)]">
      <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-3 my-4">
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${totalCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">전체 도구</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${enabledCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">활성화됨</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${hiddenCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">숨김</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${deprecatedCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">지원 중단</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${directCallCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">직접 호출</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${filtered.length}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">필터 결과</span>
        </div>
      </div>

      <div class="flex flex-wrap gap-2 mb-4">
        ${(Object.keys(SURFACE_LABELS) as SurfaceFilter[]).map(key => html`
          <button type="button"
            class=${`px-3 py-1.5 rounded-lg text-[13px] font-medium border transition-colors cursor-pointer ${surfaceFilter.value === key ? 'border-[var(--accent)]/40 text-[var(--accent)] bg-[var(--accent-8)]' : 'border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] text-[var(--text-body)]'}`}
            onClick=${() => { surfaceFilter.value = key }}
          >
            ${SURFACE_LABELS[key]}
            <span class="inline-flex items-center justify-center min-w-5 h-[18px] px-[5px] text-[10px] font-semibold bg-[var(--white-8)] text-[var(--text-muted)] rounded-full ml-1">${surfaceCountForFilter(inventory, key)}</span>
          </button>
        `)}
      </div>

      <div class="flex flex-wrap gap-3 items-center">
        <${TextInput}
          class="max-w-[320px]"
          name="tool_inventory_query"
          ariaLabel="도구 인벤토리 검색"
          autoComplete="off"
          placeholder="도구, 문서, 권한, 대체 도구 검색..."
          value=${searchQuery.value}
          onInput=${(e: Event) => {
            searchQuery.value = (e.target as HTMLInputElement).value
          }}
        />
        <select
          class="px-3 py-2 rounded-lg bg-[var(--white-3)] border border-[var(--card-border)] text-[var(--text-body)] text-[13px] focus:border-[var(--accent)]/50 outline-none"
          name="tool_inventory_category"
          aria-label="도구 카테고리 필터"
          value=${categoryFilter.value}
          onChange=${(e: Event) => {
            categoryFilter.value = (e.target as HTMLSelectElement).value
          }}
        >
          <option value="all">전체 카테고리</option>
          ${categories.map(category => html`<option value=${category}>${category}</option>`)}
        </select>
        <label class="inline-flex items-center gap-2 text-[12px] text-[var(--text-body)]">
          <input
            type="checkbox"
            checked=${enabledOnly.value}
            onChange=${(e: Event) => {
              enabledOnly.value = (e.target as HTMLInputElement).checked
            }}
          />
          <span>활성화만</span>
        </label>
        <label class="inline-flex items-center gap-2 text-[12px] text-[var(--text-body)]">
          <input
            type="checkbox"
            checked=${directOnly.value}
            onChange=${(e: Event) => {
              directOnly.value = (e.target as HTMLInputElement).checked
            }}
          />
          <span>직접 호출만</span>
        </label>
        <label class="inline-flex items-center gap-2 text-[12px] text-[var(--text-body)]">
          <input
            type="checkbox"
            checked=${showHidden.value}
            onChange=${(e: Event) => {
              showHidden.value = (e.target as HTMLInputElement).checked
            }}
          />
          <span>숨김 표시</span>
        </label>
        <label class="inline-flex items-center gap-2 text-[12px] text-[var(--text-body)]">
          <input
            type="checkbox"
            checked=${showDeprecated.value}
            onChange=${(e: Event) => {
              showDeprecated.value = (e.target as HTMLInputElement).checked
            }}
          />
          <span>지원 중단 표시</span>
        </label>
        <button type="button"
          class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
          onClick=${() => { void loadTools() }}
          disabled=${loading}
        >
          ${loading ? '새로고침 중...' : '새로고침'}
        </button>
      </div>
    </div>

    ${error ? html`<${ErrorState} message=${error} class="mt-2" />` : null}

    <div ref=${listContainerRef} class="overflow-y-auto max-h-[calc(100vh-420px)] min-h-[300px]">
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
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
        <path d="M10 15V5M10 5L5 10M10 5L15 10" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
    </button>
  `
}
