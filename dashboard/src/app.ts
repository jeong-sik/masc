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
    registerMissionRefresh(() => void refreshMissionSnapshot('snapshot'))

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
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC 운영 콘솔
            <${BuildIdentityBadge} />
          </h1>
          <p class="header-subtitle">${currentSection?.description ?? currentView?.description ?? '운영 판단과 제어를 위한 콘솔'}</p>
        </div>
        <div class="header-right">
          <${ConnectionStatus} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${SideRail} />
        <main class="dashboard-main">
          <${DashboardMain} />
        </main>
      </div>

      <${KeeperDetailOverlay} />
      <${AgentDetailOverlay} />
      <${ToastContainer} />
    </div>
  `
}
