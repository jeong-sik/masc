// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import {
  App,
  shouldBootstrapCommandPaletteShortcut,
  shouldShowCopilotFab,
  shouldShowDashboardHealthStrip,
  shouldSuppressFloatingChrome,
  shouldUseCompactDashboardChrome,
} from './app'
import { route } from './router'
import { executionLoaded, keepers, shellCounts, shellRuntimeResolution } from './store'
import { activeKeeperName } from './keeper-state'
import type { Keeper } from './types'

describe('App v2 header chrome', () => {
  let container: HTMLDivElement
  const originalHash = window.location.hash

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    window.location.hash = originalHash
    route.value = { tab: 'overview', params: {}, postId: null }
    keepers.value = []
    executionLoaded.value = false
    shellCounts.value = null
    shellRuntimeResolution.value = null
    activeKeeperName.value = ''
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    window.location.hash = originalHash
    route.value = { tab: 'overview', params: {}, postId: null }
    keepers.value = []
    executionLoaded.value = false
    shellCounts.value = null
    shellRuntimeResolution.value = null
    activeKeeperName.value = ''
  })

  function renderApp() {
    render(h(App, {}), container)
  }

  it('renders v2 app shell wrapper with tweak attributes (v2 dark default, no data-theme)', () => {
    renderApp()
    const app = container.querySelector('.v2-app')
    expect(app).not.toBeNull()
    expect(app?.hasAttribute('data-theme')).toBe(false)
    // density boots at 'spacious' to match the keeper-v2 prototype SSOT
    // (tweaksDensity defaultValue, aligned to the prototype in main 5230b5fa).
    // Users switch to 'regular'/'compact' via the Tweaks panel.
    expect(app?.getAttribute('data-density')).toBe('spacious')
    expect(app?.getAttribute('data-motion')).toBe('subtle')
    expect(app?.getAttribute('data-bubble')).toBe('card')
    expect(app?.hasAttribute('data-surface')).toBe(true)
  })

  it('passes the font-scale percentage to --twk-font-scale without double-dividing (regression #21998)', () => {
    renderApp()
    const app = container.querySelector('.v2-app') as HTMLElement | null
    expect(app).not.toBeNull()
    const dataScale = app?.getAttribute('data-font-scale') ?? ''
    const cssVar = app?.style.getPropertyValue('--twk-font-scale').trim() ?? ''
    // craft-v2.css resolves the scale as `calc(var(--twk-font-scale) * 1%)`, so
    // the CSS variable must carry the same raw percentage integer as
    // data-font-scale. #21998 divided by 100 (data=100 but var=1), collapsing
    // .v2-app font-size to 0.16px and hiding every inherited-size glyph/emoji.
    expect(Number(cssVar)).toBe(Number(dataScale))
    expect(Number(cssVar)).toBeGreaterThan(1)
  })

  it('defaults to the v2 dark skin (no data-theme on the dashboard root)', () => {
    // Theme ownership lives on <html> (bootstrapped by main.ts, toggled by
    // ThemeSwitch). The app root no longer hard-codes a theme, so the default
    // is the keeper-v2 dark skin; paper / styleseed are opt-in light themes.
    renderApp()
    const app = container.querySelector('.v2-app')
    expect(app?.hasAttribute('data-theme')).toBe(false)
  })

  it('keeps primary v2 surfaces on the single 50px top chrome', () => {
    renderApp()
    expect(container.querySelector('.v2-top')).not.toBeNull()
    const health = container.querySelector('[data-testid="dashboard-health-strip"].v2-health-strip') as HTMLElement
    expect(health).not.toBeNull()
    expect(health.style.display).toBe('none')
    expect(shouldShowDashboardHealthStrip('overview')).toBe(false)
    expect(shouldShowDashboardHealthStrip('keepers')).toBe(false)
    expect(shouldShowDashboardHealthStrip('cockpit')).toBe(true)
  })

  it('renders v2 header structural classes', () => {
    renderApp()
    // Brand/mark moved into the nav rail (NavRailV2 `.nav-brand` + `.nav-home`);
    // the keeper-v2 shell renders the MASC mark there, not in the top bar.
    expect(container.querySelector('.nav-brand')).not.toBeNull()
    expect(container.querySelector('.nav-home')).not.toBeNull()
    // The crumb is now `.v2-top .crumb` (TopBarV2), replacing `.v2-header-crumb`.
    expect(container.querySelector('.v2-top .crumb')).not.toBeNull()
    // The global chrome still renders no page title: surface-level headers own the
    // title source of truth, so the shell header carries only the crumb. (Old
    // `.v2-header-title` selector is gone; nothing renders a header title.)
    expect(container.querySelector('.v2-header-title')).toBeNull()
    // The header still carries an action/status cluster: the re-mounted operational
    // chrome lives in `.v2-top-ops` (was `.v2-header-actions` / `.v2-app-header-status`).
    expect(container.querySelector('.v2-top-ops')).not.toBeNull()
    // The shell no longer renders inline header tabs (`.v2-shell-tabs`); navigation
    // is the nav rail / bottom tab bar.
    expect(container.querySelector('.v2-shell-tabs')).toBeNull()
    // The live running-count chip still renders in the top bar.
    expect(container.querySelector('.v2-statchip.live')).not.toBeNull()
  })

  it('renders keeper breadcrumb tail and the live running-count chip', () => {
    window.innerWidth = 1280
    route.value = { tab: 'keepers', params: { keeper: 'albini' }, postId: null }
    // Before runtime health hydrates, the shared runtime-count resolver falls
    // back to the execution rows. Seed 7 running keepers so the chip reads
    // "7 실행 중".
    keepers.value = Array.from({ length: 7 }, (_, i): Keeper => ({
      name: `k${i}`,
      status: 'running',
      lifecycle_phase: 'Running',
    }))
    renderApp()

    // Crumb is now `.v2-top .crumb` (TopBarV2): surface label + keeper tail.
    const crumb = container.querySelector('.v2-top .crumb')
    expect(crumb?.textContent).toContain('Keepers')
    expect(crumb?.textContent).toContain('albini')

    // The live running-count chip is `.v2-statchip.live` in the top bar. The old
    // `.v2-app-header-status` container, the separate server-status "scheduler"
    // chip ("서버"/"응답" text + its title), and the chip-title attributes were
    // removed by the v2 reskin — TopBarV2 emits an attention indicator + 예약
    // button instead. The live-count + pulse coverage is preserved here.
    const liveChip = container.querySelector('.v2-statchip.live') as HTMLElement | null
    expect(liveChip).not.toBeNull()
    expect(liveChip?.textContent).toContain('7 실행 중')
    // Pulse is now carried by the StatusDot pip (`.dot2.pulse`), replacing the old
    // `motion-safe:animate-pulse` utility class on an inner span.
    expect(liveChip?.querySelector('.dot2.pulse')).not.toBeNull()
  })

  it('uses runtime health for the live running-count chip when rows are stale', () => {
    window.innerWidth = 1280
    route.value = { tab: 'keepers', params: { keeper: 'albini' }, postId: null }
    keepers.value = Array.from({ length: 7 }, (_, i): Keeper => ({
      name: `stale-${i}`,
      status: 'running',
      lifecycle_phase: 'Running',
    }))
    shellCounts.value = { agents: 0, tasks: 0, keepers: 7, total_runtimes: 7, configured_keepers: 13 }
    shellRuntimeResolution.value = {
      fleet_safety: {
        keeper_fibers: 7,
        paused_keepers: 3,
        paused_keepers_health: { count: 3 },
        keeper_fleet_no_fibers: false,
        keeper_fd_pressure: null,
        keeper_fleet_safety: {
          running_keeper_fiber_count: 1,
          paused_keeper_count: 3,
        },
        keeper_reaction_ledger: null,
      },
    } as any

    renderApp()

    const liveChip = container.querySelector('.v2-statchip.live') as HTMLElement | null
    expect(liveChip).not.toBeNull()
    expect(liveChip?.textContent).toContain('1 실행 중')
    expect(liveChip?.title).toContain('runtime health')
    expect(liveChip?.title).toContain('paused=3')
    expect(liveChip?.title).toContain('offline=0 (not derived from execution rows)')
    expect(liveChip?.title).toContain('configured=13 (shell)')
  })

  it('falls back to activeKeeperName for the breadcrumb tail when no route keeper param', () => {
    // With no route keeper param the crumb still tracks the keeper the chat is
    // showing. TopBarV2's fallback source is now `activeKeeperName` (the old
    // `selectedKeeper` fallback was removed by the reskin); the fallback intent
    // is unchanged.
    window.innerWidth = 1280
    route.value = { tab: 'keepers', params: {}, postId: null }
    activeKeeperName.value = 'grimja'
    renderApp()

    const crumb = container.querySelector('.v2-top .crumb')
    expect(crumb?.textContent).toContain('Keepers')
    expect(crumb?.textContent).toContain('grimja')
    // No dangling slash when a tail is present.
    expect(crumb?.textContent?.trim().endsWith('/')).toBe(false)
  })

  it('renders the main stage full-bleed (no card frame — matches keeper-v2 prototype)', () => {
    window.innerWidth = 1280
    renderApp()

    const main = container.querySelector('#main-content') as HTMLElement | null
    expect(main).not.toBeNull()
    // The host is `.v2-surface-host` and sits inside the `.v2-body` grid column
    // (the old shell put `v2-body` directly on #main-content; the v2 grid now
    // wraps it).
    expect(main?.classList.contains('v2-surface-host')).toBe(true)
    expect(main?.closest('.v2-body')).not.toBeNull()

    // Edge-to-edge full-bleed: the wrapper card chrome (rounded corners, border,
    // card background, drop shadow) was removed so the shell matches the
    // prototype's full-bleed grid. The page background shows through; each
    // surface owns its own background.
    const cls = main?.className ?? ''
    expect(cls).not.toContain('bg-[var(--ss-card)]')
    expect(cls).not.toContain('rounded-[var(--ss-radius-card)]')
    expect(cls).not.toContain('shadow-[var(--ss-shadow-card)]')
    // The host owns the scrollbar via an inline style (replacing the old
    // overflow-hidden class on the host + overflow-y-auto on the inner scroll).
    expect(main?.style.overflowY).toBe('auto')
  })

  it('renders health chips with the shared chip class on non-primary diagnostics', () => {
    route.value = { tab: 'cockpit', params: {}, postId: null }
    renderApp()
    const chip = container.querySelector('.dashboard-health-chip')
    expect(chip).not.toBeNull()
    expect((container.querySelector('[data-testid="dashboard-health-strip"]') as HTMLElement).style.display).not.toBe('none')
  })

  it('sets data-mobile based on the viewport width', () => {
    window.innerWidth = 900
    renderApp()
    const app = container.querySelector('.v2-app')
    // The v2 shell emits data-mobile="1" (prototype CSS attribute selector),
    // not "true".
    expect(app?.getAttribute('data-mobile')).toBe('1')
  })

  it('does not set data-mobile above the v2 shell breakpoint', () => {
    window.innerWidth = 901
    renderApp()
    const app = container.querySelector('.v2-app')
    // Above the breakpoint the attribute is omitted entirely (was "false").
    expect(app?.hasAttribute('data-mobile')).toBe(false)
  })

  it('renders the always-present mobile bottom tab bar below the breakpoint', () => {
    window.innerWidth = 900
    renderApp()

    // Mobile nav is now NavRailV2's always-present bottom tab bar
    // (`nav.v2-nav.is-mnav`). The old drawer model (a 44x44 hamburger
    // `button[aria-controls="dashboard-side-rail"]` toggling a side-rail
    // drawer + `nav[aria-label="Primary mobile navigation"]`) was removed by
    // the reskin; the prototype keeps a persistent bottom tab bar instead.
    expect(container.querySelector('nav.v2-nav.is-mnav')).not.toBeNull()
  })

  // REMOVED: "hides mobile nav tabs when the mobile side-rail drawer is open" —
  // the mobile side-rail drawer + hamburger toggle were removed by the v2 reskin.
  // The bottom tab bar (`nav.v2-nav.is-mnav`) is always present on mobile, so
  // there is no drawer-open state that hides it. Positive coverage that the
  // bottom bar renders is kept in the test above.

  it('uses the header Copilot control instead of a floating FAB on mobile', () => {
    window.innerWidth = 900
    renderApp()

    expect(container.querySelector('[data-testid="copilot-dock-topbar-button"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="copilot-dock-fab"]')).toBeNull()
  })

  // REMOVED: "keeps mobile nav available on the keeper roster pane" and
  // "hides mobile nav while reading the keeper chat pane" — both asserted the old
  // per-pane mobile-nav gating driven by `#main-content[data-mpane]` +
  // `keeperMobilePane`. The reskin dropped `data-mpane` from #main-content and the
  // `nav[aria-label="Primary mobile navigation"]` element; the mobile bottom tab
  // bar (`nav.v2-nav.is-mnav`) is now always present regardless of keeper pane.
  // Positive bottom-bar coverage is kept above.

  it('renders the left side rail on desktop', () => {
    window.innerWidth = 1280
    renderApp()

    // The desktop rail is now NavRailV2's `nav.v2-nav` (no `#dashboard-side-rail`
    // id, no `.v2-shell-rail`). The mobile-hidden behaviour is no longer a class
    // on the rail: on desktop the rail variant has no `.is-mnav`.
    const rail = container.querySelector('nav.v2-nav')
    expect(rail).not.toBeNull()
    expect(rail?.classList.contains('is-mnav')).toBe(false)
  })

  it('does not collapse the left rail out of view on desktop', () => {
    window.innerWidth = 1280
    renderApp()

    const rail = container.querySelector('nav.v2-nav')
    expect(rail).not.toBeNull()
    // The rail width is no longer a utility class on the rail element; it is the
    // 58px grid column of the `.v2-body` shell grid (icon rail). Assert that the
    // grid reserves a fixed 58px column for the rail (not a collapsed 0 / 1fr-only
    // grid), keeping the "rail stays visible with a real width" intent.
    const body = container.querySelector('.v2-body') as HTMLElement | null
    expect(body).not.toBeNull()
    expect(body?.style.gridTemplateColumns).toContain('58px')
  })

  it('keeps main content scrollable', () => {
    window.innerWidth = 1280
    renderApp()

    const main = container.querySelector('#main-content') as HTMLElement | null
    expect(main).not.toBeNull()
    // The host owns the scrollbar via an inline style (replacing the old
    // `overflow-hidden` class on the host).
    expect(main?.style.overflowY).toBe('auto')

    // The inner scroll wrapper is `.dashboard-main-scroll.h-full`. The reskin
    // moved scroll ownership onto the host inline style, so the inner wrapper no
    // longer carries `overflow-y-auto` — it just fills height (`h-full`).
    const scroll = main?.querySelector('.dashboard-main-scroll')
    expect(scroll).not.toBeNull()
    expect(scroll?.classList.contains('h-full')).toBe(true)
  })

  // REMOVED: "toggles the mobile side-rail drawer" — the v2 reskin removed the
  // mobile side-rail drawer (`#dashboard-side-rail` block/hidden toggling) and its
  // hamburger control (`button[aria-controls="dashboard-side-rail"]`). The mobile
  // bottom tab bar (`nav.v2-nav.is-mnav`) is always present; there is no
  // drawer-open/closed state to toggle. Positive bottom-bar coverage is kept above.

  it('hides floating status and focus chrome on prototype primary surfaces', () => {
    window.innerWidth = 1280
    window.location.hash = '#overview'
    route.value = { tab: 'overview', params: {}, postId: null }
    renderApp()

    expect(container.querySelector('[data-testid="dashboard-status-tray"]')).toBeNull()
    expect(container.querySelector('[data-testid="dashboard-focus-mode-toggle"]')).toBeNull()
  })

  it('keeps floating status and focus chrome on operational surfaces', () => {
    window.innerWidth = 1280
    // `command` is a non-primary operational surface; `monitoring` moved into
    // V2_PRIMARY_SURFACE_IDS (#23578) so it now suppresses floating chrome.
    window.location.hash = '#command/operations'
    route.value = { tab: 'command', params: { section: 'operations' }, postId: null }
    renderApp()

    expect(container.querySelector('[data-testid="dashboard-status-tray"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="dashboard-focus-mode-toggle"]')).not.toBeNull()
  })

  it('focus mode does not permanently hide the rail', async () => {
    window.innerWidth = 1280
    window.location.hash = '#command/operations'
    route.value = { tab: 'command', params: { section: 'operations' }, postId: null }
    renderApp()

    // Rail (now `nav.v2-nav`) should be visible initially.
    expect(container.querySelector('nav.v2-nav')).not.toBeNull()

    const focusButton = container.querySelector('[data-testid="dashboard-focus-mode-toggle"]') as HTMLElement | null
    expect(focusButton).not.toBeNull()
    focusButton!.click()

    // Wait for Preact to re-render after the persistent signal update. Focus mode
    // (compact chrome) omits the rail entirely.
    await waitFor(() => {
      expect(container.querySelector('nav.v2-nav')).toBeNull()
    })
    expect(container.querySelector('[data-testid="dashboard-focus-mode-toggle"]')).not.toBeNull()

    // Toggling back restores the rail.
    focusButton!.click()
    await waitFor(() => {
      expect(container.querySelector('nav.v2-nav')).not.toBeNull()
    })
  })

  it('keeps the command palette chunk out of the initial dashboard render', () => {
    renderApp()

    expect(container.querySelector('ninja-keys')).toBeNull()
  })
})

describe('shouldBootstrapCommandPaletteShortcut', () => {
  it('claims the first Cmd/Ctrl+K only until the palette is mounted', () => {
    expect(shouldBootstrapCommandPaletteShortcut({
      altKey: false,
      ctrlKey: true,
      key: 'k',
      metaKey: false,
    }, false)).toBe(true)
    expect(shouldBootstrapCommandPaletteShortcut({
      altKey: false,
      ctrlKey: true,
      key: 'k',
      metaKey: false,
    }, true)).toBe(false)
    expect(shouldBootstrapCommandPaletteShortcut({
      altKey: true,
      ctrlKey: true,
      key: 'k',
      metaKey: false,
    }, false)).toBe(false)
    expect(shouldBootstrapCommandPaletteShortcut({
      altKey: false,
      ctrlKey: true,
      key: 'j',
      metaKey: false,
    }, false)).toBe(false)
  })
})

describe('shouldSuppressFloatingChrome', () => {
  it('suppresses floating chrome for prototype primary surfaces', () => {
    expect(shouldSuppressFloatingChrome({
      currentTab: 'overview',
      keeperDetailMode: false,
      mobileDrawerOpen: false,
    })).toBe(true)
    expect(shouldSuppressFloatingChrome({
      currentTab: 'connectors',
      keeperDetailMode: false,
      mobileDrawerOpen: false,
    })).toBe(true)
    expect(shouldSuppressFloatingChrome({
      currentTab: 'logs',
      keeperDetailMode: false,
      mobileDrawerOpen: false,
    })).toBe(true)
    // monitoring joined V2_PRIMARY_SURFACE_IDS in #23578 (Monitor in the v2 rail).
    expect(shouldSuppressFloatingChrome({
      currentTab: 'monitoring',
      keeperDetailMode: false,
      mobileDrawerOpen: false,
    })).toBe(true)
  })

  it('keeps floating chrome for operational surfaces unless a shell overlay is active', () => {
    expect(shouldSuppressFloatingChrome({
      currentTab: 'command',
      keeperDetailMode: false,
      mobileDrawerOpen: false,
    })).toBe(false)
    expect(shouldSuppressFloatingChrome({
      currentTab: 'command',
      keeperDetailMode: false,
      mobileDrawerOpen: true,
    })).toBe(true)
  })
})

describe('shouldUseCompactDashboardChrome', () => {
  it('keeps the standard shell for keeper detail routes', () => {
    expect(shouldUseCompactDashboardChrome({
      widgetSoloMode: false,
      focusMode: false,
    })).toBe(false)
  })

  it('uses compact chrome for widget solo routes', () => {
    expect(shouldUseCompactDashboardChrome({
      widgetSoloMode: true,
      focusMode: false,
    })).toBe(true)
  })

  it('uses compact chrome for focus mode', () => {
    expect(shouldUseCompactDashboardChrome({
      widgetSoloMode: false,
      focusMode: true,
    })).toBe(true)
  })
})

describe('shouldShowCopilotFab', () => {
  it('shows the floating Copilot trigger on regular desktop surfaces', () => {
    expect(shouldShowCopilotFab({
      dockOpen: false,
      compactChromeMode: false,
      isMobile: false,
      currentTab: 'overview',
    })).toBe(true)
  })

  it('hides the floating Copilot trigger when another chat surface owns the action', () => {
    expect(shouldShowCopilotFab({
      dockOpen: false,
      compactChromeMode: false,
      isMobile: false,
      currentTab: 'keepers',
    })).toBe(false)
  })

  it('hides the floating Copilot trigger for open, mobile, and compact chrome states', () => {
    expect(shouldShowCopilotFab({
      dockOpen: true,
      compactChromeMode: false,
      isMobile: false,
      currentTab: 'overview',
    })).toBe(false)
    expect(shouldShowCopilotFab({
      dockOpen: false,
      compactChromeMode: false,
      isMobile: true,
      currentTab: 'overview',
    })).toBe(false)
    expect(shouldShowCopilotFab({
      dockOpen: false,
      compactChromeMode: true,
      isMobile: false,
      currentTab: 'overview',
    })).toBe(false)
  })
})
// Keeper Agent v2 sync: coverage ratchet trigger
