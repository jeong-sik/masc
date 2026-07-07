// MASC Dashboard — Entry point
// Mounts the root <App /> component into the DOM

// Foundation and global styles
// Keeper-v2 design-system tokens are loaded earliest so the v2 vocabulary is
// available to the dashboard token ladder; global.css owns the legacy/global
// CSS bundle, and tokens.css follows it so dashboard-specific root variables
// keep override priority over generated/legacy foundations.
import './styles/ds-theme-tokens.css'
import './styles/primitives.css'
import './styles/layout.css'
import './styles/layers.css'
import './styles/kpi.css'
import './styles/rail.css'
import './styles/deck.css'
import './styles/drawer.css'
import './styles/swimlanes.css'
import './styles/code.css'

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
import './styles/tokens.css'
// chat-blocks-v2.css / surfaces-v2.css / cockpit-v2.css load via the *-v2.css
// glob below (see ordering note there) — no per-surface import line here.

// Surface-specific styles not owned by global.css
import './styles/paper-theme.css'

import './styles/keeper-workspace.css'
import './styles/copilot-dock.css'
import './styles/states.css'
// ide-v2.css / work-v2.css / connectors-v2.css / telemetry-v2.css /
// craft-v2.css load via the *-v2.css glob below.

// v2 skin (skin-v2.css) — cool-charcoal palette + voltage accent
// (brass/blood/ice) + Space Grotesk display, for the --color-* surfaces.
// Activated by data-skin="v2" on <html> (index.html), scoped to yield to
// paper/styleseed. Loaded via the *-v2.css glob below.
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

// ── keeper-v2 prototype CSS — the SSOT skin (big-bang v2 reskin) ──
// Vendored verbatim from the design prototype (keeper-v2/styles/*), loaded
// LAST so the prototype's shell/skin classes (.v2-top/.v2-body/.v2-nav/.kp-row
// /.thread/.bubble/.ctx-*/.ov-*) win over any legacy *-v2.css drift on shared
// names. Load order is the prototype's <link> order (notes/css-map.md): tokens
// → v2 (shell+chat) → surfaces → per-surface overrides; craft.css after v2 so
// density rules win. As surfaces migrate to prototype DOM, the legacy CSS above
// is removed (final cleanup PR). Hot-path font loading is local/system only;
// CSS theme files must not add their own external font requests.
import './styles/keeper-v2/colors_and_type.css'
import './styles/keeper-v2/v2.css'
import './styles/keeper-v2/surfaces.css'
import './styles/keeper-v2/dock.css'
import './styles/keeper-v2/craft.css'
import './styles/keeper-v2/inspector.css'
import './styles/keeper-v2/perf.css'
import './styles/keeper-v2/fleet.css'
import './styles/keeper-v2/logs.css'
import './styles/keeper-v2/keeper-config.css'
import './styles/keeper-v2/fusion.css'
import './styles/keeper-v2/memory.css'
import './styles/keeper-v2/schedule.css'
import './styles/keeper-v2/runtime.css'
// Non-prototype: harmonizes the re-mounted operational cluster (.v2-top-ops) to
// the statchip pill shape. Loaded last so it wins on shape (see file header).
import './styles/keeper-v2/ops-cluster.css'
import './styles/keeper-v2/prompt-book.css'

// ── CSS SSOT removal scope (PR #22081 review P1) ──
// `styles/craft-v2.css` (loaded via the *-v2.css glob above) is NOT yet removable:
// it is the sole owner of rules the vendored keeper-v2 CSS does not cover, all keyed
// to LIVE dashboard classes (keeper-v2/craft.css targets design-only .thread/.bubble
// /.roster-list that the live DOM never renders, so it cannot replace these):
//   1. `--twk-font-scale` var + `.v2-app[data-font-scale]` font-size calc (app.ts:275)
//   2. `.v2-app[data-density]` → `.kw-*` workspace density + scrollbar rules
//   3. `.v2-app[data-bubble='flat'] .chat-bubble` (live class; keeper-v2 targets .bubble)
//   4. `.twk-panel` / `.twk-*` tweaks-panel UI
// Removal plan (follow-up): migrate (1)-(4) into keeper-v2/* retargeted to the live
// classes, verify craft-v2.test.ts + app.test.ts green after each step, then delete
// craft-v2.css and drop it from the glob. Until then keeper-v2 loads LAST (wins on
// shared selectors); craft-v2.css supplies only the unique rules above — no
// live-selector conflict, so single-ownership holds per selector today.
import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'
import { performanceMonitor } from './lib/performance-monitor'
import { startWebVitalsCapture } from './utils/performance-metrics'
import { startNavTelemetry } from './lib/nav-telemetry'
import { THEME_STORAGE_KEYS, THEME_SEARCH_PARAM, type ThemeId } from './lib/theme'

function normalizeTheme(raw: string | null): ThemeId {
  const value = raw?.trim().toLowerCase() ?? null
  if (value === 'styleseed' || value === 'light') {
    return 'styleseed'
  }
  if (value === 'paper') {
    return 'paper'
  }
  // Preserve compatibility with existing callers that may send dark-themed values
  // while treating explicit dark values as an opt-out to the legacy palette.
  if (value === 'dark' || value === 'dark-fantasy') {
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
