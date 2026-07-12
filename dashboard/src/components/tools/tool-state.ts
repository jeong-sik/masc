// Tool-related signals, constants, loader, and helper functions

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { fetchDashboardTools, type DashboardToolsResponse, type DashboardToolInventoryItem } from '../../api'
import { createManagedAsyncResource } from '../../lib/async-state'
import { setupVisibleAutoRefresh } from '../../lib/auto-refresh'
import { registerKeeperChatQueueRefresh } from '../../sse-store'

// Managed (stale-while-revalidate): the previously loaded response stays
// readable while a refetch is in flight. Panel-level polling — the keeper
// lane strip re-fetches this shared resource on an interval — therefore
// keeps showing the last inventory instead of flashing a loading gap every
// cycle. A plain createAsyncResource would blank the data on each load.
const toolsResource = createManagedAsyncResource<DashboardToolsResponse>()
const expectedKeeperChatQueueRevisions = new Map<string, number>()

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

function noteExpectedKeeperChatQueueRevisions(
  expectedRevisions: ReadonlyMap<string, number>,
): void {
  for (const [keeperName, revision] of expectedRevisions) {
    const previous = expectedKeeperChatQueueRevisions.get(keeperName) ?? -1
    expectedKeeperChatQueueRevisions.set(keeperName, Math.max(previous, revision))
  }
}

function assertExpectedKeeperChatQueueRevisions(
  data: DashboardToolsResponse,
  expectedRevisions: ReadonlyMap<string, number>,
): void {
  for (const [keeperName, expectedRevision] of expectedRevisions) {
    const keeper = data.keeper_waiting_inventory?.keepers
      .find(candidate => candidate.keeper_name === keeperName)
    const observedRevision = keeper?.chat_queue.revision
    if (typeof observedRevision !== 'number' || observedRevision < expectedRevision) {
      throw new Error(
        `Keeper chat queue projection is stale for ${keeperName}: expected revision ${expectedRevision}, observed ${observedRevision ?? 'missing'}`,
      )
    }
  }
}

export async function loadTools(): Promise<void> {
  const expectedAtRequest = new Map(expectedKeeperChatQueueRevisions)
  const result = await toolsResource.load(async signal => {
    const data = await fetchDashboardTools({
      signal,
      freshKeeperChatQueue: expectedAtRequest.size > 0,
    })
    assertExpectedKeeperChatQueueRevisions(data, expectedAtRequest)
    return data
  })
  if (!result) return
  for (const [keeperName, expectedRevision] of expectedKeeperChatQueueRevisions) {
    const observedRevision = result.keeper_waiting_inventory?.keepers
      .find(candidate => candidate.keeper_name === keeperName)
      ?.chat_queue.revision
    if (typeof observedRevision === 'number' && observedRevision >= expectedRevision) {
      expectedKeeperChatQueueRevisions.delete(keeperName)
    }
  }
}

export const KEEPER_WAITING_INVENTORY_REFRESH_MS = 15_000
let toolsRefreshSubscriberCount = 0
let stopToolsRefresh: (() => void) | null = null

/** Share one visibility-aware tools poller across every mounted Keeper lane
 * and conversation surface. The managed resource deduplicates fetch state;
 * this subscription also deduplicates the timer and global visibility/focus
 * listeners that trigger it. */
export function subscribeToolsAutoRefresh(): () => void {
  toolsRefreshSubscriberCount += 1
  if (toolsRefreshSubscriberCount === 1) {
    // A cached snapshot is displayable while revalidation runs, but it is not
    // evidence that a newly mounted operator surface has current queue truth.
    // Always revalidate on the first subscriber mount; the managed resource
    // retains the prior data so this does not introduce a loading flash.
    if (!toolsLoading.value) void loadTools()
    stopToolsRefresh = setupVisibleAutoRefresh(() => {
      void loadTools()
    }, KEEPER_WAITING_INVENTORY_REFRESH_MS)
  }
  return () => {
    toolsRefreshSubscriberCount = Math.max(0, toolsRefreshSubscriberCount - 1)
    if (toolsRefreshSubscriberCount === 0) {
      stopToolsRefresh?.()
      stopToolsRefresh = null
    }
  }
}

registerKeeperChatQueueRefresh((expectedRevisions) => {
  noteExpectedKeeperChatQueueRevisions(expectedRevisions)
  void loadTools()
})

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
