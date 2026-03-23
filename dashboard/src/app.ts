// MASC Dashboard — Root component
// Sticky app shell with tab routing and live status rail

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
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

export const sidebarCollapsed = signal(false)

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
    <div class="flex min-h-screen h-screen flex-col overflow-hidden bg-[var(--bg-0)] bg-[radial-gradient(ellipse_at_top,rgba(25,40,70,0.3)_0%,rgba(11,18,32,1)_80%)] text-[var(--text-body)]">
      <header class="shrink-0 border-b border-[rgba(255,255,255,0.06)] bg-[rgba(8,14,26,0.5)] px-6 py-4 backdrop-blur-2xl z-10 relative">
        <div class="absolute inset-x-0 bottom-0 h-[1px] bg-gradient-to-r from-transparent via-[rgba(71,184,255,0.15)] to-transparent"></div>
        <div class="mx-auto flex w-full max-w-[1680px] items-start justify-between gap-6 max-[860px]:flex-col max-[860px]:items-stretch">
          <div class="min-w-0">
            <div class="flex items-center gap-4">
              <div class="flex size-11 shrink-0 items-center justify-center rounded-[14px] border border-[rgba(71,184,255,0.3)] bg-[linear-gradient(135deg,rgba(71,184,255,0.2),rgba(10,28,58,0.8))] text-[18px] font-bold text-[#bfe7ff] shadow-[0_0_20px_rgba(71,184,255,0.15)]">
                ${currentView?.icon ?? 'M'}
              </div>
              <div class="min-w-0 flex flex-col justify-center">
                <div class="flex flex-wrap items-center gap-2 mb-0.5">
                  <span class="text-[10px] font-bold uppercase tracking-[0.25em] text-[rgba(154,217,255,0.6)]">MASC Control Deck</span>
                </div>
                <h1 class="text-[18px] font-semibold tracking-[-0.02em] text-[var(--text-strong)] leading-none flex items-center gap-2">
                  ${currentView?.label ?? 'Multi-Agent Room Console'}
                  ${currentSection && currentSection.label !== currentView?.label
                    ? html`<span class="text-[13px] font-medium text-[rgba(154,217,255,0.5)]">/</span><span class="text-[15px] font-medium text-[rgba(154,217,255,0.8)]">${currentSection.label}</span>`
                    : null}
                </h1>
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
        <aside class="${sidebarCollapsed.value ? 'w-16' : 'w-[260px]'} shrink-0 overflow-y-auto overflow-x-hidden rounded-[20px] border border-[rgba(255,255,255,0.06)] bg-[rgba(15,22,36,0.6)] backdrop-blur-xl shadow-[0_8px_32px_rgba(0,0,0,0.4)] transition-[width] duration-300 ease-[cubic-bezier(0.2,0.8,0.2,1)] max-[1100px]:w-full max-[1100px]:max-h-[360px] relative">
          <div class="absolute inset-0 bg-gradient-to-b from-[rgba(255,255,255,0.03)] to-transparent pointer-events-none rounded-[20px]"></div>
          <div class="relative h-full">
            <${SideRail} collapsed=${sidebarCollapsed.value} onToggle=${() => { sidebarCollapsed.value = !sidebarCollapsed.value }} />
          </div>
        </aside>

        <main class="min-w-0 flex-1 overflow-hidden rounded-[20px] border border-[rgba(255,255,255,0.06)] bg-[rgba(10,15,26,0.7)] backdrop-blur-xl shadow-[0_8px_32px_rgba(0,0,0,0.4)] max-[1100px]:min-h-0 relative">
          <div class="absolute inset-0 bg-gradient-to-b from-[rgba(255,255,255,0.02)] to-transparent pointer-events-none rounded-[20px]"></div>
          <div class="relative mx-auto h-full max-w-[1600px] overflow-y-auto p-6 lg:p-8">
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
