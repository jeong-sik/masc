import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
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
  ]
    .join(' ')
    .toLowerCase()
  return haystack.includes(query)
}

function toolBadge(label: string, tone: 'default' | 'ok' | 'warn' = 'default') {
  const color =
    tone === 'ok' ? '#7dd3fc'
      : tone === 'warn' ? '#fbbf24'
      : '#cbd5e1'
  const background =
    tone === 'ok' ? 'rgba(14, 165, 233, 0.18)'
      : tone === 'warn' ? 'rgba(245, 158, 11, 0.18)'
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

function InventoryRow({ item }: { item: DashboardToolInventoryItem }) {
  return html`
    <article class="tool-inventory-row">
      <div class="tool-inventory-head">
        <div>
          <div class="tool-inventory-name">${item.name}</div>
          <div class="tool-inventory-desc">${item.description}</div>
        </div>
        <div class="tool-inventory-badges">
          ${toolBadge(item.tier, item.tier === 'essential' ? 'ok' : item.tier === 'standard' ? 'warn' : 'default')}
          ${toolBadge(item.visibility)}
          ${toolBadge(item.lifecycle, item.lifecycle === 'deprecated' ? 'warn' : 'default')}
          ${toolBadge(item.implementationStatus)}
        </div>
      </div>
      <div class="tool-inventory-meta">
        <span>Category: <strong>${item.category}</strong></span>
        <span>Mode: <strong>${item.enabled_in_current_mode ? 'enabled' : 'disabled'}</strong></span>
        <span>Direct call: <strong>${item.direct_call_allowed ? 'allowed' : 'blocked'}</strong></span>
        <span>Permission: <strong>${item.required_permission ?? 'none'}</strong></span>
      </div>
      ${item.reason
        ? html`<div class="tool-inventory-reason">${item.reason}</div>`
        : null}
      <div class="tool-inventory-links">
        ${item.canonicalName ? html`<span>Canonical: <strong>${item.canonicalName}</strong></span>` : null}
        ${item.replacement ? html`<span>Replacement: <strong>${item.replacement}</strong></span>` : null}
        ${item.doc_refs.length > 0 ? html`<span>Docs: <strong>${item.doc_refs.join(', ')}</strong></span>` : null}
      </div>
    </article>
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

  useEffect(() => {
    if (route.value.tab !== 'tools') return
    const q = route.value.params.q?.trim()
    if (q && q !== searchQuery.value) {
      searchQuery.value = q
    }
  }, [route.value.tab, route.value.params.q])

  const categories = Array.from(new Set(inventory.map(item => item.category))).sort((left, right) => left.localeCompare(right))
  const filtered = inventory.filter(item => {
    if (!toolMatchesQuery(item, searchQuery.value)) return false
    if (categoryFilter.value !== 'all' && item.category !== categoryFilter.value) return false
    if (enabledOnly.value && !item.enabled_in_current_mode) return false
    if (directOnly.value && !item.direct_call_allowed) return false
    if (!showHidden.value && item.visibility === 'hidden') return false
    if (!showDeprecated.value && item.lifecycle === 'deprecated') return false
    return true
  })

  const totalCount = inventory.length
  const enabledCount = inventory.filter(item => item.enabled_in_current_mode).length
  const hiddenCount = inventory.filter(item => item.visibility === 'hidden').length
  const deprecatedCount = inventory.filter(item => item.lifecycle === 'deprecated').length
  const directCallCount = inventory.filter(item => item.direct_call_allowed).length

  return html`
    <div>
      <${Card} title="System Tool Inventory" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">전체 도구 inventory를 기본으로 보여줍니다</h2>
          <p class="monitor-subheadline">Allowed tools는 runtime allowlist이고, 여기서는 시스템이 가진 전체 도구 surface를 hidden/deprecated 포함 기준으로 봅니다.</p>
        </div>

        <div class="tool-inventory-summary">
          <div class="tool-inventory-stat">
            <span class="stat-value">${totalCount}</span>
            <span class="stat-label">Total tools</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${enabledCount}</span>
            <span class="stat-label">Mode enabled</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${hiddenCount}</span>
            <span class="stat-label">Hidden</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${deprecatedCount}</span>
            <span class="stat-label">Deprecated</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${directCallCount}</span>
            <span class="stat-label">Direct call</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${filtered.length}</span>
            <span class="stat-label">Filtered</span>
          </div>
        </div>

        <div class="tool-inventory-filters">
          <input
            class="control-input"
            type="text"
            placeholder="Search tools, docs, permission, replacement…"
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
            <option value="all">All categories</option>
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
            <span>Enabled only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${directOnly.value}
              onChange=${(e: Event) => {
                directOnly.value = (e.target as HTMLInputElement).checked
              }}
            />
            <span>Direct-call only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${showHidden.value}
              onChange=${(e: Event) => {
                showHidden.value = (e.target as HTMLInputElement).checked
              }}
            />
            <span>Show hidden</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${showDeprecated.value}
              onChange=${(e: Event) => {
                showDeprecated.value = (e.target as HTMLInputElement).checked
              }}
            />
            <span>Show deprecated</span>
          </label>
          <button class="control-btn ghost" onClick=${() => { void loadTools() }} disabled=${loading}>
            ${loading ? 'Refreshing…' : 'Refresh inventory'}
          </button>
        </div>

        ${error ? html`<div class="tool-metrics-error">${error}</div>` : null}

        <div class="tool-inventory-list">
          ${filtered.length > 0
            ? filtered.map(item => html`<${InventoryRow} key=${item.name} item=${item} />`)
            : html`<div class="empty-state">No tools matched the current filters.</div>`}
        </div>
      <//>

      <${Card} title="Tool Usage" class="section">
        ${usage
          ? html`
              <div class="tool-inventory-usage-hint">
                Registered ${usage.registered_count} · Distinct called ${usage.distinct_tools_called} · Never called ${usage.never_called_count}
              </div>
            `
          : null}
        <${ToolMetrics} />
      <//>
    </div>
  `
}
