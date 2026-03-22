// MASC Dashboard — Root component
// Sticky app shell with tab routing and live status rail

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { route, initRouter } from './router'
import { connectSSE, disconnectSSE } from './sse'
import { refreshRoomTruth } from './room-truth-store'
import { cancelPendingSSERefreshes, registerMissionRefresh, setupSSEReaction, startPeriodicRefresh, stopPeriodicRefresh } from './sse-store'
import { refreshForTab } from './tab-refresh'
import { refreshMissionSnapshot } from './mission-store'
import {
  BuildIdentityBadge,
  ConnectionStatus,
  DashboardMain,
  SideRail,
} from './components/dashboard-shell'
import { KeeperDetailOverlay } from './components/keeper-detail'
import { AgentDetailOverlay } from './components/agent-detail'
import { ToastContainer } from './components/common/toast'
import { DASHBOARD_NAV_ITEMS, currentSectionForRoute } from './config/navigation'

export function App() {
  useEffect(() => {
    // Initialize hash router and compatible deep links
    initRouter()

    // Connect SSE and start data fetching
    connectSSE()

    // room-truth is the single source — it includes shell + execution data.
    // Removed redundant refreshShell(), refreshExecution(), refreshMissionSnapshot()
    // that caused 5 concurrent API calls (server computes same data 3-6x).
    refreshRoomTruth()

    // Register mission refresh for periodic recovery from transient failures.
    // Uses registration pattern to avoid circular imports.
    registerMissionRefresh(() => void refreshMissionSnapshot())

    // Setup SSE -> store reaction (debounced refresh on events)
    const unsubSSE = setupSSEReaction()

    // Periodic refresh for keeper heartbeats (no SSE events)
    startPeriodicRefresh()

    return () => {
      disconnectSSE()
      unsubSSE()
      stopPeriodicRefresh()
    }
  }, [])

  useEffect(() => {
    // Cancel any pending SSE-triggered refreshes from the previous tab
    // to prevent stale fetch results arriving after navigation (C-4/M-12).
    cancelPendingSSERefreshes()
    refreshForTab(route.value.tab)
  }, [route.value.tab, route.value.params.section, route.value.params.surface, route.value.params.q])

  const currentTab = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === currentTab)
  const currentSection = currentSectionForRoute(route.value)

  return html`
    <div class="flex flex-col h-screen overflow-hidden bg-[var(--bg-0)]">
      <!-- Top Bar (GCP-style slim header) -->
      <header class="flex items-center justify-between h-12 px-5 border-b border-[var(--card-border)] bg-[rgba(8,15,29,0.95)] backdrop-blur-md shrink-0 z-50">
        <div class="flex items-center gap-3">
          <h1 class="text-[15px] font-semibold text-[var(--text-strong)] tracking-tight">MASC</h1>
          <span class="text-[12px] text-[var(--text-muted)] hidden sm:inline">${currentSection?.description ?? currentView?.description ?? ''}</span>
          <${BuildIdentityBadge} />
        </div>
        <${ConnectionStatus} />
      </header>

      <!-- Body: Sidebar + Main -->
      <div class="flex flex-1 overflow-hidden">
        <!-- Sidebar (fixed 240px) -->
        <aside class="w-60 shrink-0 border-r border-[var(--card-border)] bg-[rgba(10,18,34,0.6)] overflow-y-auto">
          <${SideRail} />
        </aside>

        <!-- Main Content -->
        <main class="flex-1 overflow-y-auto p-6 min-w-0">
          <div class="max-w-[1400px] mx-auto">
            <${DashboardMain} />
          </div>
        </main>
      </div>

      <${KeeperDetailOverlay} />
      <${AgentDetailOverlay} />
      <${ToastContainer} />
    </div>
  `
}
