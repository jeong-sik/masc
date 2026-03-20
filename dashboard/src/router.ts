// MASC Dashboard — Hash-based router
// Reads location.hash for canonical dashboard routes.
// Legacy tab IDs (pre-restructure) are transparently redirected to new 7-tab structure.

import { signal, type ReadonlySignal } from '@preact/signals'
import type { RouteState, TabId, AnyTabId, LegacyTabId } from './types'
import { VALID_TABS, LEGACY_TAB_REDIRECTS } from './types'

const DEFAULT_ROUTE: RouteState = { tab: 'home', params: {}, postId: null }

function isTabId(v: string | null | undefined): v is TabId {
  return !!v && VALID_TABS.includes(v as TabId)
}

/** Resolve a raw string to a new TabId, applying legacy redirects if needed. */
function resolveTab(raw: string | null | undefined): { tab: TabId; params?: Record<string, string> } | null {
  if (!raw) return null
  if (isTabId(raw)) return { tab: raw }
  const redirect = LEGACY_TAB_REDIRECTS[raw as LegacyTabId]
  if (redirect) return { tab: redirect.tab, params: redirect.params }
  return null
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
  // Deep-link: /chains/operation/:id -> lab tab
  if (segments[0] === 'chains') {
    const nextParams: Record<string, string> = { ...params, surface: 'chains' }
    if (segments[1] === 'operation' && segments[2]) {
      nextParams.operation = decodeSafe(segments[2])
    }
    return { tab: 'lab', params: nextParams, postId: null }
  }

  // Deep-link: /lab/:surface -> lab tab
  if (segments[0] === 'lab') {
    const nextParams = { ...params }
    if (segments[1]) {
      nextParams.surface = decodeSafe(segments[1])
    }
    return { tab: 'lab', params: nextParams, postId: null }
  }

  const tabFromPath = segments[0]
  const tabFromQuery = params.tab

  // Resolve with legacy redirect support
  const resolved = resolveTab(tabFromPath) || resolveTab(tabFromQuery) || { tab: 'home' as TabId }
  const mergedParams = { ...params, ...(resolved.params ?? {}) }

  return { tab: resolved.tab, params: mergedParams, postId: null }
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
  if (sub[0] === 'assets' || sub[0] === 'credits') return null

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

// Listen for hash changes — silently replace legacy hashes with canonical form
window.addEventListener('hashchange', () => {
  const parsed = parseHash(window.location.hash)
  route.value = parsed
  const canonical = toHash(parsed)
  if (window.location.hash !== canonical) {
    window.history.replaceState(
      null,
      '',
      `${window.location.pathname}${window.location.search}${canonical}`,
    )
  }
})

// --- Navigation helpers ---

/** Navigate to a tab. Accepts both new and legacy tab IDs (legacy are silently redirected). */
export function navigate(tab: AnyTabId, params?: Record<string, string>): void {
  const redirect = LEGACY_TAB_REDIRECTS[tab as LegacyTabId]
  const resolvedTab: TabId = redirect ? redirect.tab : tab as TabId
  const resolvedParams = redirect?.params
    ? { ...redirect.params, ...(params ?? {}) }
    : params ?? {}
  const next = { tab: resolvedTab, params: resolvedParams, postId: null } satisfies RouteState
  const nextHash = toHash(next)
  // Update signal synchronously so Preact re-renders immediately.
  // Without this, clicking the same surface twice is needed because
  // hashchange fires asynchronously and may be skipped if the hash
  // is identical to the current value.
  route.value = next
  if (window.location.hash !== nextHash) {
    window.location.hash = nextHash
  }
}

export function navigateToPost(postId: string): void {
  window.location.hash = `#work?section=board&post=${encodeURIComponent(postId)}`
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
    // Replace legacy hash with canonical form
    const canonical = toHash(route.value)
    if (window.location.hash !== canonical) {
      window.history.replaceState(
        null,
        '',
        `${window.location.pathname}${window.location.search}${canonical}`,
      )
    }
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
