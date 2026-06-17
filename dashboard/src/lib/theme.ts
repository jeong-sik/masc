/**
 * Shared theme constants used by both the bootstrap entry (main.ts) and
 * the runtime toggle (components/theme-switch.ts).
 *
 * Two storage keys are written/read in tandem so the same persisted
 * choice survives across the `dashboardTheme` → `masc-theme-v2` rename
 * (#8177). Drift between writer and reader sites used to mean a user's
 * paper theme silently disappeared after a refresh — both sites must
 * read from this single source.
 *
 * `applyTheme` / `normalizeTheme` stay file-local on each side because
 * their signatures diverge: main.ts only persists, theme-switch.ts also
 * mirrors a signal and the URL query string.
 */
import { signal } from '@preact/signals'

export const THEME_STORAGE_KEYS = ['dashboardTheme', 'masc-theme-v2'] as const

export const THEME_SEARCH_PARAM = 'theme'

export type ThemeId = 'styleseed' | 'paper' | null

export function readDomTheme(): ThemeId {
  const attr = document.documentElement.dataset.theme
  if (attr === 'styleseed') return 'styleseed'
  if (attr === 'paper') return 'paper'
  return null
}

// Single source of truth for the active dashboard theme.  The default is
// StyleSeed; main.ts seeds the value from URL/localStorage/DOM on boot and
// ThemeSwitch keeps it in sync with the DOM attribute so external changes
// are reflected without mutating state during render.
export const currentTheme = signal<ThemeId>(
  typeof document === 'undefined' ? 'styleseed' : (readDomTheme() ?? 'styleseed'),
)
