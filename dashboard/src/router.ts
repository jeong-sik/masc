// MASC Dashboard — Hash-based router
// Reads location.hash for canonical dashboard routes.
// Legacy tab IDs (pre-restructure) are transparently redirected to the current IA.

import { signal, type ReadonlySignal } from '@preact/signals'
import type { RouteState, TabId, AnyTabId, LegacyTabId } from './types'
import { VALID_TABS, LEGACY_TAB_REDIRECTS } from './types'
import { normalizeRouteParams } from './config/navigation'

const DEFAULT_ROUTE: RouteState = { tab: 'overview', params: {}, postId: null }
const COMMAND_SURFACE_SEGMENTS = new Set([
  'orchestra',
  'swarm',
  'operations',
  'chains',
  'control',
])
const LAB_SECTION_SEGMENTS = new Set(['overview', 'autoresearch'])

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
  // Deep-link: /chains/operation/:id -> operations command surface
  if (segments[0] === 'chains') {
    const nextParams: Record<string, string> = {
      ...params,
      section: 'command',
      surface: 'chains',
    }
    if (segments[1] === 'operation' && segments[2]) {
      nextParams.operation = decodeSafe(segments[2])
    }
    return {
      tab: 'command',
      params: normalizeRouteParams('command', nextParams),
      postId: null,
    }
  }

  // Legacy deep-link: /lab/:surface
  if (segments[0] === 'lab') {
    if (segments[1]) {
      const section = decodeSafe(segments[1])
      const nextParams = { ...params }
      if (LAB_SECTION_SEGMENTS.has(section)) {
        nextParams.section = section
        return {
          tab: 'lab',
          params: normalizeRouteParams('lab', nextParams),
          postId: null,
        }
      }
      nextParams.section = 'command'
      nextParams.surface = section
      return {
        tab: 'command',
        params: normalizeRouteParams('command', nextParams),
        postId: null,
      }
    }
    if (params.surface) {
      const nextParams = { ...params }
      nextParams.section = 'command'
      return {
        tab: 'command',
        params: normalizeRouteParams('command', nextParams),
        postId: null,
      }
    }
    if (!params.section && !params.surface) {
      return {
        tab: 'command',
        params: normalizeRouteParams('command', { ...params, section: 'command' }),
        postId: null,
      }
    }
    const nextParams = { ...params }
    return {
      tab: 'lab',
      params: normalizeRouteParams('lab', nextParams),
      postId: null,
    }
  }

  if ((segments[0] === 'operations' || segments[0] === 'command') && segments[1]) {
    const nextParams = { ...params }
    const second = decodeSafe(segments[1])
    if (second === 'intervene' || second === 'command' || second === 'tools') {
      nextParams.section = second
    } else if (COMMAND_SURFACE_SEGMENTS.has(second)) {
      nextParams.section = 'command'
      nextParams.surface = second
    }
    return {
      tab: 'command',
      params: normalizeRouteParams('command', nextParams),
      postId: null,
    }
  }

  if ((segments[0] === 'status' || segments[0] === 'monitoring' || segments[0] === 'work' || segments[0] === 'workspace') && segments[1]) {
    const rawTab = segments[0]
    const tab = (rawTab === 'status' ? 'monitoring' : rawTab === 'work' ? 'workspace' : rawTab) as 'monitoring' | 'workspace'
    const nextParams = { ...params, section: decodeSafe(segments[1]) }
    return {
      tab,
      params: normalizeRouteParams(tab, nextParams),
      postId: null,
    }
  }

  const tabFromPath = segments[0]
  const tabFromQuery = params.tab

  // Lab tab removed (#2898). Redirect legacy lab bookmarks (e.g. #lab?surface=trpg)
  // to command tab. No valid lab section exists to fall back to.
  if ((tabFromPath === 'lab' || tabFromQuery === 'lab') && params.surface && !params.section) {
    const nextParams = { ...params, section: 'command' }
    return {
      tab: 'command',
      params: normalizeRouteParams('command', nextParams),
      postId: null,
    }
  }

  // Resolve with legacy redirect support
  const resolved = resolveTab(tabFromPath) || resolveTab(tabFromQuery) || { tab: 'overview' as TabId }
  const mergedParams = normalizeRouteParams(resolved.tab, { ...params, ...(resolved.params ?? {}) })

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
  const baseParams = redirect?.params
    ? { ...redirect.params, ...(params ?? {}) }
    : params ?? {}
  const next = {
    tab: resolvedTab,
    params: normalizeRouteParams(resolvedTab, baseParams),
    postId: null,
  } satisfies RouteState
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
  window.location.hash = `#workspace?section=board&post=${encodeURIComponent(postId)}`
}

export function navigateBack(): void {
  const current = route.value
  window.location.hash = toHash({
    tab: current.tab,
    params: normalizeRouteParams(current.tab, {}),
    postId: null,
  })
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
  window.location.hash = '#overview'
  route.value = parseHash(window.location.hash)
}
