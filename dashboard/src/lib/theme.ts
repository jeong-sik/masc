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
export const THEME_STORAGE_KEYS = ['dashboardTheme', 'masc-theme-v2'] as const

export const THEME_SEARCH_PARAM = 'theme'

export type ThemeId = 'styleseed' | 'paper' | null
