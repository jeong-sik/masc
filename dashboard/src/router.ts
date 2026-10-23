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

function canonicalRoute(tab: TabId, params: Record<string, string>): RouteState {
  return { tab, params: normalizeRouteParams(tab, params), postId: null }
}

function normalizeSegments(pathPart: string): string[] {
  const normalized = pathPart.replace(/^\/+/, '')
  const segments = normalized.split('/').filter(Boolean).map(decodeSafe)
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
    const second = segments[1]
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
    const nextParams = { ...params, section: segments[1] }
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

  let pathPart = raw
  let queryPart: string | undefined

  if (raw.startsWith('?')) {
    pathPart = ''
    queryPart = raw.slice(1)
  } else {
    const qIndex = raw.indexOf('?')
    if (qIndex >= 0) {
      pathPart = raw.slice(0, qIndex)
      queryPart = raw.slice(qIndex + 1)
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
  const segments = pathname
    .replace(/^\/+/, '')
    .split('/')
    .filter(Boolean)
    .map(decodeSafe)
  // The server serves the dashboard at both / and /dashboard, so a link
  // written as /?tab=monitoring is the same request as /dashboard?tab=…. It
  // used to fall through to the default route, which is a silent answer to a
  // URL that named a destination.
  if (segments.length === 0) {
    return parseSegments([], parseParams(search.replace(/^\?/, '')))
  }
  if (segments[0] !== 'dashboard') return null

  const sub = segments.slice(1)
  if (sub[0] === 'assets' || sub[0] === 'credits') return null
  // /dashboard?tab=monitoring&section=… is the shape a person writes by hand,
  // and it used to land on overview: this returned DEFAULT_ROUTE with the
  // params attached, so `tab` rode along as a parameter of the wrong tab.
  // parseSegments already resolves a tab from the query when the path carries
  // none, so hand it the empty segment list rather than answering first.
  if (sub.length === 0) return parseSegments([], parseParams(search.replace(/^\?/, '')))

  const params = parseParams(search.replace(/^\?/, ''))
  return parseSegments(sub, params)
}

export function hashForRoute(tab: TabId, params?: Record<string, string>): string {
  return toHash(canonicalRoute(tab, params ?? {}))
}

function toHash(r: RouteState): string {
  const path = r.tab
  const paramEntries = Object.entries(r.params).filter(([key, value]) => {
    if (key === 'tab' && value === r.tab) return false
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

export function replaceRoute(tab: TabId, params?: Record<string, string>): void {
  const next = canonicalRoute(tab, params ?? {})
  const nextHash = toHash(next)
  route.value = next
  window.history.replaceState(
    null,
    '',
    `${window.location.pathname}${window.location.search}${nextHash}`,
  )
  window.dispatchEvent(new HashChangeEvent('hashchange'))
}

export function navigateToPost(postId: string): void {
  window.location.hash = `#board?post=${encodeURIComponent(postId)}`
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
