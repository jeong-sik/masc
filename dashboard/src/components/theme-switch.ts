// ThemeSwitch — compact header toggle for opt-in paper theme (#8177).
//
// Cycles between the default dark palette and the "paper" palette.
// The actual token swap lives in styles/paper-theme.css; this component
// only flips document.documentElement.dataset.theme and persists the
// choice to localStorage so reloads are stable.
//
// The switch is intentionally unobtrusive — a 2-letter mono label in
// the same visual register as BuildIdentityBadge and ConnectionStatus.
// It does not try to preview, animate, or decorate the flip; the
// cascade handles rerender.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { ringFocusClasses } from './common/ring'

type ThemeId = 'paper' | null
const THEME_SEARCH_PARAM = 'theme'
const THEME_STORAGE_KEYS = ['dashboardTheme', 'masc-theme-v2'] as const

function readDomTheme(): ThemeId {
  const attr = document.documentElement.dataset.theme
  return attr === 'paper' ? 'paper' : null
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
  if (next === 'paper') {
    url.searchParams.set(THEME_SEARCH_PARAM, next)
  } else {
    url.searchParams.delete(THEME_SEARCH_PARAM)
  }
  history.replaceState(null, '', url.toString())
}

function toggleTheme(): void {
  applyTheme(currentTheme.value === 'paper' ? null : 'paper')
}

const LABEL: Record<'default' | 'paper', string> = {
  default: 'DARK',
  paper: 'PAPER',
}

const TITLE: Record<'default' | 'paper', string> = {
  default: '현재 테마: Dark · 클릭하여 Paper 테마로 전환',
  paper: '현재 테마: Paper · 클릭하여 Dark 테마로 전환',
}

export function ThemeSwitch() {
  const key = currentTheme.value === 'paper' ? 'paper' : 'default'
  return html`
    <button
      type="button"
      class=${`cursor-pointer rounded-[var(--r-0)] border border-[var(--white-10)] bg-[var(--white-4)] px-2.5 py-[5px] text-3xs font-mono uppercase tracking-4 text-[var(--color-fg-muted)] transition-colors duration-150 hover:border-[var(--accent-20)] hover:text-[var(--color-fg-secondary)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
      aria-label=${TITLE[key]}
      title=${TITLE[key]}
      onClick=${toggleTheme}
    >
      ${LABEL[key]}
    </button>
  `
}
