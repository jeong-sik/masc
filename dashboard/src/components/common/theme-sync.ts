// theme-sync.ts — Preact↔Bonsai theme sync via localStorage + URL hash
//
// Kimi design system sec08 8.2.2: bidirectional theme synchronization across surfaces.

import type { ThemeId } from './use-theme'

export const THEME_STORAGE_KEY = 'masc-theme-v2'
export const THEME_HASH_PREFIX = '#theme='

export function updateUrlHash(theme: ThemeId) {
  const newHash = `${THEME_HASH_PREFIX}${theme}`
  if (typeof location !== 'undefined' && location.hash !== newHash) {
    history.replaceState(null, '', newHash)
  }
}

export function parseThemeFromHash(hash: string): ThemeId | null {
  if (hash.startsWith(THEME_HASH_PREFIX)) {
    const theme = hash.slice(THEME_HASH_PREFIX.length)
    if (theme === 'dark' || theme === 'light' || theme === 'dark-fantasy' || theme === 'paper') {
      return theme
    }
  }
  return null
}

export interface ThemeSyncListeners {
  onStorageChange?: (theme: ThemeId) => void
  onHashChange?: (theme: ThemeId) => void
}

export function syncThemeAcrossSurfaces(listeners?: ThemeSyncListeners) {
  if (typeof window === 'undefined') return () => {}

  const handleStorage = (e: StorageEvent) => {
    if (e.key === THEME_STORAGE_KEY && e.newValue) {
      const theme = e.newValue as ThemeId
      document.documentElement.setAttribute('data-theme', theme)
      updateUrlHash(theme)
      listeners?.onStorageChange?.(theme)
    }
  }

  const handleHashChange = () => {
    const theme = parseThemeFromHash(location.hash)
    if (theme) {
      localStorage.setItem(THEME_STORAGE_KEY, theme)
      document.documentElement.setAttribute('data-theme', theme)
      listeners?.onHashChange?.(theme)
    }
  }

  window.addEventListener('storage', handleStorage)
  window.addEventListener('hashchange', handleHashChange)

  return () => {
    window.removeEventListener('storage', handleStorage)
    window.removeEventListener('hashchange', handleHashChange)
  }
}
