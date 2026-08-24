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

/**
 * The opt-in themes, as values a CSS selector can match.
 *
 * Default/dark token sources load after these, so each one guards itself with
 * a `:not([data-theme=...])` for every opt-in theme. Adding a theme means
 * adding that exclusion everywhere; missing one silently reintroduces the
 * override for that theme, and the assertions were literal selector strings,
 * so a missed CSS site was a missed test site too (#21860).
 *
 * The list is here so a test can check every guard against it rather than
 * against a string somebody remembered to update.
 */
export const OPT_IN_THEMES = ['paper', 'styleseed'] as const

export type OptInTheme = (typeof OPT_IN_THEMES)[number]

/** The `:not(...)` chain a default-token selector needs to yield to every
 *  opt-in theme, in the order the stylesheets write it. */
export const themeExclusionSuffix = (): string =>
  OPT_IN_THEMES.map((theme) => `:not([data-theme="${theme}"])`).join('')
