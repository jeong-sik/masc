// MASC Dashboard — Entry point
// Mounts the root <App /> component into the DOM

// Foundation styles (load first)
// Keeper-v2 design-system tokens are loaded earliest so the v2 vocabulary is
// available to the dashboard token ladder; dashboard-specific tokens loaded
// below override any name collisions.
import './styles/ds-theme-tokens.css'
import './styles/tokens.generated.css'
import './styles/tokens.css'
import './styles/variables.css'
import './styles/primitives.css'
import './styles/layout.css'
import './styles/layers.css'
import './styles/kpi.css'
import './styles/rail.css'
import './styles/deck.css'
import './styles/drawer.css'
import './styles/swimlanes.css'
import './styles/code.css'
import './styles/base.css'
import './styles/keyframes.css'

/*
 * EXPERIMENTAL: StyleSeed light theme — opt-in via data-theme='styleseed' on html
 * These files define a self-contained StyleSeed-inspired token layer. Rules are
 * scoped to [data-theme="styleseed"] so they have no effect on the default
 * dark-fantasy / v2 surfaces unless the attribute is explicitly set.
 */
import './styles/styleseed-theme.css'
import './styles/styleseed-base.css'

// Global utilities and layout
import './styles/global.css'
import './styles/chat.css'
import './styles/chat-blocks-v2.css'
import './styles/surfaces-v2.css'
import './styles/cockpit-v2.css'

// Component-specific styles
import './styles/ui.css'
import './styles/board.css'
import './styles/dashboard.css'
import './styles/governance.css'
import './styles/governance-agent.css'
import './styles/ops.css'
import './styles/tools.css'
import './styles/paper-theme.css'

import './styles/keeper-workspace.css'
import './styles/copilot-dock.css'
import './styles/keeper-turn-inspector.css'
import './styles/ide-v2.css'
import './styles/work-v2.css'
import './styles/design-canvas.css'
import './styles/states.css'
import './styles/connectors-v2.css'
import './styles/telemetry-v2.css'
import './styles/craft-v2.css'

// v2 skin — cool-charcoal palette + voltage accent (brass/blood/ice) +
// Space Grotesk display, for the --color-* surfaces. Activated by
// data-skin="v2" on <html> (index.html), scoped to yield to paper/styleseed.
import './styles/skin-v2.css'
// StyleSeed → keeper-v2 Dark Fantasy bridge. Re-points the StyleSeed token
// VALUES (--ss-* / --background / --card / --brand, defined LIGHT by
// app-shell-v2.css) at the Dark Fantasy spine, so the migrated surfaces render
// dark under the default theme while StyleSeed's readable sizing is kept.
import './styles/ss-keeper-v2-bridge.css'

/*
 * EXPERIMENTAL: keeper-v2 DS UI kits — may conflict with existing v2-* styles; enable after review
 * import './styles/ds-ui-kits.css'
 */

// Keeper-v2 surface stylesheets are auto-imported by filename convention:
// every dashboard/src/styles/*-v2.css is injected here at build time. A new v2
// surface adds only its own stylesheet file — it must NOT add a per-surface
// import line to main.ts. Per-surface import edits all landed in this one block
// and serialized into repeated merge conflicts across parallel surface PRs;
// the glob removes that shared anchor. Ordering note: all *-v2.css load at this
// point (after variables.css and dashboard.css), preserving the cases where a
// v2 rule overrides its v1 counterpart (.gd-board, .mg-board, .ide-plane-shell).
import.meta.glob('./styles/*-v2.css', { eager: true })

import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'
import { performanceMonitor } from './lib/performance-monitor'
import { startWebVitalsCapture } from './utils/performance-metrics'
import { startNavTelemetry } from './lib/nav-telemetry'
import { THEME_STORAGE_KEYS, THEME_SEARCH_PARAM, type ThemeId } from './lib/theme'

function normalizeTheme(raw: string | null): ThemeId {
  if (raw === 'styleseed' || raw === 'light') {
    return 'styleseed'
  }
  if (raw === 'paper') {
    return 'paper'
  }
  // Preserve compatibility with existing callers that may send dark-themed values
  // while treating explicit dark values as an opt-out to the legacy palette.
  if (raw === 'dark' || raw === 'dark-fantasy') {
    return null
  }
  return null
}

function persistTheme(theme: ThemeId): void {
  try {
    if (theme === 'styleseed' || theme === 'paper') {
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
  // Default: keeper-v2 Dark Fantasy (null = no data-theme). StyleSeed / paper
  // are opt-in via ThemeSwitch or ?theme= and persist in localStorage.
  return null
}

function applyTheme(theme: ThemeId): void {
  if (theme === 'styleseed') {
    document.documentElement.dataset.theme = 'styleseed'
  } else if (theme === 'paper') {
    document.documentElement.dataset.theme = 'paper'
  } else {
    delete document.documentElement.dataset.theme
  }
}

const theme = resolveTheme()
applyTheme(theme)

// Ensure the v2 voltage accent attribute is present so skin-v2.css voltage
// variants (brass/blood/ice) resolve. The source default is brass; an explicit
// attribute in index.html wins and is preserved.
if (!document.documentElement.dataset.volt) {
  document.documentElement.dataset.volt = 'brass'
}

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

// RFC-0049 — surface/section open counters to /api/v1/dashboard/nav-event.
// Aggregate only, no PII. Drives RFC-0048 IA decisions.
startNavTelemetry()
