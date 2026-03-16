// MASC Dashboard — Hash-based router
// Reads location.hash for canonical dashboard routes only.
// Legacy aliases were intentionally removed during the operator-console rewrite.

import { signal, type ReadonlySignal } from '@preact/signals'
import type { RouteState, TabId } from './types'
import { VALID_TABS } from './types'

const DEFAULT_ROUTE: RouteState = { tab: 'home', params: {}, postId: null }

function isTabId(v: string | null | undefined): v is TabId {
  return !!v && VALID_TABS.includes(v as TabId)
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

  if (segments[0] === 'lab') {
    const nextParams = { ...params }
    if (segments[1]) {
      nextParams.surface = decodeSafe(segments[1])
    }
    return { tab: 'lab', params: nextParams, postId: null }
  }

  const tabFromPath = segments[0]
  const tabFromQuery = params.tab
  const tab: TabId = isTabId(tabFromPath)
    ? tabFromPath
    : isTabId(tabFromQuery)
      ? tabFromQuery
      : 'home'

  return { tab, params, postId: null }
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
  const path = r.tab === 'lab' && r.params.surface
    ? `lab/${encodeURIComponent(r.params.surface)}`
    : r.tab
  const paramEntries = Object.entries(r.params).filter(([key]) => {
    if (key === 'tab') return false
    if (r.tab === 'lab' && key === 'surface') return false
    return true
  })
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
  window.location.hash = `#memory?post=${encodeURIComponent(postId)}`
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
  window.location.hash = '#home'
  route.value = parseHash(window.location.hash)
}
