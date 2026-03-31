// Tool-related signals, constants, loader, and helper functions

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { fetchDashboardTools, type DashboardToolsResponse, type DashboardToolInventoryItem } from '../../api'

export const toolsData = signal<DashboardToolsResponse | null>(null)
export const toolsError = signal<string | null>(null)
export const toolsLoading = signal(false)
export const searchQuery = signal('')
export const categoryFilter = signal('all')
export const enabledOnly = signal(false)
export const directOnly = signal(false)
export const showHidden = signal(false)
export const showDeprecated = signal(true)

export type SurfaceFilter = 'all' | 'public_mcp' | 'agent' | 'keeper' | 'internal'
export const surfaceFilter = signal<SurfaceFilter>('all')

export const SURFACE_MAP: Record<Exclude<SurfaceFilter, 'all'>, string[]> = {
  public_mcp: ['public_mcp'],
  agent: ['spawned_agent_mcp'],
  keeper: ['keeper_standard', 'keeper_privileged'],
  internal: ['local_worker', 'mdal_auditable', 'privileged_executor'],
}

export const SURFACE_LABELS: Record<SurfaceFilter, string> = {
  all: '전체',
  public_mcp: 'MCP 공개',
  agent: '에이전트',
  keeper: '키퍼',
  internal: '내부',
}

export async function loadTools() {
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

export function toolMatchesQuery(item: DashboardToolInventoryItem, rawQuery: string): boolean {
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

export function toolBadge(label: string, tone: 'default' | 'ok' | 'warn' | 'surface' = 'default') {
  const toneClass =
    tone === 'ok' ? 'text-[#7dd3fc] bg-[rgba(14,165,233,0.18)]'
      : tone === 'warn' ? 'text-[var(--warn)] bg-[var(--warn-12)]'
      : tone === 'surface' ? 'text-[#c4b5fd] bg-[rgba(139,92,246,0.18)]'
      : 'text-[var(--text-muted)] bg-[var(--white-8)]'
  return html`
    <span class="text-[11px] rounded-full px-2 py-0.5 ${toneClass}">
      ${label}
    </span>
  `
}

export function surfaceCountForFilter(inventory: DashboardToolInventoryItem[], filter: SurfaceFilter): number {
  if (filter === 'all') return inventory.length
  const targets = SURFACE_MAP[filter]
  return inventory.filter(item => (item.surfaces ?? []).some(s => targets.includes(s))).length
}

export const showBackToTop = signal(false)
export const showFullInventory = signal(false)
