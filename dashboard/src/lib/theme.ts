/**
 * Single OKLCH theme & static high-contrast state helpers.
 *
 * - Default (dark): "Tempered Slate + Surgical Hearth" (no data-theme attribute)
 * - Light: "Warm Archival Paper" (`data-theme="light"`)
 * - Contrast: static `[data-contrast="high"]` (APCA Lc >= 90, zero runtime culori),
 *   also honors `@media (prefers-contrast: more)` unless explicitly set to `"normal"`.
 */

export const THEME_STORAGE_KEYS = ['masc-theme', 'masc-theme-v2', 'dashboardTheme'] as const
export const CONTRAST_STORAGE_KEY = 'masc-contrast'
export const THEME_SEARCH_PARAM = 'theme'
export const CONTRAST_SEARCH_PARAM = 'contrast'

export type ThemeId = 'dark' | 'light'
export type ContrastId = 'normal' | 'high'

export function normalizeTheme(raw: string | null | undefined): ThemeId {
  const value = raw?.trim().toLowerCase() ?? ''
  if (value === 'light' || value === 'paper' || value === 'styleseed') {
    return 'light'
  }
  return 'dark'
}

export function normalizeContrast(raw: string | null | undefined): ContrastId | null {
  const value = raw?.trim().toLowerCase() ?? ''
  if (value === 'high' || value === 'more') return 'high'
  if (value === 'normal' || value === 'default') return 'normal'
  return null
}

export function applyTheme(theme: ThemeId): void {
  if (typeof document === 'undefined') return
  if (theme === 'light') {
    document.documentElement.dataset.theme = 'light'
  } else {
    delete document.documentElement.dataset.theme
  }
}

export function applyContrast(contrast: ContrastId | null): void {
  if (typeof document === 'undefined') return
  if (contrast === 'high') {
    document.documentElement.dataset.contrast = 'high'
  } else if (contrast === 'normal') {
    document.documentElement.dataset.contrast = 'normal'
  } else {
    delete document.documentElement.dataset.contrast
  }
}

export function persistTheme(theme: ThemeId): void {
  try {
    for (const key of THEME_STORAGE_KEYS) {
      localStorage.setItem(key, theme)
    }
  } catch { /* storage unavailable */ }
}

export function persistContrast(contrast: ContrastId | null): void {
  try {
    if (contrast === null) localStorage.removeItem(CONTRAST_STORAGE_KEY)
    else localStorage.setItem(CONTRAST_STORAGE_KEY, contrast)
  } catch { /* storage unavailable */ }
}

export function resolveInitialTheme(): ThemeId {
  if (typeof window === 'undefined') return 'dark'
  const fromUrl = new URLSearchParams(window.location.search).get(THEME_SEARCH_PARAM)
  if (fromUrl !== null) {
    const normalized = normalizeTheme(fromUrl)
    persistTheme(normalized)
    return normalized
  }
  try {
    for (const key of THEME_STORAGE_KEYS) {
      const stored = localStorage.getItem(key)
      if (stored) return normalizeTheme(stored)
    }
  } catch { /* storage unavailable */ }
  return 'dark'
}

export function resolveInitialContrast(): ContrastId | null {
  if (typeof window === 'undefined') return null
  const fromUrl = new URLSearchParams(window.location.search).get(CONTRAST_SEARCH_PARAM)
  if (fromUrl !== null) {
    const normalized = normalizeContrast(fromUrl)
    persistContrast(normalized)
    return normalized
  }
  try {
    return normalizeContrast(localStorage.getItem(CONTRAST_STORAGE_KEY))
  } catch {
    return null
  }
}
