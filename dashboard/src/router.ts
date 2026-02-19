// MASC Dashboard — Hash-based router
// Reads location.hash and produces a signal-based RouteState

import { signal, type ReadonlySignal } from '@preact/signals'
import type { RouteState, TabId } from './types'
import { VALID_TABS } from './types'

function parseHash(hash: string): RouteState {
  const h = (hash || '').replace(/^#/, '')
  if (!h) return { tab: 'overview', params: {}, postId: null }

  const [pathPart, queryPart] = h.split('?') as [string, string | undefined]
  const segments = pathPart.split('/')
  const tab: TabId = VALID_TABS.includes(segments[0] as TabId)
    ? (segments[0] as TabId)
    : 'overview'

  // #board/post/{id}
  let postId: string | null = null
  if (segments[0] === 'board' && segments[1] === 'post' && segments[2]) {
    postId = segments[2]
  }

  // Parse query params
  const params: Record<string, string> = {}
  if (queryPart) {
    const sp = new URLSearchParams(queryPart)
    sp.forEach((v, k) => { params[k] = v })
  }

  return { tab, params, postId }
}

// --- Reactive route signal ---

export const route = signal<RouteState>(parseHash(window.location.hash))

// Listen for hash changes
window.addEventListener('hashchange', () => {
  route.value = parseHash(window.location.hash)
})

// --- Navigation helpers ---

export function navigate(tab: TabId, params?: Record<string, string>): void {
  let hash = `#${tab}`
  if (params && Object.keys(params).length > 0) {
    const sp = new URLSearchParams(params)
    hash += `?${sp.toString()}`
  }
  window.location.hash = hash
}

export function navigateToPost(postId: string): void {
  window.location.hash = `#board/post/${postId}`
}

export function navigateBack(): void {
  // Go back to the parent tab
  const current = route.value
  window.location.hash = `#${current.tab}`
}

// --- Hook for components ---

export function useRoute(): ReadonlySignal<RouteState> {
  return route
}

// Auto-apply initial hash from URL on load
// (handled by signal initialization above)

// --- Deep link: restore tab from initial hash on first load ---

export function initRouter(): void {
  // If no hash, set default
  if (!window.location.hash || window.location.hash === '#') {
    window.location.hash = '#overview'
  }
  // Parse current hash
  route.value = parseHash(window.location.hash)
}
