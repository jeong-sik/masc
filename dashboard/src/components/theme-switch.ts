// ThemeSwitch — compact header theme toggle.
//
// Cycles between the default dark palette, StyleSeed, and Paper.
// The actual token swaps live in styles/styleseed-theme.css and
// styles/paper-theme.css; this component only flips
// document.documentElement.dataset.theme and persists the choice to
// localStorage so reloads are stable.
//
// The switch is intentionally unobtrusive — a 2-letter mono label in
// the same visual register as BuildIdentityBadge and ConnectionStatus.
// It does not try to preview, animate, or decorate the flip; the
// runtime handles rerender.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { ringFocusClasses } from './common/ring'
import { THEME_STORAGE_KEYS, THEME_SEARCH_PARAM, type ThemeId } from '../lib/theme'

function readDomTheme(): ThemeId {
  const attr = document.documentElement.dataset.theme
  if (attr === 'styleseed') return 'styleseed'
  if (attr === 'paper') return 'paper'
  return null
}

// Single source of truth: mirrors the DOM attribute so Preact renders
// the button label in sync with however main.ts initialised the theme.
const currentTheme = signal<ThemeId>(
  typeof document === 'undefined' ? null : readDomTheme(),
)

function applyTheme(next: ThemeId): void {
  if (next === null) {
    delete document.documentElement.dataset.theme
    try {
      THEME_STORAGE_KEYS.forEach((key) => {
        localStorage.removeItem(key)
      })
    } catch { /* quota / privacy */ }
  } else {
    document.documentElement.dataset.theme = next
    try {
      THEME_STORAGE_KEYS.forEach((key) => {
        localStorage.setItem(key, next)
      })
    } catch { /* quota / privacy */ }
  }
  syncThemeSearchParam(next)
  currentTheme.value = next
}

function syncThemeSearchParam(next: ThemeId): void {
  const url = new URL(window.location.href)
  if (next === 'styleseed' || next === 'paper') {
    url.searchParams.set(THEME_SEARCH_PARAM, next)
  } else {
    url.searchParams.delete(THEME_SEARCH_PARAM)
  }
  history.replaceState(null, '', url.toString())
}

function nextTheme(current: ThemeId): ThemeId {
  if (current === null) return 'styleseed'
  if (current === 'styleseed') return 'paper'
  return null
}

function toggleTheme(): void {
  applyTheme(nextTheme(currentTheme.value))
}

const LABEL: Record<'default' | 'styleseed' | 'paper', string> = {
  default: 'DARK',
  styleseed: 'SEED',
  paper: 'PAPER',
}

const TITLE: Record<'default' | 'styleseed' | 'paper', string> = {
  default: '현재 테마: Dark · 클릭하여 StyleSeed 테마로 전환',
  styleseed: '현재 테마: StyleSeed · 클릭하여 Paper 테마로 전환',
  paper: '현재 테마: Paper · 클릭하여 Dark 테마로 전환',
}

export function ThemeSwitch() {
  // Re-sync with the DOM on every render so external bootstrapping (main.ts)
  // and tests that set dataset.theme after module load see the correct label.
  const domTheme = readDomTheme()
  if (currentTheme.value !== domTheme) {
    currentTheme.value = domTheme
  }

  const key = currentTheme.value === 'styleseed' ? 'styleseed' : currentTheme.value === 'paper' ? 'paper' : 'default'
  return html`
    <button
      type="button"
      class=${`v2-shell-action cursor-pointer rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2.5 py-[5px] text-3xs font-mono uppercase tracking-4 text-[var(--color-fg-muted)] transition-colors duration-[var(--t-med)] hover:border-[var(--accent-20)] hover:text-[var(--color-fg-secondary)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
      aria-label=${TITLE[key]}
      title=${TITLE[key]}
      onClick=${toggleTheme}
    >
      ${LABEL[key]}
    </button>
  `
}
