// Tool-related signals, constants, loader, and helper functions

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { fetchDashboardTools, type DashboardToolsResponse, type DashboardToolInventoryItem } from '../../api'
import { createManagedAsyncResource } from '../../lib/async-state'

// Managed (stale-while-revalidate): the previously loaded response stays
// readable while a refetch is in flight. Panel-level polling — the keeper
// lane strip re-fetches this shared resource on an interval — therefore
// keeps showing the last inventory instead of flashing a loading gap every
// cycle. A plain createAsyncResource would blank the data on each load.
const toolsResource = createManagedAsyncResource<DashboardToolsResponse>()

export const toolsData = computed(() => toolsResource.state.value.data)
export const toolsError = computed<string | null>(() => toolsResource.state.value.error)
export const toolsLoading = computed(() => toolsResource.state.value.loading)
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
  await toolsResource.load(signal => fetchDashboardTools({ signal }))
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
    tone === 'ok' ? 'text-[var(--color-status-info)] bg-[var(--info-soft)]'
      : tone === 'warn' ? 'text-[var(--color-status-warn)] bg-[var(--warn-soft)]'
      : tone === 'surface' ? 'text-[var(--color-status-stalled)] bg-[var(--stalled-soft)]'
      : 'text-[var(--color-fg-muted)] bg-[var(--color-bg-hover)]'
  return html`
    <span class="text-2xs rounded-[var(--r-0)] px-2 py-0.5 ${toneClass}">
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
