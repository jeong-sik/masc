// MASC Dashboard — Hash-based router
// Reads location.hash for canonical dashboard routes.

import { signal } from '@preact/signals'
import type { RouteState, TabId } from './types'
import { VALID_TABS } from './types'
import { normalizeRouteParams, sectionItemsForTab } from './config/navigation'
import { cockpitTargetForParams, normalizeCockpitMode } from './cockpit-entrypoints'

const DEFAULT_ROUTE: RouteState = { tab: 'overview', params: {}, postId: null }
const VALID_COMMAND_SECTIONS = new Set(
  sectionItemsForTab('command').map(item => item.params.section),
)

interface CrossSurfaceRedirect {
  tab: TabId
  section: string
  view?: string
  params?: Record<string, string>
}

type TabSectionKey = `${TabId}:${string}`

const CROSS_SURFACE_SECTION_REDIRECTS: Record<TabSectionKey, CrossSurfaceRedirect> = {
  'monitoring:git-graph': {
    tab: 'workspace',
    section: 'repositories',
    view: 'graph',
  },
  'monitoring:safe-autonomy': {
    tab: 'command',
    section: 'operations',
    view: 'safety',
  },
}

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

function routeForCockpitMode(params: Record<string, string>): RouteState | null {
  const redirect = cockpitTargetForParams(params)
  if (!redirect) return null

  const nextParams = { ...params, ...(redirect.params ?? {}) }
  return canonicalRoute(redirect.tab, nextParams)
}

function shouldApplyCockpitModeRoute(segments: string[], params: Record<string, string>): boolean {
  if (!normalizeCockpitMode(params.mode ?? params.plane)) return false
  if (segments.length === 0) return true
  if (segments.length === 1 && isTabId(segments[0]) && !params.section) return true
  return false
}

function applyCrossSurfaceRedirect(
  tab: TabId,
  params: Record<string, string>,
): { tab: TabId; params: Record<string, string> } | null {
  const section = params.section
  if (!section) return null
  const redirect = CROSS_SURFACE_SECTION_REDIRECTS[`${tab}:${section}` as TabSectionKey]
  if (!redirect) return null

  const nextParams = { ...params, ...(redirect.params ?? {}) }
  nextParams.section = redirect.section
  if (redirect.view && !nextParams.view) nextParams.view = redirect.view
  return { tab: redirect.tab, params: nextParams }
}

function canonicalRoute(tab: TabId, params: Record<string, string>): RouteState {
  const rawCrossSurface = applyCrossSurfaceRedirect(tab, params)
  if (rawCrossSurface) {
    return {
      tab: rawCrossSurface.tab,
      params: normalizeRouteParams(rawCrossSurface.tab, rawCrossSurface.params),
      postId: null,
    }
  }

  const normalizedParams = normalizeRouteParams(tab, params)
  const normalizedCrossSurface = applyCrossSurfaceRedirect(tab, normalizedParams)
  if (normalizedCrossSurface) {
    return {
      tab: normalizedCrossSurface.tab,
      params: normalizeRouteParams(normalizedCrossSurface.tab, normalizedCrossSurface.params),
      postId: null,
    }
  }

  return { tab, params: normalizedParams, postId: null }
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
  if (shouldApplyCockpitModeRoute(segments, params)) {
    const cockpitModeRoute = routeForCockpitMode(params)
    if (cockpitModeRoute) return cockpitModeRoute
  }

  if (segments[0] === 'command' && segments[1]) {
    const nextParams = { ...params }
    const second = decodeSafe(segments[1])
    if (!VALID_COMMAND_SECTIONS.has(second)) {
      console.warn('[router] unknown command section, falling back to operations', second)
      nextParams.section = 'operations'
    } else {
      nextParams.section = second
    }
    return canonicalRoute('command', nextParams)
  }

  if (
    (segments[0] === 'monitoring' || segments[0] === 'workspace' || segments[0] === 'lab' || segments[0] === 'code')
    && segments[1]
  ) {
    const tab = segments[0] as 'monitoring' | 'workspace' | 'lab' | 'code'
    const nextParams = { ...params, section: decodeSafe(segments[1]) }
    return canonicalRoute(tab, nextParams)
  }

  const tabFromPath = segments[0]
  const tabFromQuery = params.tab

  const resolvedTab =
    (isTabId(tabFromPath) && tabFromPath)
    || (isTabId(tabFromQuery) && tabFromQuery)
    || 'overview'
  return canonicalRoute(resolvedTab, params)
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

  if (!queryPart && hashLooksLikeQuery(raw)) {
    queryPart = raw
    pathPart = ''
  }

  const params = parseParams(queryPart)
  const segments = normalizeSegments(pathPart)
  return parseSegments(segments, params)
}

function hashLooksLikeQuery(rawHashBody: string): boolean {
  const eqIndex = rawHashBody.indexOf('=')
  if (eqIndex < 0) return false
  const slashIndex = rawHashBody.indexOf('/')
  return slashIndex < 0 || eqIndex < slashIndex
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

export function hashForRoute(tab: TabId, params?: Record<string, string>): string {
  return toHash(canonicalRoute(tab, params ?? {}))
}

function toHash(r: RouteState): string {
  const path = r.tab
  const paramEntries = Object.entries(r.params).filter(([key]) => {
    if (key === 'tab') return false
    return true
  })
  if (paramEntries.length === 0) return `#${path}`
  const sp = new URLSearchParams(paramEntries)
  return `#${path}?${sp.toString()}`
}

// --- Reactive route signal ---

export const route = signal<RouteState>(parseHash(window.location.hash))

// Listen for hash changes and normalize the route state into canonical hashes.
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

export function navigate(tab: TabId, params?: Record<string, string>): void {
  const next = canonicalRoute(tab, params ?? {})
  const nextHash = hashForRoute(tab, params)
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
  window.location.hash = `#workspace?section=board&post=${encodeURIComponent(postId)}`
}

export function initRouter(): void {
  // Priority 1: explicit hash route
  if (window.location.hash && window.location.hash !== '#') {
    route.value = parseHash(window.location.hash)
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
  window.location.hash = '#overview'
  route.value = parseHash(window.location.hash)
}
