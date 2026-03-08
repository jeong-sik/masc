// MASC Dashboard — Hash-based router
// Reads location.hash and supports legacy deep-link forms:
// #overview, #/overview, #board/post/:id, #tab=agents, /dashboard/agents

import { signal, type ReadonlySignal } from '@preact/signals'
import type { RouteState, TabId } from './types'
import { VALID_TABS } from './types'

const DEFAULT_ROUTE: RouteState = { tab: 'overview', params: {}, postId: null }
const LEGACY_TAB_ALIASES: Record<string, TabId> = {
  journal: 'overview',
  mdal: 'goals',
  tasks: 'goals',
  execution: 'overview',
  council: 'board',
  activity: 'overview',
}

function isTabId(v: string | null | undefined): v is TabId {
  return !!v && VALID_TABS.includes(v as TabId)
}

function normalizeTabAlias(v: string | null | undefined): string | undefined {
  if (!v) return undefined
  return LEGACY_TAB_ALIASES[v] ?? v
}

function decodeSafe(input: string): string {
  try {
    return decodeURIComponent(input)
  } catch {
    return input
  }
}

function parseParams(raw: string | undefined): Record<string, string> {
  const params: Record<string, string> = {}
  if (!raw) return params

  const sp = new URLSearchParams(raw)
  sp.forEach((v, k) => {
    params[k] = v
  })
  return params
}

function normalizeSegments(pathPart: string): string[] {
  const normalized = pathPart.replace(/^\/+/, '')
  const segments = normalized.split('/').filter(Boolean)
  if (segments[0] === 'dashboard') return segments.slice(1)
  return segments
}

function parseSegments(
  segments: string[],
  params: Record<string, string>,
): RouteState {
  if (segments[0] === 'chains') {
    const nextParams: Record<string, string> = { ...params, surface: 'chains' }
    if (segments[1] === 'operation' && segments[2]) {
      nextParams.operation = decodeSafe(segments[2])
    }
    return { tab: 'command', params: nextParams, postId: null }
  }

  const tabFromPath = normalizeTabAlias(segments[0])
  const tabFromQuery = normalizeTabAlias(params.tab)
  const tab: TabId = isTabId(tabFromPath)
    ? tabFromPath
    : isTabId(tabFromQuery)
      ? tabFromQuery
      : 'overview'

  let postId: string | null = null
  if (tab === 'board') {
    if (segments[0] === 'board' && segments[1] === 'post' && segments[2]) {
      postId = decodeSafe(segments[2])
    } else if (segments[0] === 'post' && segments[1]) {
      postId = decodeSafe(segments[1])
    }
  }

  return { tab, params, postId }
}

function parseHash(hash: string): RouteState {
  const raw = (hash || '').replace(/^#/, '').trim()
  if (!raw) return DEFAULT_ROUTE

  const decoded = decodeSafe(raw)
  let pathPart = decoded
  let queryPart: string | undefined

  if (decoded.startsWith('?')) {
    pathPart = ''
    queryPart = decoded.slice(1)
  } else {
    const qIndex = decoded.indexOf('?')
    if (qIndex >= 0) {
      pathPart = decoded.slice(0, qIndex)
      queryPart = decoded.slice(qIndex + 1)
    }
  }

  // Legacy format: #tab=agents&room=xxx
  if (!queryPart && pathPart.includes('=') && !pathPart.includes('/')) {
    queryPart = pathPart
    pathPart = ''
  }

  const params = parseParams(queryPart)
  const segments = normalizeSegments(pathPart)
  return parseSegments(segments, params)
}

function parsePathname(pathname: string, search: string): RouteState | null {
  const segments = pathname.replace(/^\/+/, '').split('/').filter(Boolean)
  if (segments[0] !== 'dashboard') return null

  const sub = segments.slice(1)
  if (sub.length === 0) return { ...DEFAULT_ROUTE, params: parseParams(search.replace(/^\?/, '')) }
  if (sub[0] === 'assets' || sub[0] === 'credits' || sub[0] === 'lodge') return null

  const params = parseParams(search.replace(/^\?/, ''))
  return parseSegments(sub, params)
}

function toHash(r: RouteState): string {
  const path = r.postId
    ? `board/post/${encodeURIComponent(r.postId)}`
    : r.tab
  const paramEntries = Object.entries(r.params).filter(([k]) => k !== 'tab')
  if (paramEntries.length === 0) return `#${path}`
  const sp = new URLSearchParams(paramEntries)
  return `#${path}?${sp.toString()}`
}

// --- Reactive route signal ---

export const route = signal<RouteState>(parseHash(window.location.hash))

// Listen for hash changes
window.addEventListener('hashchange', () => {
  route.value = parseHash(window.location.hash)
})

// --- Navigation helpers ---

export function navigate(tab: TabId, params?: Record<string, string>): void {
  const next = { tab, params: params ?? {}, postId: null } satisfies RouteState
  window.location.hash = toHash(next)
}

export function navigateToPost(postId: string): void {
  window.location.hash = `#board/post/${encodeURIComponent(postId)}`
}

export function navigateBack(): void {
  const current = route.value
  window.location.hash = `#${current.tab}`
}

// --- Hook for components ---

export function useRoute(): ReadonlySignal<RouteState> {
  return route
}

export function initRouter(): void {
  // Priority 1: explicit hash route
  if (window.location.hash && window.location.hash !== '#') {
    route.value = parseHash(window.location.hash)
    return
  }

  // Priority 2: path deep-link route (/dashboard/:tab)
  const fromPath = parsePathname(window.location.pathname, window.location.search)
  if (fromPath) {
    route.value = fromPath
    const canonicalHash = toHash(fromPath)
    window.history.replaceState(
      null,
      '',
      `${window.location.pathname}${window.location.search}${canonicalHash}`,
    )
    return
  }

  // Default route
  window.location.hash = '#overview'
  route.value = parseHash(window.location.hash)
}
