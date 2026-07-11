// MASC Dashboard — Root component (v2 skin shell)
//
// The chrome (top bar, nav rail, body grid) is the keeper-v2 prototype DOM
// (`.v2-app` → `.v2-top` → `.v2-stage` → `.v2-body`), styled by the vendored
// keeper-v2 CSS SSOT (src/styles/keeper-v2/*). The body still mounts the
// existing `DashboardMain` surface dispatcher, so every surface keeps
// rendering while it is migrated to the prototype DOM in stacked follow-ups.
//
// All lifecycle wiring (router, WS, SSE reaction, periodic refresh, dev-token,
// config thresholds, cleanup, volt/theme sync) is preserved verbatim from the
// previous shell — only the rendered DOM changed.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { lazy, Suspense } from 'preact/compat'
import { signal } from '@preact/signals'
import { persistentSignal } from './lib/persistent-signal'
import { route, initRouter } from './router'
import { requestNamespaceTruthNow, disposeNamespaceTruthScheduler } from './namespace-truth-store'
import { cancelPendingSSERefreshes, registerGovernanceRefresh, registerMissionRefresh, setupSSEReaction, startPeriodicRefresh, stopPeriodicRefresh } from './sse-store'
import { initNotificationDelivery } from './notifications'
import { refreshShell } from './store'
import { connectDashboardWS, disconnectDashboardWS, subscribeDashboardRoute } from './dashboard-ws'
import { ensureDevToken } from './api/dev-token'
import { fetchDashboardConfig, parseContextThresholds } from './api/dashboard-logs'
import { CONTEXT_RATIO_CRITICAL, CONTEXT_RATIO_WARN, CONTEXT_RATIO_COMPACTING } from './config/constants'
import { setContextThresholds } from './config/context-thresholds'
import { DashboardMain, DashboardHealthStrip, isKeeperDetailDashboardRoute } from './components/dashboard-shell'
import { RemoteWarningBanner } from './components/auth-status'
import { SkipLink } from './components/skip-link'
import { selectedAgentName } from './components/agent-detail-selection'
import { selectedTask } from './components/goals/task-detail-selection'
import { ToastContainer } from './components/common/toast'
import { ConfirmDialogOverlay } from './components/common/confirm-dialog'
import { commandPaletteRequested, requestCommandPaletteOpen } from './components/common/command-palette-state'
import { BundleStalenessBanner, installBundleStalenessWatch } from './components/bundle-staleness-banner'
import { startErrorCleanup, stopErrorCleanup } from './components/common/error-notification-state'
import { DashboardStatusTray } from './components/status-tray'
import { DashboardFocusModeToggle, dashboardFocusMode } from './components/focus-mode-toggle'
import { isPrimaryDashboardSurface } from './config/navigation'
import { navBadges, markBoardMentionsSeenNow } from './nav-badges'
import type { TabId } from './types'
import { useKeyboardShortcutHost } from '../design-system/headless-preact/use-keyboard-shortcut'
import { globalShortcutManager } from './lib/global-shortcut-manager'
import { useKeeperPinShortcuts } from './components/ide/use-keeper-pin-shortcuts'
import { useIsMobile } from './hooks/use-is-mobile'
import { isWidgetSoloRoute } from './components/widget-solo'
import { keeperMobilePane } from './components/keeper-detail-state'
import {
  CopilotDock,
  CopilotDockFab,
  useCopilotDock,
  useCopilotDockShortcuts,
} from './components/copilot-dock'
import {
  TweaksPanel,
  tweaksDensity,
  tweaksFontScale,
  tweaksMotion,
  tweaksBubble,
  tweaksTheme,
  tweaksVolt,
  tweaksThreadW,
} from './components/tweaks-panel'
import { TopBarV2 } from './components/v2/top-bar-v2'
import { NavRailV2 } from './components/v2/nav-rail-v2'
import { loadTools, toolsData, toolsLoading } from './components/tools/tool-state'

// Sidebar collapsed state persists across reloads (kept for compatibility with
// downstream consumers / tests). The v2 rail is a fixed 58px icon rail, so this
// no longer toggles width, but the signal is retained so the contract holds.
const sidebarCollapsed = persistentSignal<boolean>({
  key: 'dashboard:sidebar-collapsed',
  defaultValue: true,
})
const mobileMenuOpen = signal(false)

export function shouldSuppressFloatingChrome({
  currentTab,
  keeperDetailMode,
  mobileDrawerOpen,
}: {
  currentTab: TabId
  keeperDetailMode: boolean
  mobileDrawerOpen: boolean
}): boolean {
  return keeperDetailMode || mobileDrawerOpen || isPrimaryDashboardSurface(currentTab)
}

const LazyAgentDetailOverlay = lazy(async () => ({
  default: (await import('./components/agent-detail')).AgentDetailOverlay,
}))
const LazyTaskDetailOverlay = lazy(async () => ({
  default: (await import('./components/goals/task-detail-overlay')).TaskDetailOverlay,
}))
const LazyCommandPalette = lazy(async () => ({
  default: (await import('./components/common/command-palette')).CommandPalette,
}))

export function shouldBootstrapCommandPaletteShortcut(
  event: Pick<KeyboardEvent, 'altKey' | 'ctrlKey' | 'key' | 'metaKey'>,
  mounted: boolean,
): boolean {
  return !mounted
    && !event.altKey
    && (event.ctrlKey || event.metaKey)
    && event.key.toLowerCase() === 'k'
}

function refreshCurrentRoute(options?: { recordVisit?: boolean }): void {
  const routeState = route.value
  void import('./tab-refresh')
    .then(({ refreshForRoute }) => {
      refreshForRoute(routeState, options)
    })
    .catch(err => {
      console.warn('[app] route refresh unavailable', err instanceof Error ? err.message : err)
    })
}

export function shouldUseCompactDashboardChrome({
  widgetSoloMode,
  focusMode,
}: {
  widgetSoloMode: boolean
  focusMode: boolean
}): boolean {
  return widgetSoloMode || focusMode
}

export function shouldShowCopilotFab({
  dockOpen,
  compactChromeMode,
  isMobile,
  currentTab,
}: {
  dockOpen: boolean
  compactChromeMode: boolean
  isMobile: boolean
  currentTab: TabId
}): boolean {
  return !dockOpen && !compactChromeMode && !isMobile && currentTab !== 'keepers'
}

export function App() {
  // RFC-0012 §3.2: single document-level keydown host bound once at the root.
  useKeyboardShortcutHost(globalShortcutManager)
  // Multi-keeper pin shortcuts share the root keyboard host.
  useKeeperPinShortcuts(globalShortcutManager)

  useEffect(() => {
    let cancelled = false

    // Initialize hash router and compatible deep links
    initRouter()

    const ensureLoopbackAuth = () => ensureDevToken()
      .catch(err => {
        console.warn('[app] dashboard dev-token bootstrap failed', err instanceof Error ? err.message : err)
      })

    void ensureLoopbackAuth()
      .finally(() => {
        if (cancelled) return
        void refreshShell({ light: true })
        requestNamespaceTruthNow()

        void fetchDashboardConfig()
          .then(data => {
            const thresholds = parseContextThresholds(data, {
              critical: CONTEXT_RATIO_CRITICAL,
              warn: CONTEXT_RATIO_WARN,
              compacting: CONTEXT_RATIO_COMPACTING,
            })
            setContextThresholds(thresholds)
          })
          .catch(err => {
            console.warn('[app] dashboard config fetch failed', err instanceof Error ? err.message : err)
          })

        void connectDashboardWS(route.value)
      })

    registerMissionRefresh(() => {
      void import('./mission-actions')
        .then(({ refreshMissionSnapshot }) => refreshMissionSnapshot())
        .catch(err => {
          console.warn('[app] mission refresh unavailable', err instanceof Error ? err.message : err)
        })
    })

    // Governance/HITL approvals feed the always-visible nav-rail approvals
    // badge and topbar attention indicator (nav-badges.ts navBadges), so the
    // governance resource must refresh globally. Keep boot on the read-only
    // refresh module instead of governance-actions: first paint should not load
    // toast/action write handlers just to count pending approvals.
    const refreshGovernanceLazy = (opts?: { force?: boolean }) => {
      void import('./components/governance-refresh')
        .then(({ refreshGovernance }) => refreshGovernance(opts))
        .catch(err => {
          console.warn('[app] governance refresh unavailable', err instanceof Error ? err.message : err)
        })
    }
    registerGovernanceRefresh(refreshGovernanceLazy)
    refreshGovernanceLazy()

    // The scheduled-automation projection backs the always-visible nav-rail
    // schedule badge + topbar chip (schedule.jsx: chip/badge stay in sync). Like
    // the governance approvals badge, the count must be available before the
    // operator visits the schedule surface, so load the projection once at boot.
    if (!toolsData.value && !toolsLoading.value) {
      void loadTools()
    }

    const unsubSSE = setupSSEReaction()
    const unsubNotify = initNotificationDelivery()
    startPeriodicRefresh()
    startErrorCleanup()
    const uninstallStalenessWatch = installBundleStalenessWatch()

    return () => {
      cancelled = true
      disconnectDashboardWS()
      unsubSSE()
      unsubNotify()
      stopPeriodicRefresh()
      stopErrorCleanup()
      disposeNamespaceTruthScheduler()
      uninstallStalenessWatch()
    }
  }, [])

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!shouldBootstrapCommandPaletteShortcut(event, commandPaletteRequested.value)) return
      event.preventDefault()
      requestCommandPaletteOpen()
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [])

  useEffect(() => {
    cancelPendingSSERefreshes()
    subscribeDashboardRoute(route.value).catch(err => {
      console.warn('[dashboard] subscribeDashboardRoute failed', err)
    })
    refreshCurrentRoute({ recordVisit: true })
    // Board-mentions nav-rail badge: mark currently-known for-me mentions as
    // seen when the operator visits the board surface (mirrors the
    // per-keeper advanceKeeperLastSeen "mark read on visit" pattern).
    if (route.value.tab === 'board') markBoardMentionsSeenNow()
  }, [route.value.tab, route.value.params.section, route.value.params.view, route.value.params.q])

  const dock = useCopilotDock()
  useCopilotDockShortcuts(dock)

  const isMobile = useIsMobile()

  const currentTab = route.value.tab
  const isCodeSurface = currentTab === 'code'
  const isScheduleSurface = currentTab === 'schedule'
  const widgetSoloMode = isWidgetSoloRoute(route.value)
  const keeperDetailMode = isKeeperDetailDashboardRoute(route.value)
  const mobileKeeperPane = isMobile && keeperDetailMode ? keeperMobilePane.value : null
  const mobileKeeperReadingMode = mobileKeeperPane === 'chat'
  const focusMode = dashboardFocusMode.value
  const mobileDrawerOpen = isMobile && mobileMenuOpen.value
  const suppressFloatingChrome = shouldSuppressFloatingChrome({
    currentTab,
    keeperDetailMode,
    mobileDrawerOpen,
  })
  const compactChromeMode = shouldUseCompactDashboardChrome({
    widgetSoloMode,
    focusMode,
  })

  // sync volt and theme to document root (skin-v2 voltage + paper theme)
  useEffect(() => {
    document.documentElement.setAttribute('data-volt', tweaksVolt.value)
    document.documentElement.setAttribute('data-theme', tweaksTheme.value === 'paper' ? 'paper' : '')
  }, [tweaksVolt.value, tweaksTheme.value])

  // Body grid columns. Desktop: nav rail (58px) + single content column. Mobile:
  // a single 1fr column — the nav becomes a fixed bottom tab bar (.v2-nav.is-mnav),
  // out of grid flow. (The keepers 4-column roster|chat|ctx grid is provided by
  // the keeper-workspace layout, not here.)
  const cols = isMobile ? '1fr' : '58px minmax(0,1fr)'

  return html`
    <div
      class="v2-app"
      data-surface=${currentTab}
      data-density=${tweaksDensity.value}
      data-motion=${tweaksMotion.value}
      data-bubble=${tweaksBubble.value}
      data-mobile=${isMobile ? '1' : null}
      data-font-scale=${tweaksFontScale.value}
      data-theme=${tweaksTheme.value === 'paper' ? 'paper' : null}
      data-volt=${tweaksVolt.value}
      data-focus-mode=${focusMode ? 'true' : 'false'}
      data-keeper-detail-mode=${keeperDetailMode ? 'true' : 'false'}
      data-reading=${mobileKeeperReadingMode ? 'true' : 'false'}
      data-widget-solo=${widgetSoloMode ? 'true' : 'false'}
      style=${{
        // tweaksFontScale.value is a percentage integer (80..140, default 100).
        // craft-v2.css resolves it as `calc(var(--twk-font-scale) * 1%)`, so the
        // raw percentage must be passed through. Dividing by 100 here (regressed
        // in #21998) double-applies the percentage: 100 -> `1 * 1%` -> 0.16px,
        // collapsing every inherited-font-size glyph (emoji, icon chars) to ~0px.
        '--twk-font-scale': String(tweaksFontScale.value),
        '--kw-thread-w': `${tweaksThreadW.value}px`,
        '--thread-w': `${tweaksThreadW.value}px`,
      }}
    >
      <${SkipLink} />
      ${compactChromeMode ? null : html`<${TopBarV2} dock=${dock} />`}
      ${/* Operational/safety strips re-mounted under the v2 top bar (review P1):
          remote-auth warning + the runtime health chip bar. Both self-gate
          (render null when there is no warning / no health signal). */ ''}
      ${compactChromeMode ? null : html`<${RemoteWarningBanner} />`}
      ${compactChromeMode ? null : html`<${DashboardHealthStrip} />`}

      <div class="v2-stage">
        <div class="v2-body" style=${{ gridTemplateColumns: cols }}>
          ${compactChromeMode ? null : html`<${NavRailV2} badges=${navBadges.value} mobile=${isMobile} />`}
          <main
            id="main-content"
            tabindex=${-1}
            class="v2-surface-host"
            style=${{ minWidth: 0, minHeight: 0, overflowY: isCodeSurface || isScheduleSurface ? 'hidden' : 'auto' }}
          >
            <div class=${isCodeSurface || isScheduleSurface || widgetSoloMode ? 'h-full overflow-hidden p-0' : keeperDetailMode ? 'h-full p-0' : 'dashboard-main-scroll h-full p-4 max-[900px]:pb-16'}>
              <div class="v2-surface" key=${currentTab}>
                <${DashboardMain} />
              </div>
            </div>
          </main>
        </div>
        ${dock.state.value.open ? html`<${CopilotDock} dock=${dock} />` : null}
      </div>

      ${shouldShowCopilotFab({
        dockOpen: dock.state.value.open,
        compactChromeMode,
        isMobile,
        currentTab,
      }) ? html`<${CopilotDockFab} dock=${dock} />` : null}

      ${selectedAgentName.value
        ? html`<${Suspense} fallback=${null}><${LazyAgentDetailOverlay} /><//>`
        : null}
      ${selectedTask.value
        ? html`<${Suspense} fallback=${null}><${LazyTaskDetailOverlay} /><//>`
        : null}
      ${suppressFloatingChrome ? null : html`
        <${DashboardStatusTray} sideRailCollapsed=${sidebarCollapsed.value} />
        <${DashboardFocusModeToggle} />
      `}
      <${ToastContainer} />
      <${ConfirmDialogOverlay} />
      <${BundleStalenessBanner} />
      <${TweaksPanel} />
      ${commandPaletteRequested.value
        ? html`
          <${Suspense} fallback=${null}>
            <${LazyCommandPalette} openOnMount=${true} />
          <//>
        `
        : null}
    </div>
  `
}

// Re-export state surfaces from the app root so downstream consumers have a
// single import surface.
export { EmptyState, ErrorState, LoadingState } from './components/state-surfaces'
