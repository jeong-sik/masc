// MASC Dashboard — Root component
// Sticky app shell with tab routing and live status rail

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
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
import { KeeperDetailOverlay } from './components/keeper-detail'
import { AgentDetailOverlay } from './components/agent-detail'
import { TaskDetailOverlay } from './components/goals/task-detail-overlay'
import { ToastContainer } from './components/common/toast'
import { ConfirmDialogOverlay } from './components/common/confirm-dialog'
import { CommandPalette } from './components/common/command-palette'
import { AuthStatus, RemoteWarningBanner } from './components/auth-status'
import { DASHBOARD_NAV_ITEMS, currentSectionForRoute } from './config/navigation'
import { Menu, X } from 'lucide-preact'

export const sidebarCollapsed = signal(false)
export const mobileMenuOpen = signal(false)

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

  return html`
    <div class="flex min-h-screen h-screen flex-col overflow-hidden bg-[var(--bg-0)] bg-[radial-gradient(ellipse_at_top,rgba(25,40,70,0.3)_0%,rgba(11,18,32,1)_80%)] text-[var(--text-body)]">
      <header class="relative z-10 shrink-0 border-b border-[rgba(255,255,255,0.06)] bg-[rgba(8,14,26,0.44)] px-4 py-2 backdrop-blur-xl">
        <div class="absolute inset-x-0 bottom-0 h-[1px] bg-gradient-to-r from-transparent via-[rgba(71,184,255,0.15)] to-transparent"></div>
        <div class="flex w-full items-center justify-between gap-4 max-[860px]:flex-col max-[860px]:items-stretch">
          <div class="min-w-0">
            <div class="flex items-center gap-4">
              <button type="button"
                class="hidden max-[768px]:flex size-10 items-center justify-center rounded-lg border border-[var(--white-10)] bg-[var(--white-5)] text-[var(--text-body)] cursor-pointer transition-colors hover:bg-[rgba(255,255,255,0.1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[rgba(71,184,255,0.45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-0)]"
                aria-expanded=${mobileMenuOpen.value}
                aria-label=${mobileMenuOpen.value ? '탐색 메뉴 닫기' : '탐색 메뉴 열기'}
                aria-controls="dashboard-side-rail"
                onClick=${() => { mobileMenuOpen.value = !mobileMenuOpen.value }}
              >
                ${mobileMenuOpen.value ? html`<${X} size=${20} />` : html`<${Menu} size=${20} />`}
              </button>
              <div class="flex size-8 shrink-0 items-center justify-center rounded-lg border border-[rgba(71,184,255,0.3)] bg-[linear-gradient(135deg,rgba(71,184,255,0.2),rgba(10,28,58,0.8))] text-[15px] font-bold text-[var(--text-strong)]">
                ${currentView?.icon ?? 'M'}
              </div>
              <div class="min-w-0 flex flex-col justify-center">
                <div class="flex flex-wrap items-center gap-2 mb-0.5">
                  <span class="text-[10px] font-bold uppercase tracking-[0.25em] text-[rgba(154,217,255,0.6)]">MASC Control Deck</span>
                </div>
                <h1 class="text-[15px] font-semibold tracking-[-0.02em] text-[var(--text-strong)] leading-none flex items-center gap-1.5">
                  ${currentView?.label ?? 'Multi-Agent Namespace Console'}
                  ${currentSection && currentSection.label !== currentView?.label
                    ? html`<span class="text-[13px] font-medium text-[var(--text-muted)]">/</span><span class="text-[15px] font-medium text-[rgba(154,217,255,0.8)]">${currentSection.label}</span>`
                    : null}
                </h1>
              </div>
            </div>
          </div>

          <div class="flex shrink-0 flex-col items-end gap-2">
            <div class="flex items-center gap-2">
              <${AuthStatus} />
              <${ConnectionStatus} />
            </div>
            <${BuildIdentityBadge} />
          </div>
        </div>
      </header>

      <${RemoteWarningBanner} />

      <div class="flex flex-1 gap-2 overflow-hidden p-2 max-[1100px]:flex-col">
        <aside id="dashboard-side-rail" class="${sidebarCollapsed.value ? 'w-14' : 'w-[220px]'} shrink-0 overflow-y-auto overflow-x-hidden rounded-xl border border-[rgba(255,255,255,0.06)] bg-[rgba(15,22,36,0.6)] backdrop-blur-xl transition-[width] duration-300 ease-[cubic-bezier(0.2,0.8,0.2,1)] max-[1100px]:w-full max-[1100px]:max-h-[300px] ${mobileMenuOpen.value ? '' : 'max-[768px]:hidden'}">
          <${SideRail} collapsed=${sidebarCollapsed.value} onToggle=${() => { sidebarCollapsed.value = !sidebarCollapsed.value }} />
        </aside>

        <main class="min-w-0 flex-1 overflow-hidden rounded-xl border border-[rgba(255,255,255,0.06)] bg-[rgba(10,15,26,0.68)] backdrop-blur-lg max-[1100px]:min-h-0">
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
