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
import { selectedAgentName } from './components/agent-detail-selection'
import { selectedTask } from './components/goals/task-detail-selection'
import { ToastContainer } from './components/common/toast'
import { ConfirmDialogOverlay } from './components/common/confirm-dialog'
import { startErrorCleanup, stopErrorCleanup } from './components/common/error-notification-state'
import { DASHBOARD_NAV_ITEMS, currentSectionForRoute } from './config/navigation'
import { Menu, X } from 'lucide-preact'

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
      class="flex h-[22px] w-[4.5rem] items-center gap-1.5 rounded border border-solid border-[var(--card-border)] bg-[var(--white-4)] px-2"
      aria-hidden="true"
    >
      <span class="size-[7px] rounded-sm bg-[var(--white-15)]"></span>
      <span class="h-2.5 w-9 rounded bg-[var(--white-10)]"></span>
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
  useEffect(() => {
    let cancelled = false
    // Resolved once per mount; runtime changes require a reload.  The
    // server-side fanout guarantees every event that hits /sse also hits
    // the WS external-subscriber path, so turning SSE off is safe when
    // operators have validated the WS channel in their environment.
    const wsOnly = dashboardWsOnlyEnabled()

    // Initialize hash router and compatible deep links
    initRouter()

    // Prime the lightweight shell status first so build/version metadata lands
    // while the project snapshot warms heavier execution/command projections.
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

    // Replay durable OAS state before opening the live SSE tail.
    pauseQueuedOasRuntimeIngress()
    void import('./oas-runtime-store')
      .then(({ replayOasRuntimeTelemetry }) => replayOasRuntimeTelemetry())
      .catch(err => {
        console.warn('[app] OAS runtime replay failed', err instanceof Error ? err.message : err)
      })
      .finally(() => {
        if (cancelled) return
        void ensureDevToken()
          .catch(err => {
            console.warn('[app] dashboard dev-token bootstrap failed', err instanceof Error ? err.message : err)
          })
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

  return html`
    <div class="flex min-h-screen h-screen flex-col overflow-hidden bg-[var(--color-bg-page)] bg-[radial-gradient(ellipse_at_top,rgba(25,40,70,0.3)_0%,rgba(11,18,32,1)_80%)] text-[var(--text-body)]">
      <a href="#main-content" class="sr-only focus:not-sr-only focus:fixed focus:top-4 focus:left-4 focus:z-[100] focus:rounded-md focus:bg-[var(--color-bg-page)] focus:px-4 focus:py-2 focus:text-sm focus:text-[var(--text-strong)] focus:shadow-lg focus:ring-2 focus:ring-[var(--accent-45)]">메인 콘텐츠로 건너뛰기</a>
      <header class="relative z-10 shrink-0 border-b border-[var(--white-5)] bg-[rgba(8,14,26,0.36)] px-4 py-1.5 backdrop-blur-xl">
        <div class="absolute inset-x-0 bottom-0 h-[1px] bg-gradient-to-r from-transparent via-[var(--accent-15)] to-transparent"></div>
        <div class="flex w-full items-center justify-between gap-3 max-[900px]:flex-col max-[900px]:items-stretch">
          <div class="min-w-0 flex items-center gap-3">
            <div class="flex shrink-0 items-center gap-2">
              <button type="button"
                class=${`hidden max-[768px]:flex size-9 items-center justify-center rounded border border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-body)] cursor-pointer transition-colors hover:bg-[rgba(255,255,255,0.1)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
                aria-expanded=${mobileMenuOpen.value}
                aria-label=${mobileMenuOpen.value ? '탐색 메뉴 닫기' : '탐색 메뉴 열기'}
                aria-controls="dashboard-side-rail"
                onClick=${() => { mobileMenuOpen.value = !mobileMenuOpen.value }}
              >
                ${mobileMenuOpen.value ? html`<${X} size=${20} />` : html`<${Menu} size=${20} />`}
              </button>
              <div class="flex size-7 shrink-0 items-center justify-center rounded border border-[var(--white-10)] bg-[var(--white-4)] text-sm text-[var(--text-strong)]">
                ${currentView?.icon ?? 'M'}
              </div>
            </div>

            <div class="min-w-0 flex flex-col justify-center">
              ${currentSection && currentSection.label !== currentView?.label
                ? html`
                    <div class="mb-0.5 flex flex-wrap items-center gap-1.5 text-2xs text-[var(--text-muted)]">
                      <span>${currentView?.label ?? '홈'}</span>
                      <span>/</span>
                    </div>
                  `
                : null}
              <h1 class="min-w-0 text-xl font-semibold tracking-[-0.02em] text-[var(--text-strong)] leading-none [overflow-wrap:anywhere]">
                ${currentSection?.label ?? currentView?.label ?? 'Multi-Agent Namespace Console'}
              </h1>
            </div>
          </div>

          <div class="flex shrink-0 flex-wrap items-center justify-end gap-2">
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

      <${Suspense} fallback=${null}>
        <${LazyRemoteWarningBanner} />
      <//>

      <div class="flex flex-1 gap-2 overflow-hidden p-2 max-[1100px]:flex-col">
        <aside id="dashboard-side-rail" aria-label="사이드바 탐색" class="${sidebarCollapsed.value ? 'w-14' : 'w-55'} shrink-0 overflow-y-auto overflow-x-hidden rounded-xl border border-[var(--white-5)] bg-[rgba(15,22,36,0.6)] backdrop-blur-xl transition-[width] duration-300 ease-[cubic-bezier(0.2,0.8,0.2,1)] max-[1100px]:w-full max-[1100px]:max-h-75 ${mobileMenuOpen.value ? '' : 'max-[768px]:hidden'}">
          <${SideRail} collapsed=${sidebarCollapsed.value} onToggle=${() => { sidebarCollapsed.value = !sidebarCollapsed.value }} />
        </aside>

        <main id="main-content" tabindex=${-1} class="min-w-0 flex-1 overflow-hidden rounded-xl border border-[var(--white-5)] bg-[rgba(10,15,26,0.68)] backdrop-blur-lg max-[1100px]:min-h-0">
          <div class="h-full overflow-y-auto p-4">
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
      <${ToastContainer} />
      <${ConfirmDialogOverlay} />
      <${Suspense} fallback=${null}>
        <${LazyCommandPalette} />
      <//>
    </div>
  `
}
