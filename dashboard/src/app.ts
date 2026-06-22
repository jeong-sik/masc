// MASC Dashboard — Root component
// Sticky app shell with tab routing and live status rail

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { lazy, Suspense } from 'preact/compat'
import { signal } from '@preact/signals'
import { persistentSignal } from './lib/persistent-signal'
import { ringFocusClasses } from './components/common/ring'
import { route, initRouter } from './router'
import {
  pauseQueuedOasRuntimeIngress,
  resumeQueuedOasRuntimeIngress,
} from './sse'
import { requestNamespaceTruthNow, disposeNamespaceTruthScheduler } from './namespace-truth-store'
import { cancelPendingSSERefreshes, registerMissionRefresh, setupSSEReaction, startPeriodicRefresh, stopPeriodicRefresh } from './sse-store'
import { refreshShell, serverStatus, shellCounts } from './store'
import { connectDashboardWS, disconnectDashboardWS, subscribeDashboardRoute } from './dashboard-ws'
import { ensureDevToken } from './api/dev-token'
import { fetchDashboardConfig, parseContextThresholds } from './api/dashboard'
import { CONTEXT_RATIO_CRITICAL, CONTEXT_RATIO_WARN, CONTEXT_RATIO_COMPACTING } from './config/constants'
import { setContextThresholds } from './config/context-thresholds'
import {
  BuildIdentityBadge,
  ConnectionStatus,
  DashboardHealthStrip,
  DashboardMain,
  ErrorCounterBadge,
  isKeeperDetailDashboardRoute,
} from './components/dashboard-shell'
import { ThemeSwitch } from './components/theme-switch'
import { EmergencyStopControl } from './components/emergency-stop-control'
import { AttentionIndicator } from './components/attention-indicator'
import { TransportBeacon } from './components/transport-beacon'
import { DashboardNavRail } from './components/mobile-nav'
import { SkipLink } from './components/skip-link'
import { selectedAgentName } from './components/agent-detail-selection'
import { selectedKeeper } from './components/keeper-detail-state'
import { selectedTask } from './components/goals/task-detail-selection'
import { ToastContainer } from './components/common/toast'
import { ConfirmDialogOverlay } from './components/common/confirm-dialog'
import { BundleStalenessBanner, installBundleStalenessWatch } from './components/bundle-staleness-banner'
import { startErrorCleanup, stopErrorCleanup } from './components/common/error-notification-state'
import { DashboardStatusTray } from './components/status-tray'
import { DashboardFocusModeToggle, dashboardFocusMode } from './components/focus-mode-toggle'
import {
  DASHBOARD_NAV_ITEMS,
  currentSectionForRoute,
  isPrimaryDashboardSurface,
} from './config/navigation'
import type { TabId } from './types'
import { Menu, X } from 'lucide-preact'
import { useKeyboardShortcutHost } from '../design-system/headless-preact/use-keyboard-shortcut'
import { globalShortcutManager } from './lib/global-shortcut-manager'
import { useKeeperPinShortcuts } from './components/ide/use-keeper-pin-shortcuts'
import { useIsMobile } from './hooks/use-is-mobile'
import { isWidgetSoloRoute } from './components/widget-solo'
import {
  CopilotDock,
  CopilotDockFab,
  CopilotDockTopBarButton,
  useCopilotDock,
  useCopilotDockShortcuts,
} from './components/copilot-dock'
import { keeperMobilePane } from './components/keeper-mobile-pane-state'
import {
  TweaksPanel,
  TweaksPanelToggle,
  tweaksDensity,
  tweaksFontScale,
  tweaksMotion,
  tweaksBubble,
  tweaksTheme,
  tweaksVolt,
  tweaksThreadW,
} from './components/tweaks-panel'

// Sidebar collapsed state persists across reloads — a user who picks
// the dense layout keeps it. Namespaced key avoids clashing with any
// future per-user preference that might use plain \"sidebar-collapsed\".
// Default = collapsed: a fresh load shows the keeper-v2 prototype's
// icon-only 58px rail. Returning users keep their stored choice (the
// persistent signal only falls back to this default when no value is set).
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
const LazyAuthStatus = lazy(async () => ({
  default: (await import('./components/auth-status')).AuthStatus,
}))
const LazyRemoteWarningBanner = lazy(async () => ({
  default: (await import('./components/auth-status')).RemoteWarningBanner,
}))

function authStatusFallback() {
  return html`
    <span
      class="flex h-[22px] w-[4.5rem] items-center gap-1.5 rounded-[var(--r-1)] border border-solid border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2"
      aria-hidden="true"
    >
      <span class="size-[7px] rounded-[var(--r-0)] bg-[var(--color-fg-disabled)]"></span>
      <span class="h-2.5 w-9 rounded-[var(--r-1)] bg-[var(--color-fg-disabled)]"></span>
    </span>
  `
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
  // RFC-0012 §3.2: bind a single document-level keydown listener once at
  // the app root. Registry starts empty; per RFC §8 each ad-hoc keydown
  // owner (command palette, modal Escape, IDE multi-keeper pin promote /
  // unpin) migrates onto `globalShortcutManager` in its own PR. The
  // manager's `dispatch` returns `false` on no-match so the host does not
  // `preventDefault`, leaving existing element-scoped listeners working.
  useKeyboardShortcutHost(globalShortcutManager)

  // RFC-0027 PR-γ-2: 5 multi-keeper-pin shortcuts (Mod+Shift+1..4
  // promote, Mod+Shift+W unpin head). First consumer of the global
  // shortcut manager (RFC-0012 §8 consumer-migration pattern). Chord
  // namespace deliberately distinct from RFC-0012 §4 default IDE set
  // (Mod+1..9 reserved for tab switching, Mod+W for tab close).
  useKeeperPinShortcuts(globalShortcutManager)

  useEffect(() => {
    let cancelled = false
    // WS/WSS is the sole dashboard transport. The server fans every
    // broadcast to the WS external-subscriber path, and reconnect re-syncs
    // via the hello/subscribe snapshot, so the SSE fallback path was
    // removed (it carried a separate event-id space and caused stale-delta
    // churn at the WS<->SSE boundary).

    // Initialize hash router and compatible deep links
    initRouter()

    const ensureLoopbackAuth = () => ensureDevToken()
      .catch(err => {
        console.warn('[app] dashboard dev-token bootstrap failed', err instanceof Error ? err.message : err)
      })

    // Loopback dashboards can self-provision a dev bearer token. Do that before
    // the first authenticated projections so the header auth badge and runtime
    // stores do not briefly settle on an unauthenticated shell snapshot.
    void ensureLoopbackAuth()
      .finally(() => {
        if (cancelled) return
        void refreshShell({ light: true })
        requestNamespaceTruthNow()

        // Fetch runtime thresholds so health-strip and lifecycle state use
        // server-side config instead of compiled fallback defaults (P-DASH-07).
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
      })

    // Replay durable OAS state before opening the live SSE tail.
    pauseQueuedOasRuntimeIngress()
    void import('./oas-runtime-store')
      .then(({ replayOasRuntimeTelemetry }) => replayOasRuntimeTelemetry())
      .catch(err => {
        console.warn('[app] OAS runtime replay failed', err instanceof Error ? err.message : err)
      })
      .finally(() => {
        if (cancelled) return
        void ensureLoopbackAuth()
          .finally(() => {
            if (cancelled) return
            void connectDashboardWS(route.value)
            resumeQueuedOasRuntimeIngress()
          })
      })

    // Register mission refresh for periodic recovery from transient failures.
    // Uses registration pattern to avoid circular imports.
    registerMissionRefresh(() => {
      void import('./mission-actions')
        .then(({ refreshMissionSnapshot }) => refreshMissionSnapshot())
        .catch(err => {
          console.warn('[app] mission refresh unavailable', err instanceof Error ? err.message : err)
        })
    })

    // Setup SSE -> store reaction (debounced refresh on events)
    const unsubSSE = setupSSEReaction()

    // Periodic refresh for keeper heartbeats (no SSE events)
    startPeriodicRefresh()

    // Error notification cleanup (removes old acknowledged errors)
    startErrorCleanup()

    // Detect a newer served bundle when the tab is picked up again
    const uninstallStalenessWatch = installBundleStalenessWatch()

    return () => {
      cancelled = true
      disconnectDashboardWS()
      unsubSSE()
      stopPeriodicRefresh()
      stopErrorCleanup()
      disposeNamespaceTruthScheduler()
      uninstallStalenessWatch()
    }
  }, [])

  useEffect(() => {
    // Cancel any pending SSE-triggered refreshes from the previous tab
    // to prevent stale fetch results arriving after navigation (C-4/M-12).
    cancelPendingSSERefreshes()
    // Swallow + log subscribe rejections (timeout / closed socket) here so
    // they do not surface as Uncaught (in promise) noise in DevTools.  The
    // ws layer owns reconnect on failure (see dashboard-ws.ts onopen path).
    subscribeDashboardRoute(route.value).catch(err => {
      console.warn('[dashboard] subscribeDashboardRoute failed', err)
    })
    refreshCurrentRoute({ recordVisit: true })
  }, [route.value.tab, route.value.params.section, route.value.params.view, route.value.params.q])

  const dock = useCopilotDock()
  useCopilotDockShortcuts(dock)

  const isMobile = useIsMobile()

  const currentTab = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === currentTab)
  const currentSection = currentSectionForRoute(route.value)
  // Keepers surface is sectionless (navigation `keepers: []`), so its breadcrumb
  // tail is the keeper the chat is showing. Prefer the explicit route param,
  // then fall back to the `selectedKeeper` signal (mirrors keeper-detail-page's
  // tier-2 resolution) so the crumb still tracks the keeper when no route param
  // is present. Reading `selectedKeeper.value` subscribes App to a single
  // low-frequency signal — NOT the high-frequency keepers list (P0 perf).
  // Mirrors the v2 design crumb `<surface> / <keeper.id>`.
  const breadcrumbKeeper = currentTab === 'keepers'
    ? (route.value.params.keeper?.trim() || selectedKeeper.value?.name || undefined)
    : undefined
  const isCodeSurface = currentTab === 'code'
  const widgetSoloMode = isWidgetSoloRoute(route.value)
  const keeperDetailMode = isKeeperDetailDashboardRoute(route.value)
  const mobileKeeperPane = isMobile && keeperDetailMode ? keeperMobilePane.value : null
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

  // sync volt and theme to document root
  useEffect(() => {
    document.documentElement.setAttribute('data-volt', tweaksVolt.value)
    document.documentElement.setAttribute('data-theme', tweaksTheme.value === 'paper' ? 'paper' : '')
  }, [tweaksVolt.value, tweaksTheme.value])

  return html`
    <div
      class="v2-app flex min-h-screen h-screen flex-col overflow-hidden bg-[var(--color-bg-page)] text-[var(--color-fg-primary)]"
      data-widget-solo=${widgetSoloMode ? 'true' : 'false'}
      data-focus-mode=${focusMode ? 'true' : 'false'}
      data-keeper-detail-mode=${keeperDetailMode ? 'true' : 'false'}
      data-mobile=${isMobile ? 'true' : 'false'}
      data-density=${tweaksDensity.value}
      data-motion=${tweaksMotion.value}
      data-bubble=${tweaksBubble.value}
      data-font-scale=${tweaksFontScale.value}
      data-theme=${tweaksTheme.value === 'paper' ? 'paper' : null}
      data-volt=${tweaksVolt.value}
      data-surface=${currentTab}
      style=${{
        '--twk-font-scale': String(tweaksFontScale.value / 100),
        '--thread-w': `${tweaksThreadW.value}px`,
      }}
    >
      <${SkipLink} />
      <header class="${compactChromeMode ? 'hidden' : 'relative v2-shell-header'} z-10 shrink-0 px-4 py-2">
        <div class="absolute inset-x-0 bottom-0 h-[1px] bg-gradient-to-r from-transparent via-[var(--accent-15)] to-transparent"></div>
        <div class="flex w-full items-center justify-between gap-3 max-[1080px]:flex-col max-[1080px]:items-stretch">
          <div class="flex min-w-0 flex-1 items-center gap-3 max-[860px]:flex-wrap">
            <div class="flex min-w-0 shrink-0 items-center gap-2.5 max-[520px]:w-full">
              <button type="button"
                class=${`${isMobile ? 'flex' : 'hidden'} size-11 items-center justify-center rounded-md border border-[var(--ss-border)] bg-[var(--ss-card)] text-[var(--ss-text-primary)] cursor-pointer transition-colors hover:bg-[var(--ss-surface-subtle)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
                aria-expanded=${mobileMenuOpen.value}
                aria-label=${mobileMenuOpen.value ? 'Close navigation' : 'Open navigation'}
                aria-controls="dashboard-side-rail"
                onClick=${() => { mobileMenuOpen.value = !mobileMenuOpen.value }}
              >
                ${mobileMenuOpen.value ? html`<${X} size=${20} />` : html`<${Menu} size=${20} />`}
              </button>
              <div class="v2-header-brand flex min-w-0 items-stretch overflow-hidden rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]">
                <div class="v2-header-mark flex w-12 shrink-0 flex-col items-center justify-center border-r border-[var(--color-border-default)] bg-[var(--accent-10)] px-2 py-1 font-display text-2xs font-semibold uppercase leading-none tracking-[0.12em] text-[var(--color-accent-fg)]">
                  MASC
                </div>
                <div class="min-w-0 px-2.5 py-1">
                  <div class="v2-header-crumb flex items-center gap-1.5 font-ui text-[var(--fs-10)] uppercase leading-none tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
                    <span>${currentView?.label ?? 'Surface'}</span>
                    ${breadcrumbKeeper
                      ? html`
                          <span class="text-[var(--color-warn)]">/</span>
                          <span class="truncate">${breadcrumbKeeper}</span>
                        `
                      : currentSection && currentSection.label !== currentView?.label
                      ? html`
                          <span class="text-[var(--color-warn)]">/</span>
                          <span class="truncate">${currentSection.label}</span>
                        `
                      : null}
                  </div>
                  ${/* No title heading here: each surface owns its primary header
                       (single source of truth), so the global chrome shows only the
                       crumb — matching the v2 design top bar, which carries a slim
                       breadcrumb and no page title. A title here duplicated every
                       surface-level heading/header. */ ''}
                </div>
              </div>
            </div>

          </div>

          <div class="v2-header-actions flex shrink-0 flex-wrap items-center justify-end gap-2 max-[1080px]:justify-between">
            <div class="v2-app-header-status v2-desktop-header-only flex items-center gap-2" aria-label="대시보드 요약">
              <span class="v2-statchip live" title="실행 중인 keeper 수 (shell 스냅샷 기준)">
                <span class="inline-block size-2 rounded-full bg-[var(--color-status-ok)] shadow-[0_0_7px_rgb(var(--ok-glow)/0.75)] motion-safe:animate-pulse"></span>
                ${shellCounts.value?.keepers ?? 0} 실행 중
              </span>
              <span class="v2-statchip" title="dashboard shell이 최근 서버 status를 수신했는지 여부">
                서버 <b>${serverStatus.value ? '응답' : '—'}</b>
              </span>
            </div>
            <${AttentionIndicator} />
            <span class="contents" data-mobile-detail-keep><${EmergencyStopControl} /></span>
            <${CopilotDockTopBarButton} dock=${dock} />
            <${Suspense} fallback=${authStatusFallback()}>
              <${LazyAuthStatus} />
            <//>
            <${ConnectionStatus} />
            <${ErrorCounterBadge} />
            <div class="v2-desktop-header-only"><${TransportBeacon} /></div>
            <div class="v2-desktop-header-only"><${ThemeSwitch} /></div>
            <div class="v2-desktop-header-only"><${TweaksPanelToggle} /></div>
            <div class="v2-desktop-header-only"><${BuildIdentityBadge} /></div>
          </div>
        </div>
      </header>

      ${widgetSoloMode
        ? html`
          <div
            class="flex shrink-0 flex-wrap items-center justify-end gap-2 border-b border-[var(--ss-border)] bg-[var(--ss-card)] px-3 py-1.5"
            data-testid="dashboard-widget-solo-auth-strip"
            aria-label="Solo view auth and runtime status"
          >
            <${Suspense} fallback=${authStatusFallback()}>
              <${LazyAuthStatus} />
            <//>
            <${ConnectionStatus} />
            <${ErrorCounterBadge} />
          </div>
        `
        : null}
      ${focusMode || keeperDetailMode ? null : html`
        <${Suspense} fallback=${null}>
          <${LazyRemoteWarningBanner} />
        <//>
        <${DashboardHealthStrip} />
      `}

      <div class=${compactChromeMode ? 'v2-shell-stage flex flex-1 overflow-hidden p-0' : 'v2-shell-stage flex flex-1 gap-2 overflow-hidden p-2 max-[1100px]:flex-col'}>
        ${compactChromeMode
          ? null
          : html`
            <${DashboardNavRail}
              currentTab=${currentTab}
              mobile=${isMobile}
              drawerOpen=${mobileMenuOpen.value}
              hideMobileTabs=${mobileKeeperPane === 'chat'}
              collapsed=${sidebarCollapsed.value}
              onToggleCollapsed=${() => { sidebarCollapsed.value = !sidebarCollapsed.value }}
              onToggleDrawer=${() => { mobileMenuOpen.value = !mobileMenuOpen.value }}
              onCloseDrawer=${() => { mobileMenuOpen.value = false }}
            />
          `}

        <div class="v2-stage min-h-0 flex-1">
          <main
            id="main-content"
            tabindex=${-1}
            data-mpane=${mobileKeeperPane ?? undefined}
            class=${compactChromeMode ? 'v2-body min-w-0 flex-1 overflow-hidden' : 'v2-body min-w-0 flex-1 overflow-hidden rounded-[var(--ss-radius-card)] border border-[var(--ss-border)] bg-[var(--ss-card)] shadow-[var(--ss-shadow-card)]'}
          >
            <div class=${isCodeSurface || widgetSoloMode ? 'h-full overflow-hidden p-0' : keeperDetailMode ? 'h-full p-0' : focusMode ? 'dashboard-main-scroll h-full overflow-y-auto p-3 max-[520px]:p-2 max-[900px]:pb-16' : 'dashboard-main-scroll h-full overflow-y-auto p-4 max-[900px]:pb-16'}>
              <div class="v2-surface" key=${currentTab}>
                <${DashboardMain} />
              </div>
            </div>
          </main>
          ${dock.state.value.open ? html`<${CopilotDock} dock=${dock} />` : null}
        </div>
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
      <${Suspense} fallback=${null}>
        <${LazyCommandPalette} />
      <//>
    </div>
  `
}

// Re-export the keeper-v2 v8 config panel + state surfaces from the app root
// so downstream consumers have a single import surface.
export { KeeperConfigPanel } from './components/keeper-config-panel-v2'
export { EmptyState, ErrorState, LoadingState } from './components/state-surfaces'
