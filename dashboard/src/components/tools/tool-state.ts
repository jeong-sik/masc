// Tool-related signals, constants, loader, and helper functions

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { fetchDashboardTools, type DashboardToolsResponse, type DashboardToolInventoryItem } from '../../api'
import { createAsyncResource, getData } from '../../lib/async-state'

const toolsResource = createAsyncResource<DashboardToolsResponse>()

export const toolsData = computed(() => getData(toolsResource.state.value) ?? null)
export const toolsError = computed<string | null>(() => {
  const s = toolsResource.state.value
  return s.status === 'error' ? s.message : null
})
export const toolsLoading = computed(() => toolsResource.state.value.status === 'loading')
export const searchQuery = signal('')
export const categoryFilter = signal('all')
export const directOnly = signal(false)
export const showHidden = signal(false)
export const showDeprecated = signal(true)

export type SurfaceFilter = 'all' | 'public_mcp' | 'agent' | 'keeper' | 'internal'
export const surfaceFilter = signal<SurfaceFilter>('all')

export const SURFACE_MAP: Record<Exclude<SurfaceFilter, 'all'>, string[]> = {
  public_mcp: ['public_mcp'],
  agent: ['spawned_agent_mcp'],
  keeper: ['keeper_standard', 'keeper_privileged'],
  internal: ['local_worker', 'privileged_executor'],
}

export const SURFACE_LABELS: Record<SurfaceFilter, string> = {
  all: '전체',
  public_mcp: 'MCP 공개',
  agent: '에이전트',
  keeper: '키퍼',
  internal: '내부',
}

export async function loadTools() {
  await toolsResource.load(() => fetchDashboardTools())
}

export function hasSurface(item: DashboardToolInventoryItem, surface: string): boolean {
  return (item.surfaces ?? []).includes(surface)
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
    <span class="text-2xs rounded-sm px-2 py-0.5 ${toneClass}">
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
