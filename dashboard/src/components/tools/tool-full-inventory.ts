// Full inventory view with filters, search, and virtual list

import { html } from 'htm/preact'
import { useEffect, useRef, useCallback } from 'preact/hooks'
import { VirtualList } from '../common/virtual-list'
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
    if (route.value.tab !== 'operations' || route.value.params.section !== 'tools') return
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
    <div class="tool-inventory-sticky-header">
      <div class="tool-inventory-summary">
        <div class="tool-inventory-stat">
          <span class="stat-value">${totalCount}</span>
          <span class="stat-label">전체 도구</span>
        </div>
        <div class="tool-inventory-stat">
          <span class="stat-value">${enabledCount}</span>
          <span class="stat-label">활성화됨</span>
        </div>
        <div class="tool-inventory-stat">
          <span class="stat-value">${hiddenCount}</span>
          <span class="stat-label">숨김</span>
        </div>
        <div class="tool-inventory-stat">
          <span class="stat-value">${deprecatedCount}</span>
          <span class="stat-label">지원 중단</span>
        </div>
        <div class="tool-inventory-stat">
          <span class="stat-value">${directCallCount}</span>
          <span class="stat-label">직접 호출</span>
        </div>
        <div class="tool-inventory-stat">
          <span class="stat-value">${filtered.length}</span>
          <span class="stat-label">필터 결과</span>
        </div>
      </div>

      <div class="tool-surface-tabs">
        ${(Object.keys(SURFACE_LABELS) as SurfaceFilter[]).map(key => html`
          <button
            class=${`control-btn${surfaceFilter.value === key ? ' is-active' : ''}`}
            onClick=${() => { surfaceFilter.value = key }}
          >
            ${SURFACE_LABELS[key]}
            <span class="tool-surface-count">${surfaceCountForFilter(inventory, key)}</span>
          </button>
        `)}
      </div>

      <div class="tool-inventory-filters">
        <input
          class="control-input"
          type="text"
          placeholder="도구, 문서, 권한, 대체 도구 검색..."
          value=${searchQuery.value}
          onInput=${(e: Event) => {
            searchQuery.value = (e.target as HTMLInputElement).value
          }}
        />
        <select
          class="control-select"
          value=${categoryFilter.value}
          onChange=${(e: Event) => {
            categoryFilter.value = (e.target as HTMLSelectElement).value
          }}
        >
          <option value="all">전체 카테고리</option>
          ${categories.map(category => html`<option value=${category}>${category}</option>`)}
        </select>
        <label class="tool-inventory-toggle">
          <input
            type="checkbox"
            checked=${enabledOnly.value}
            onChange=${(e: Event) => {
              enabledOnly.value = (e.target as HTMLInputElement).checked
            }}
          />
          <span>활성화만</span>
        </label>
        <label class="tool-inventory-toggle">
          <input
            type="checkbox"
            checked=${directOnly.value}
            onChange=${(e: Event) => {
              directOnly.value = (e.target as HTMLInputElement).checked
            }}
          />
          <span>직접 호출만</span>
        </label>
        <label class="tool-inventory-toggle">
          <input
            type="checkbox"
            checked=${showHidden.value}
            onChange=${(e: Event) => {
              showHidden.value = (e.target as HTMLInputElement).checked
            }}
          />
          <span>숨김 표시</span>
        </label>
        <label class="tool-inventory-toggle">
          <input
            type="checkbox"
            checked=${showDeprecated.value}
            onChange=${(e: Event) => {
              showDeprecated.value = (e.target as HTMLInputElement).checked
            }}
          />
          <span>지원 중단 표시</span>
        </label>
        <button class="control-btn ghost" onClick=${() => { void loadTools() }} disabled=${loading}>
          ${loading ? '새로고침 중...' : '새로고침'}
        </button>
      </div>
    </div>

    ${error ? html`<div class="tool-metrics-error">${error}</div>` : null}

    <div ref=${listContainerRef} class="tool-inventory-virtual-container">
      ${filtered.length > 0
        ? html`<${VirtualList}
            items=${filtered}
            itemHeight=${130}
            renderItem=${(item: DashboardToolInventoryItem) => html`<${InventoryRow} item=${item} />`}
            getKey=${(item: DashboardToolInventoryItem) => item.name}
            className="tool-inventory-list"
          />`
        : html`<div class="empty-state">조건에 맞는 도구가 없습니다.</div>`}
    </div>

    <button
      class=${`tool-back-to-top${showBackToTop.value ? ' visible' : ''}`}
      onClick=${scrollToTop}
      title="맨 위로"
    >
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
        <path d="M10 15V5M10 5L5 10M10 5L15 10" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
    </button>
  `
}
