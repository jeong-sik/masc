// MASC Dashboard — Entry point
// Mounts the root <App /> component into the DOM

// Foundation styles (load first)
import './styles/tokens.generated.css'
import './styles/tokens.css'
import './styles/variables.css'
import './styles/primitives.css'
import './styles/layout.css'
import './styles/layers.css'
import './styles/kpi.css'
import './styles/lifeline.css'
import './styles/ticker.css'
import './styles/sidebar.css'
import './styles/rail.css'
import './styles/deck.css'
import './styles/drawer.css'
import './styles/swimlanes.css'
import './styles/code.css'
import './styles/center.css'
import './styles/base.css'
import './styles/keyframes.css'

// Global utilities and layout
import './styles/global.css'

// Component-specific styles
import './styles/ui.css'
import './styles/board.css'
/* chat.css: styles merged into global.css @utility blocks (#3915) */
import './styles/dashboard.css'
import './styles/governance.css'
import './styles/governance-agent.css'
import './styles/ops.css'
import './styles/tools.css'
import './styles/paper-theme.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'
import { performanceMonitor } from './lib/performance-monitor'
import { startWebVitalsCapture } from './utils/performance-metrics'

const THEME_STORAGE_KEYS = ['dashboardTheme', 'masc-theme-v2'] as const
const THEME_SEARCH_PARAM = 'theme'

type ThemeId = 'paper' | null

function normalizeTheme(raw: string | null): ThemeId {
  if (raw === 'paper' || raw === 'light') {
    return 'paper'
  }
  // Preserve compatibility with existing callers that may send dark-themed values
  // while keeping the default dashboard branch at the non-paper
  // baseline (`dark-fantasy` in the generated token stack).
  if (raw === 'dark' || raw === 'dark-fantasy' || raw === null || raw === '') {
    return null
  }
  return null
}

function persistTheme(theme: ThemeId): void {
  try {
    if (theme === 'paper') {
      THEME_STORAGE_KEYS.forEach((key) => localStorage.setItem(key, theme))
    } else {
      THEME_STORAGE_KEYS.forEach((key) => localStorage.removeItem(key))
    }
  } catch { /* quota / privacy */ }
}

function resolveTheme(): ThemeId {
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
  } catch { /* access denied */ }
  return null
}

function applyTheme(theme: ThemeId): void {
  if (theme === 'paper') {
    document.documentElement.dataset.theme = 'paper'
  } else {
    delete document.documentElement.dataset.theme
  }
}

const theme = resolveTheme()
applyTheme(theme)

const root = document.getElementById('app')
if (root) {
  render(html`<${App} />`, root)
}

// Begin collecting long-animation-frame telemetry.
// No-op on browsers that do not support LoAF.
performanceMonitor.start()

// Begin capturing synthetic web-vitals (TTFB, FCP, LCP, CLS, FID).
// Snapshot available on window.__MASC_WEB_VITALS__ for test/playwright inspection.
startWebVitalsCapture()
