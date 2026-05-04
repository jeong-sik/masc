// theme-sync.ts — Preact↔Bonsai theme sync via localStorage + URL search params
//
// Kimi design system sec08 8.2.2: bidirectional theme synchronization across surfaces.
//
// Theme is persisted in localStorage and optionally reflected in the URL
// *search* params (?theme=...) so it does not interfere with the hash-based
// router (router.ts canonicalises #<tab>?...).

import type { ThemeId } from './use-theme'

export const THEME_STORAGE_KEY = 'masc-theme-v2'
export const THEME_SEARCH_PARAM = 'theme'

export function updateThemeSearchParam(theme: ThemeId) {
  if (typeof location === 'undefined') return
  const url = new URL(location.href)
  if (url.searchParams.get(THEME_SEARCH_PARAM) !== theme) {
    url.searchParams.set(THEME_SEARCH_PARAM, theme)
    history.replaceState(null, '', url.toString())
  }
}

export function parseThemeFromSearch(search: string): ThemeId | null {
  const sp = new URLSearchParams(search.replace(/^\?/, ''))
  const theme = sp.get(THEME_SEARCH_PARAM)
  if (theme === 'dark' || theme === 'light' || theme === 'dark-fantasy' || theme === 'paper') {
    return theme
  }
  return null
}

export interface ThemeSyncListeners {
  onStorageChange?: (theme: ThemeId) => void
  onSearchChange?: (theme: ThemeId) => void
}

export function syncThemeAcrossSurfaces(listeners?: ThemeSyncListeners) {
  if (typeof window === 'undefined') return () => {}

  const handleStorage = (e: StorageEvent) => {
    if (e.key === THEME_STORAGE_KEY && e.newValue) {
      const theme = e.newValue as ThemeId
      document.documentElement.setAttribute('data-theme', theme)
      updateThemeSearchParam(theme)
      listeners?.onStorageChange?.(theme)
    }
  }

  const handlePopState = () => {
    const theme = parseThemeFromSearch(location.search)
    if (theme) {
      localStorage.setItem(THEME_STORAGE_KEY, theme)
      document.documentElement.setAttribute('data-theme', theme)
      listeners?.onSearchChange?.(theme)
    }
  }

  window.addEventListener('storage', handleStorage)
  window.addEventListener('popstate', handlePopState)

  return () => {
    window.removeEventListener('storage', handleStorage)
    window.removeEventListener('popstate', handlePopState)
  }
}
