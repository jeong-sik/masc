import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef, useCallback } from 'preact/hooks'
import { Card } from './common/card'
import { VirtualList } from './common/virtual-list'
import { ToolMetrics } from './tool-metrics'
import { route } from '../router'
import { fetchDashboardTools, type DashboardToolsResponse, type DashboardToolInventoryItem } from '../api'

const toolsData = signal<DashboardToolsResponse | null>(null)
const toolsError = signal<string | null>(null)
const toolsLoading = signal(false)
const searchQuery = signal('')
const categoryFilter = signal('all')
const enabledOnly = signal(false)
const directOnly = signal(false)
const showHidden = signal(true)
const showDeprecated = signal(true)

type SurfaceFilter = 'all' | 'public_mcp' | 'agent' | 'keeper' | 'internal'
const surfaceFilter = signal<SurfaceFilter>('all')

const SURFACE_MAP: Record<Exclude<SurfaceFilter, 'all'>, string[]> = {
  public_mcp: ['public_mcp'],
  agent: ['spawned_agent_mcp'],
  keeper: ['keeper_standard', 'keeper_privileged'],
  internal: ['local_worker', 'mdal_auditable', 'privileged_executor'],
}

const SURFACE_LABELS: Record<SurfaceFilter, string> = {
  all: '전체',
  public_mcp: 'MCP 공개',
  agent: '에이전트',
  keeper: '키퍼',
  internal: '내부',
}

async function loadTools() {
  if (toolsLoading.value) return
  toolsLoading.value = true
  toolsError.value = null
  try {
    toolsData.value = await fetchDashboardTools()
  } catch (err) {
    toolsError.value = err instanceof Error ? err.message : String(err)
  } finally {
    toolsLoading.value = false
  }
}

function toolMatchesQuery(item: DashboardToolInventoryItem, rawQuery: string): boolean {
  const query = rawQuery.trim().toLowerCase()
  if (!query) return true
  const haystack = [
    item.name,
    item.description,
    item.category,
    item.required_permission ?? '',
    item.visibility,
    item.lifecycle,
    item.implementationStatus,
    item.tier,
    item.canonicalName ?? '',
    item.replacement ?? '',
    item.reason ?? '',
    ...item.doc_refs,
    ...item.prompt_hints,
    ...(item.surfaces ?? []),
  ]
    .join(' ')
    .toLowerCase()
  return haystack.includes(query)
}

function toolBadge(label: string, tone: 'default' | 'ok' | 'warn' | 'surface' = 'default') {
  const color =
    tone === 'ok' ? '#7dd3fc'
      : tone === 'warn' ? '#fbbf24'
      : tone === 'surface' ? '#c4b5fd'
      : '#cbd5e1'
  const background =
    tone === 'ok' ? 'rgba(14, 165, 233, 0.18)'
      : tone === 'warn' ? 'rgba(245, 158, 11, 0.18)'
      : tone === 'surface' ? 'rgba(139, 92, 246, 0.18)'
      : 'rgba(148, 163, 184, 0.16)'
  return html`
    <span
      style=${{
        fontSize: '11px',
        color,
        background,
        borderRadius: '999px',
        padding: '2px 8px',
      }}
    >
      ${label}
    </span>
  `
}

function surfaceCountForFilter(inventory: DashboardToolInventoryItem[], filter: SurfaceFilter): number {
  if (filter === 'all') return inventory.length
  const targets = SURFACE_MAP[filter]
  return inventory.filter(item => (item.surfaces ?? []).some(s => targets.includes(s))).length
}

function InventoryRow({ item }: { item: DashboardToolInventoryItem }) {
  return html`
    <article class="tool-inventory-row">
      <div class="tool-inventory-head">
        <div>
          <div class="tool-inventory-name">${item.name}</div>
          <div class="tool-inventory-desc">${item.description}</div>
        </div>
        <div class="tool-inventory-badges">
          ${(item.surfaces ?? []).map(s => toolBadge(s, 'surface'))}
          ${toolBadge(item.tier, item.tier === 'essential' ? 'ok' : item.tier === 'standard' ? 'warn' : 'default')}
          ${toolBadge(item.visibility)}
          ${toolBadge(item.lifecycle, item.lifecycle === 'deprecated' ? 'warn' : 'default')}
          ${toolBadge(item.implementationStatus)}
        </div>
      </div>
      <div class="tool-inventory-meta">
        <span>카테고리: <strong>${item.category}</strong></span>
        <span>모드: <strong>${item.enabled_in_current_mode ? '활성' : '비활성'}</strong></span>
        <span>직접 호출: <strong>${item.direct_call_allowed ? '허용' : '차단'}</strong></span>
        <span>권한: <strong>${item.required_permission ?? '없음'}</strong></span>
      </div>
      ${item.reason
        ? html`<div class="tool-inventory-reason">${item.reason}</div>`
        : null}
      <div class="tool-inventory-links">
        ${item.canonicalName ? html`<span>정식 이름: <strong>${item.canonicalName}</strong></span>` : null}
        ${item.replacement ? html`<span>대체 도구: <strong>${item.replacement}</strong></span>` : null}
        ${item.doc_refs.length > 0 ? html`<span>문서: <strong>${item.doc_refs.join(', ')}</strong></span>` : null}
      </div>
    </article>
  `
}

const showBackToTop = signal(false)
const showFullInventory = signal(false)

export { loadTools as refreshTools }

// --- Summary View: Top 10 most essential + Top 5 never-used ---

function ToolSummaryView({ inventory }: { inventory: DashboardToolInventoryItem[] }) {
  const essential = inventory
    .filter(item => item.tier === 'essential' && item.enabled_in_current_mode)
    .slice(0, 10)

  const neverUsed = inventory
    .filter(item => item.lifecycle !== 'deprecated' && item.visibility !== 'hidden')
    .slice(-5)
    .reverse()

  const totalCount = inventory.length
  const enabledCount = inventory.filter(item => item.enabled_in_current_mode).length
  const deprecatedCount = inventory.filter(item => item.lifecycle === 'deprecated').length

  return html`
    <div class="tool-summary">
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
          <span class="stat-value">${deprecatedCount}</span>
          <span class="stat-label">폐기 예정</span>
        </div>
      </div>

      ${essential.length > 0 ? html`
        <div class="tool-summary-section">
          <h4 class="tool-summary-heading">필수 도구 (상위 ${essential.length}개)</h4>
          <div class="tool-summary-list">
            ${essential.map(item => html`
              <div class="tool-summary-row" key=${item.name}>
                <span class="tool-summary-name">${item.name}</span>
                <span class="tool-summary-desc">${item.description?.slice(0, 60) ?? ''}</span>
                ${(item.surfaces ?? []).map(s => toolBadge(s, 'surface'))}
              </div>
            `)}
          </div>
        </div>
      ` : null}

      ${neverUsed.length > 0 ? html`
        <div class="tool-summary-section">
          <h4 class="tool-summary-heading">미사용 도구 (${neverUsed.length}개)</h4>
          <div class="tool-summary-list">
            ${neverUsed.map(item => html`
              <div class="tool-summary-row" key=${item.name}>
                <span class="tool-summary-name">${item.name}</span>
                <span class="tool-summary-desc">${item.description?.slice(0, 60) ?? ''}</span>
                ${toolBadge(item.category)}
              </div>
            `)}
          </div>
        </div>
      ` : null}
    </div>
  `
}

// --- Full Inventory View (existing) ---

function FullInventoryView({
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

export function Tools() {
  const data = toolsData.value
  const loading = toolsLoading.value
  const error = toolsError.value
  const inventory = data?.tool_inventory.tools ?? []
  const usage = data?.tool_usage ?? null

  useEffect(() => {
    if (!toolsData.value && !toolsLoading.value) {
      void loadTools()
    }
  }, [])

  return html`
    <div>
      <${Card} title="시스템 도구 목록" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">시스템 도구 목록</h2>
          <p class="monitor-subheadline">
            ${showFullInventory.value
              ? 'hidden/deprecated 포함 전체 도구 surface를 봅니다.'
              : '필수 도구와 사용 현황 요약입니다.'}
          </p>
          <button
            class="control-btn ghost"
            style="margin-top: 8px;"
            onClick=${() => { showFullInventory.value = !showFullInventory.value }}
          >
            ${showFullInventory.value ? '요약 보기' : '전체 인벤토리 보기'}
          </button>
        </div>

        ${showFullInventory.value
          ? html`<${FullInventoryView}
              inventory=${inventory}
              loading=${loading}
              error=${error}
            />`
          : html`<${ToolSummaryView} inventory=${inventory} />`
        }
      <//>

      <${Card} title="도구 사용 현황" class="section">
        ${usage
          ? html`
              <div class="tool-inventory-usage-hint">
                등록됨 ${usage.registered_count} · 사용된 ${usage.distinct_tools_called} · 미사용 ${usage.never_called_count}
              </div>
            `
          : null}
        <${ToolMetrics} />
      <//>
      ${data?.generated_at
        ? html`<div class="monitor-meta" style="margin-top:8px">
            <span>생성 시각: ${data.generated_at}</span>
            <span>metrics 기준: 최근 1시간</span>
          </div>`
        : null}
    </div>
  `
}
