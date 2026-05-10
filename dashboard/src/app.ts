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
  connectSSE,
  disconnectSSE,
  pauseQueuedOasRuntimeIngress,
  resumeQueuedOasRuntimeIngress,
} from './sse'
import { requestNamespaceTruthNow, disposeNamespaceTruthScheduler } from './namespace-truth-store'
import { cancelPendingSSERefreshes, registerMissionRefresh, setupSSEReaction, startPeriodicRefresh, stopPeriodicRefresh } from './sse-store'
import { refreshShell } from './store'
import { connectDashboardWS, disconnectDashboardWS, subscribeDashboardRoute } from './dashboard-ws'
import { dashboardWsOnlyEnabled } from './dashboard-ws-cutover'
import { ensureDevToken } from './api/dev-token'
import { fetchDashboardConfig, parseContextThresholds } from './api/dashboard'
import { CONTEXT_RATIO_CRITICAL, CONTEXT_RATIO_WARN, CONTEXT_RATIO_COMPACTING } from './config/constants'
import { setContextThresholds } from './config/context-thresholds'
import {
  BuildIdentityBadge,
  ConnectionStatus,
  DashboardMain,
  ErrorCounterBadge,
  SideRail,
} from './components/dashboard-shell'
import { ThemeSwitch } from './components/theme-switch'
import { TransportBeacon } from './components/transport-beacon'
import { DashboardSurfaceTabs } from './components/dashboard-surface-tabs'
import { SkipLink } from './components/skip-link'
import { selectedAgentName } from './components/agent-detail-selection'
import { selectedTask } from './components/goals/task-detail-selection'
import { ToastContainer } from './components/common/toast'
import { ConfirmDialogOverlay } from './components/common/confirm-dialog'
import { startErrorCleanup, stopErrorCleanup } from './components/common/error-notification-state'
import { DashboardStatusTray } from './components/status-tray'
import { DashboardFocusModeToggle, dashboardFocusMode } from './components/focus-mode-toggle'
import { DASHBOARD_NAV_ITEMS, currentSectionForRoute } from './config/navigation'
import { Menu, X } from 'lucide-preact'
import { useKeyboardShortcutHost } from '../design-system/headless-preact/use-keyboard-shortcut'
import { globalShortcutManager } from './lib/global-shortcut-manager'
import { useKeeperPinShortcuts } from './components/ide/use-keeper-pin-shortcuts'
import { isWidgetSoloRoute } from './components/widget-solo'

// Sidebar collapsed state persists across reloads — a user who picks
// the dense layout keeps it. Namespaced key avoids clashing with any
// future per-user preference that might use plain \"sidebar-collapsed\".
const sidebarCollapsed = persistentSignal<boolean>({
  key: 'dashboard:sidebar-collapsed',
  defaultValue: false,
})
const mobileMenuOpen = signal(false)
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
    // Resolved once per mount; runtime changes require a reload.  The
    // server-side fanout guarantees every event that hits /sse also hits
    // the WS external-subscriber path, so turning SSE off is safe when
    // operators have validated the WS channel in their environment.
    const wsOnly = dashboardWsOnlyEnabled()

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
      })

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
            // In cutover mode the WS channel is trusted to carry every
            // broadcast (it is already registered as an Sse external
            // subscriber on the server).  Opening the /sse EventSource in
            // parallel only duplicates delivery; skip it.
            if (!wsOnly) {
              connectSSE()
            }
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

    return () => {
      cancelled = true
      disconnectDashboardWS()
      if (!wsOnly) {
        disconnectSSE()
      }
      unsubSSE()
      stopPeriodicRefresh()
      stopErrorCleanup()
      disposeNamespaceTruthScheduler()
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

  const currentTab = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === currentTab)
  const currentSection = currentSectionForRoute(route.value)
  const isCodeSurface = currentTab === 'code'
  const widgetSoloMode = isWidgetSoloRoute(route.value)
  const focusMode = dashboardFocusMode.value
  const compactChromeMode = widgetSoloMode || focusMode

  return html`
    <div
      class="flex min-h-screen h-screen flex-col overflow-hidden bg-[var(--color-bg-page)] text-[var(--color-fg-primary)]"
      data-widget-solo=${widgetSoloMode ? 'true' : 'false'}
      data-focus-mode=${focusMode ? 'true' : 'false'}
    >
      <${SkipLink} />
      <header class="${compactChromeMode ? 'hidden' : 'relative'} z-10 shrink-0 border-b border-[var(--color-border-default)] bg-[var(--shell-header-bg)] px-3 py-1.5 backdrop-blur-xl">
        <div class="absolute inset-x-0 bottom-0 h-[1px] bg-gradient-to-r from-transparent via-[var(--accent-15)] to-transparent"></div>
        <div class="flex w-full items-center justify-between gap-3 max-[1080px]:flex-col max-[1080px]:items-stretch">
          <div class="flex min-w-0 flex-1 items-center gap-3 max-[860px]:flex-wrap">
            <div class="flex min-w-0 shrink-0 items-center gap-2.5 max-[520px]:w-full">
              <button type="button"
                class=${`hidden max-[768px]:flex size-8 items-center justify-center rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-primary)] cursor-pointer transition-colors hover:bg-[var(--color-bg-hover)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
                aria-expanded=${mobileMenuOpen.value}
                aria-label=${mobileMenuOpen.value ? 'Close navigation' : 'Open navigation'}
                aria-controls="dashboard-side-rail"
                onClick=${() => { mobileMenuOpen.value = !mobileMenuOpen.value }}
              >
                ${mobileMenuOpen.value ? html`<${X} size=${20} />` : html`<${Menu} size=${20} />`}
              </button>
              <div class="flex min-w-0 items-stretch overflow-hidden rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]">
                <div class="flex w-12 shrink-0 flex-col items-center justify-center border-r border-[var(--color-border-default)] bg-[var(--accent-10)] px-2 py-1 font-mono text-3xs font-semibold uppercase leading-none tracking-[var(--track-caps)] text-[var(--color-accent-fg)]">
                  MASC
                </div>
                <div class="min-w-0 px-2.5 py-1">
                  <div class="flex items-center gap-1.5 font-mono text-[var(--fs-9)] uppercase leading-none tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
                    <span>${currentView?.label ?? 'Surface'}</span>
                    ${currentSection && currentSection.label !== currentView?.label
                      ? html`
                          <span class="text-[var(--color-warn)]">/</span>
                          <span class="truncate">${currentSection.label}</span>
                        `
                      : null}
                  </div>
                  <h1 class="mt-1 min-w-0 truncate text-xs font-semibold leading-tight tracking-normal text-[var(--color-fg-secondary)]">
                    ${currentSection?.label ?? currentView?.label ?? 'Multi-Agent Namespace Console'}
                  </h1>
                </div>
              </div>
            </div>

            <${DashboardSurfaceTabs} items=${DASHBOARD_NAV_ITEMS} currentTab=${currentTab} />
          </div>

          <div class="flex shrink-0 flex-wrap items-center justify-end gap-2 max-[1080px]:justify-between">
            <${Suspense} fallback=${authStatusFallback()}>
              <${LazyAuthStatus} />
            <//>
            <${ConnectionStatus} />
            <${TransportBeacon} />
            <${ErrorCounterBadge} />
            <${ThemeSwitch} />
            <${BuildIdentityBadge} />
          </div>
        </div>
      </header>

      ${widgetSoloMode
        ? html`
          <div
            class="flex shrink-0 flex-wrap items-center justify-end gap-2 border-b border-[var(--color-border-default)] bg-[var(--shell-header-bg)] px-3 py-1.5"
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
      ${focusMode ? null : html`
        <${Suspense} fallback=${null}>
          <${LazyRemoteWarningBanner} />
        <//>
      `}

      <div class=${compactChromeMode ? 'flex flex-1 overflow-hidden p-0' : 'flex flex-1 gap-2 overflow-hidden p-2 max-[1100px]:flex-col'}>
        ${compactChromeMode
          ? null
          : html`
            <aside id="dashboard-side-rail" aria-label="Sidebar navigation" class="${sidebarCollapsed.value ? 'w-14' : 'w-55'} shrink-0 overflow-hidden rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--shell-rail-bg)] backdrop-blur-xl transition-[width] duration-[var(--t-slow)] ease-[var(--ease)] max-[1100px]:w-full max-[1100px]:max-h-75 ${mobileMenuOpen.value ? '' : 'max-[768px]:hidden'}">
              <${SideRail} collapsed=${sidebarCollapsed.value} onToggle=${() => { sidebarCollapsed.value = !sidebarCollapsed.value }} />
            </aside>
          `}

        <main id="main-content" tabindex=${-1} class=${compactChromeMode ? 'min-w-0 flex-1 overflow-hidden bg-[var(--shell-main-bg)] backdrop-blur-lg' : 'min-w-0 flex-1 overflow-hidden rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--shell-main-bg)] backdrop-blur-lg max-[1100px]:min-h-0'}>
          <div class=${isCodeSurface || widgetSoloMode ? 'h-full overflow-hidden p-0' : focusMode ? 'h-full overflow-y-auto p-3 max-[520px]:p-2' : 'h-full overflow-y-auto p-4'}>
            <${DashboardMain} />
          </div>
        </main>
      </div>

      ${selectedAgentName.value
        ? html`<${Suspense} fallback=${null}><${LazyAgentDetailOverlay} /><//>`
        : null}
      ${selectedTask.value
        ? html`<${Suspense} fallback=${null}><${LazyTaskDetailOverlay} /><//>`
        : null}
      <${DashboardStatusTray} sideRailCollapsed=${sidebarCollapsed.value} />
      <${DashboardFocusModeToggle} />
      <${ToastContainer} />
      <${ConfirmDialogOverlay} />
      <${Suspense} fallback=${null}>
        <${LazyCommandPalette} />
      <//>
    </div>
  `
}
