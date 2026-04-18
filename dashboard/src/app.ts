// MASC Dashboard — Root component
// Sticky app shell with tab routing and live status rail

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { persistentSignal } from './lib/persistent-signal'
import { route, initRouter } from './router'
import {
  connectSSE,
  disconnectSSE,
  pauseQueuedOasRuntimeIngress,
  resumeQueuedOasRuntimeIngress,
} from './sse'
import { requestNamespaceTruthNow, disposeNamespaceTruthScheduler } from './namespace-truth-store'
import { cancelPendingSSERefreshes, registerMissionRefresh, setupSSEReaction, startPeriodicRefresh, stopPeriodicRefresh } from './sse-store'
import { refreshForRoute } from './tab-refresh'
import { refreshMissionSnapshot } from './mission-store'
import { replayOasRuntimeTelemetry } from './oas-runtime-store'
import { refreshShell } from './store'
import {
  BuildIdentityBadge,
  ConnectionStatus,
  DashboardMain,
  SideRail,
} from './components/dashboard-shell'
import { ThemeSwitch } from './components/theme-switch'
import { KeeperDetailOverlay } from './components/keeper-detail'
import { AgentDetailOverlay } from './components/agent-detail'
import { TaskDetailOverlay } from './components/goals/task-detail-overlay'
import { ToastContainer } from './components/common/toast'
import { ConfirmDialogOverlay } from './components/common/confirm-dialog'
import { CommandPalette } from './components/common/command-palette'
import { AuthStatus, RemoteWarningBanner } from './components/auth-status'
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

export function App() {
  useEffect(() => {
    let cancelled = false

    // Initialize hash router and compatible deep links
    initRouter()

    // Prime the lightweight shell status first so build/version metadata lands
    // while namespace-truth warms heavier execution/command projections.
    void refreshShell()
    requestNamespaceTruthNow()

    // Replay durable OAS state before opening the live SSE tail.
    pauseQueuedOasRuntimeIngress()
    void replayOasRuntimeTelemetry()
      .catch(err => {
        console.warn('[app] OAS runtime replay failed', err instanceof Error ? err.message : err)
      })
      .finally(() => {
        if (cancelled) return
        connectSSE()
        resumeQueuedOasRuntimeIngress()
      })

    // Register mission refresh for periodic recovery from transient failures.
    // Uses registration pattern to avoid circular imports.
    registerMissionRefresh(() => void refreshMissionSnapshot())

    // Setup SSE -> store reaction (debounced refresh on events)
    const unsubSSE = setupSSEReaction()

    // Periodic refresh for keeper heartbeats (no SSE events)
    startPeriodicRefresh()

    return () => {
      cancelled = true
      disconnectSSE()
      unsubSSE()
      stopPeriodicRefresh()
      disposeNamespaceTruthScheduler()
    }
  }, [])

  useEffect(() => {
    // Cancel any pending SSE-triggered refreshes from the previous tab
    // to prevent stale fetch results arriving after navigation (C-4/M-12).
    cancelPendingSSERefreshes()
    refreshForRoute(route.value, { recordVisit: true })
  }, [route.value.tab, route.value.params.section, route.value.params.q])

  const currentTab = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === currentTab)
  const currentSection = currentSectionForRoute(route.value)
  const activeSurfaceLabel = currentSection && currentSection.label !== currentView?.label
    ? `${currentView?.label ?? '홈'} / ${currentSection.label}`
    : (currentSection?.label ?? currentView?.label ?? '홈')

  return html`
    <div class="dashboard-shell-app flex min-h-screen h-screen flex-col overflow-hidden text-[var(--text-body)]">
      <header class="dashboard-topbar relative z-10 shrink-0 px-4 py-2">
        <div class="flex w-full items-center justify-between gap-3 max-[900px]:flex-col max-[900px]:items-stretch">
          <div class="min-w-0 flex items-center gap-3">
            <div class="flex shrink-0 items-center gap-2.5">
              <button type="button"
                class="dashboard-chip dashboard-chip--control hidden max-[768px]:flex size-9 items-center justify-center p-0 cursor-pointer text-[var(--text-body)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-0)]"
                aria-expanded=${mobileMenuOpen.value}
                aria-label=${mobileMenuOpen.value ? '탐색 메뉴 닫기' : '탐색 메뉴 열기'}
                aria-controls="dashboard-side-rail"
                onClick=${() => { mobileMenuOpen.value = !mobileMenuOpen.value }}
              >
                ${mobileMenuOpen.value ? html`<${X} size=${20} />` : html`<${Menu} size=${20} />`}
              </button>
              <div class="dashboard-surface-code shrink-0">
                ${currentView?.icon ?? 'M'}
              </div>
            </div>

            <div class="min-w-0 flex flex-col justify-center">
              <div class="dashboard-topbar__eyebrow">Multi-Agent Namespace Console</div>
              <h1 class="dashboard-topbar__title min-w-0 [overflow-wrap:anywhere]">
                MASC Control Deck
              </h1>
              <div class="dashboard-topbar__summary">${activeSurfaceLabel}</div>
            </div>
          </div>

          <div class="flex shrink-0 flex-wrap items-center justify-end gap-2.5">
            <${AuthStatus} />
            <${ConnectionStatus} />
            <${ThemeSwitch} />
            <${BuildIdentityBadge} />
          </div>
        </div>
      </header>

      <${RemoteWarningBanner} />

      <div class="dashboard-shell-grid flex flex-1 gap-3 overflow-hidden p-3 max-[1100px]:flex-col">
        <aside id="dashboard-side-rail" class="dashboard-rail ${sidebarCollapsed.value ? 'w-14' : 'w-[248px]'} shrink-0 overflow-y-auto overflow-x-hidden transition-[width] duration-300 ease-[cubic-bezier(0.2,0.8,0.2,1)] max-[1100px]:w-full max-[1100px]:max-h-[320px] ${mobileMenuOpen.value ? '' : 'max-[768px]:hidden'}">
          <${SideRail} collapsed=${sidebarCollapsed.value} onToggle=${() => { sidebarCollapsed.value = !sidebarCollapsed.value }} />
        </aside>

        <main class="dashboard-main-panel min-w-0 flex-1 overflow-hidden max-[1100px]:min-h-0">
          <div class="h-full overflow-y-auto p-4">
            <${DashboardMain} />
          </div>
        </main>
      </div>

      <${KeeperDetailOverlay} />
      <${AgentDetailOverlay} />
      <${TaskDetailOverlay} />
      <${ToastContainer} />
      <${ConfirmDialogOverlay} />
      <${CommandPalette} />
    </div>
  `
}
