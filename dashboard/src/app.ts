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
    <div class="flex min-h-screen h-screen flex-col overflow-hidden bg-[var(--bg-0)] text-[var(--text-body)]">
      <header class="shrink-0 border-b border-[var(--card-border)] bg-[rgba(4,9,18,0.82)] px-6 py-4 backdrop-blur-xl z-10">
        <div class="mx-auto flex w-full max-w-[1680px] items-start justify-between gap-6 max-[860px]:flex-col max-[860px]:items-stretch">
          <div class="min-w-0">
            <div class="flex items-center gap-4">
              <div class="flex size-12 shrink-0 items-center justify-center rounded-2xl border border-[rgba(113,214,255,0.28)] bg-[linear-gradient(145deg,rgba(61,157,255,0.34),rgba(10,28,58,0.95))] text-[18px] font-semibold text-white shadow-lg">
                ${currentView?.icon ?? 'M'}
              </div>
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2 mb-1">
                  <span class="text-[10px] font-semibold uppercase tracking-[0.22em] text-[rgba(154,217,255,0.7)]">MASC</span>
                  ${currentView
                    ? html`
                        <span class="text-[10px] font-medium text-[rgba(154,217,255,0.4)]">/</span>
                        <span class="text-[10px] font-semibold uppercase tracking-[0.1em] text-[rgba(154,217,255,0.9)]">${currentView.label}</span>
                      `
                    : null}
                </div>
                <h1 class="text-[22px] font-semibold tracking-[-0.03em] text-[var(--text-strong)] leading-none">
                  ${currentSection?.label ?? currentView?.label ?? 'Multi-Agent Room Console'}
                </h1>
                <p class="mt-1.5 max-w-[760px] text-[12px] leading-relaxed text-[var(--text-muted)]">
                  ${currentSection?.description ?? currentView?.description ?? 'Rooms, keepers, governance, and operational signals in one place.'}
                </p>
              </div>
            </div>
          </div>

          <div class="flex shrink-0 flex-col items-end gap-2">
            <${ConnectionStatus} />
            <${BuildIdentityBadge} />
          </div>
        </div>
      </header>

      <div class="flex flex-1 gap-5 overflow-hidden p-5 max-[1100px]:flex-col max-[1100px]:p-4">
        <aside class="w-72 shrink-0 overflow-y-auto rounded-3xl border border-[var(--card-border)] bg-[linear-gradient(180deg,rgba(9,17,31,0.94),rgba(7,14,26,0.9))] shadow-xl max-[1100px]:w-full max-[1100px]:max-h-[360px]">
          <${SideRail} />
        </aside>

        <main class="min-w-0 flex-1 overflow-hidden rounded-3xl border border-[var(--card-border)] bg-[linear-gradient(180deg,rgba(8,15,28,0.92),rgba(9,14,25,0.88))] shadow-xl max-[1100px]:min-h-0">
          <div class="mx-auto h-full max-w-[1600px] overflow-y-auto p-6 lg:p-8">
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
