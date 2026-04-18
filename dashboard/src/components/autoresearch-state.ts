// Autoresearch state management and data loading.
// Extracted from autoresearch.ts to separate state from UI.

import { signal, computed } from '@preact/signals'
import { requestConfirm } from './common/confirm-dialog'
import { createAsyncResource } from '../lib/async-state'
import {
  deleteAutoresearchLoop,
  fetchAutoresearchLoops,
  fetchAutoresearchLoopDetail,
  retryAutoresearchLoop,
  type AutoresearchLoopsResponse,
  type AutoresearchLoopDetail,
  type AutoresearchLoopSummary,
} from '../api'

// --- Loops list (deduplication via AsyncResource) ---

export const loopsResource = createAsyncResource<AutoresearchLoopsResponse>()
const loopsLimit = signal(100)

export const hasMoreLoops = computed(() => {
  const state = loopsResource.state.value
  if (state.status !== 'loaded') return false
  return state.data.total > state.data.loops.length
})

export async function loadMoreLoops() {
  loopsLimit.value += 100
  await loadLoops()
}

// --- Detail (manual signals with sequence counter for race-condition guard) ---

export const selectedLoopId = signal<string | null>(null)
export const loopDetail = signal<AutoresearchLoopDetail | null>(null)
export const detailLoading = signal(false)
export const detailError = signal<string | null>(null)

// --- Loop actions ---

export const loopActionBusy = signal(false)
export const loopActionError = signal<string | null>(null)

let pendingRefreshDetail = false
let detailRequestSeq = 0

export const authorFilter = signal<string>('all')

export const filteredLoops = computed<AutoresearchLoopSummary[]>(() => {
  const state = loopsResource.state.value
  const loops = state.status === 'loaded' ? state.data.loops : []
  const filter = authorFilter.value
  if (filter === 'all') return loops
  return loops.filter(l => l.author === filter || (filter === 'unknown' && !l.author))
})

export const availableAuthors = computed<string[]>(() => {
  const state = loopsResource.state.value
  if (state.status !== 'loaded') return []
  const authors = new Set<string>()
  for (const loop of state.data.loops) {
    if (loop.author) authors.add(loop.author)
  }
  return Array.from(authors).sort()
})

// --- Computed ---

export const selectedLoop = computed<AutoresearchLoopSummary | null>(() => {
  const id = selectedLoopId.value
  const state = loopsResource.state.value
  if (!id || state.status !== 'loaded') return null
  return state.data.loops.find(l => l.loop_id === id) ?? null
})

// --- Data loading ---

function nextSelectedLoopId(data: AutoresearchLoopsResponse): string | null {
  const currentId = selectedLoopId.value
  if (currentId && data.loops.some(loop => loop.loop_id === currentId)) {
    return currentId
  }
  return data.loops[0]?.loop_id ?? null
}

export async function syncSelectedLoopDetail(data: AutoresearchLoopsResponse): Promise<void> {
  const nextLoopId = nextSelectedLoopId(data)
  selectedLoopId.value = nextLoopId
  if (!nextLoopId) {
    loopDetail.value = null
    detailError.value = null
    return
  }
  await loadDetail(nextLoopId)
}

export async function loadLoops({ refreshDetail = false }: { refreshDetail?: boolean } = {}) {
  pendingRefreshDetail ||= refreshDetail

  await loopsResource.load(async () => {
    const data = await fetchAutoresearchLoops(0, loopsLimit.value)
    if (pendingRefreshDetail) {
      pendingRefreshDetail = false
      await syncSelectedLoopDetail(data)
    } else if (!selectedLoopId.value && data.loops.length > 0) {
      const first = data.loops[0]
      if (first) {
        selectedLoopId.value = first.loop_id
      }
    }
    return data
  })
}

export async function refreshAutoresearchSurface(): Promise<void> {
  await loadLoops({ refreshDetail: true })
}

export async function loadDetail(loopId: string) {
  const requestSeq = ++detailRequestSeq
  detailLoading.value = true
  detailError.value = null
  try {
    const detail = await fetchAutoresearchLoopDetail(loopId)
    if (requestSeq !== detailRequestSeq || selectedLoopId.value !== loopId) return
    loopDetail.value = detail
  } catch (err) {
    if (requestSeq !== detailRequestSeq || selectedLoopId.value !== loopId) return
    loopDetail.value = null
    detailError.value = err instanceof Error ? err.message : String(err)
  } finally {
    if (requestSeq !== detailRequestSeq) return
    detailLoading.value = false
  }
}

export function selectLoop(loopId: string) {
  selectedLoopId.value = loopId
  loadDetail(loopId)
}

// --- Actions ---

export async function runLoopAction(action: () => Promise<unknown>) {
  loopActionBusy.value = true
  loopActionError.value = null
  try {
    await action()
    await refreshAutoresearchSurface()
  } catch (err) {
    loopActionError.value = err instanceof Error ? err.message : String(err)
  } finally {
    loopActionBusy.value = false
  }
}

export async function retrySelectedLoop() {
  const loop = selectedLoop.value
  if (!loop?.loop_id) return
  await runLoopAction(() => retryAutoresearchLoop(loop.loop_id))
}

export async function deleteSelectedLoop() {
  const loop = selectedLoop.value
  if (!loop?.loop_id) return
  const confirmed = await requestConfirm({
    title: '루프 삭제',
    message: `루프 ${loop.loop_id}와 연결된 worktree/branch/results를 삭제합니다. 계속할까요?`,
    tone: 'danger'
  })
  if (!confirmed) return
  await runLoopAction(() => deleteAutoresearchLoop(loop.loop_id))
}

// --- Reset (called by form module too, so accepts a callback) ---

export function resetAutoresearchState(resetFormFields?: () => void): void {
  loopsResource.reset()
  selectedLoopId.value = null
  loopDetail.value = null
  detailLoading.value = false
  detailError.value = null
  loopActionBusy.value = false
  loopActionError.value = null
  pendingRefreshDetail = false
  detailRequestSeq = 0
  if (resetFormFields) resetFormFields()
}
