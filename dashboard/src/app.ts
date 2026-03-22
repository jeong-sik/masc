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
    <div class="flex flex-col h-screen overflow-hidden bg-bg-0 text-text-body font-sans">
      <!-- Top Bar (Modern frosted glass header) -->
      <header class="flex items-center justify-between h-14 px-6 border-b border-card-border bg-bg-0/80 backdrop-blur-xl shrink-0 z-50 shadow-sm shadow-black/10">
        <div class="flex items-center gap-4">
          <div class="flex items-center gap-2">
            <div class="size-6 rounded-md bg-gradient-to-br from-accent to-blue-600 shadow-inner flex items-center justify-center">
              <span class="text-[10px] font-bold text-white tracking-tighter">M</span>
            </div>
            <h1 class="text-base font-semibold text-text-strong tracking-wide">MASC</h1>
          </div>
          <div class="w-[1px] h-4 bg-card-border mx-1"></div>
          <span class="text-[13px] font-medium text-text-muted hidden sm:inline">${currentSection?.description ?? currentView?.description ?? ''}</span>
          <div class="ml-2">
            <${BuildIdentityBadge} />
          </div>
        </div>
        <${ConnectionStatus} />
      </header>

      <!-- Body: Sidebar + Main -->
      <div class="flex flex-1 overflow-hidden relative">
        <!-- Sidebar (fixed 260px) -->
        <aside class="w-[260px] shrink-0 border-r border-card-border bg-bg-1/40 overflow-y-auto flex flex-col">
          <${SideRail} />
        </aside>

        <!-- Main Content -->
        <main class="flex-1 overflow-y-auto p-8 min-w-0 bg-gradient-to-b from-transparent to-bg-0/50">
          <div class="max-w-[1400px] mx-auto pb-12">
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
