// MASC Dashboard — Root component
// Sticky app shell with tab routing and live status rail

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { route, initRouter } from './router'
import { connectSSE, disconnectSSE } from './sse'
import { dashboardSemantics } from './store'
import { fetchDashboardSemantics } from './api'
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
import { DASHBOARD_NAV_ITEMS } from './config/navigation'

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

    // Semantics: static data, fetch once and cache forever.
    void fetchDashboardSemantics()
      .then(data => { dashboardSemantics.value = data })
      .catch(err => { console.warn('Semantics load failed (non-critical):', err) })

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
  }, [route.value.tab])

  const currentTab = route.value.tab
  const isHome = currentTab === 'home'
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === currentTab)

  return html`
    <div class="app-shell">
      <header class="dashboard-header ${isHome ? 'dashboard-header--slim' : ''}">
        <div class="header-title-wrap">
          <h1>
            MASC 대시보드
            <${BuildIdentityBadge} />
          </h1>
          <p class="header-subtitle">${currentView?.description ?? '운영자 의사결정 및 실행 콘솔'}</p>
        </div>
        <div class="header-right">
          <${ConnectionStatus} />
        </div>
      </header>

      <div class="dashboard-layout ${isHome ? 'dashboard-layout--home' : ''}">
        ${isHome ? null : html`<${SideRail} />`}
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
