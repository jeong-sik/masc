// MASC Dashboard — Root component
// Sticky app shell with tab routing and live status rail

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { route, initRouter, navigate } from './router'
import { connected, eventCount, connectSSE, disconnectSSE } from './sse'
import {
  refreshDashboard,
  refreshDashboardSemantics,
  refreshBoard,
  refreshTrpg,
  refreshGoals,
  refreshMdal,
  setupSSEReaction,
  startPeriodicRefresh,
  stopPeriodicRefresh,
  dashboardLoading,
} from './store'
import { Mission } from './components/mission'
import { Command } from './components/command'
import { Ops } from './components/ops'
import { Board } from './components/board'
import { Activity } from './components/activity'
import { Agents } from './components/agents'
import { Goals } from './components/goals'
import { Trpg } from './components/trpg'
import { KeeperDetailOverlay } from './components/keeper-detail'
import { AgentDetailOverlay } from './components/agent-detail'
import { ToastContainer } from './components/common/toast'
import { DASHBOARD_NAV_ITEMS, DASHBOARD_NAV_SECTIONS } from './config/navigation'
import { operatorSnapshot, refreshOperatorRoomDigest, refreshOperatorSnapshot } from './operator-store'
import { refreshMissionSnapshot } from './mission-store'
import {
  commandPlaneSurface,
  refreshCommandPlaneChainSummary,
  refreshCommandPlaneCurrentSurface,
  refreshCommandPlaneSwarm,
} from './command-store'
import { activityPanelOpen, closeActivityPanel, toggleActivityPanel } from './activity-panel'

function ConnectionStatus() {
  const isConnected = connected.value
  return html`
    <div class="connection-status ${isConnected ? 'connected' : 'disconnected'}">
      <span class="status-dot ${isConnected ? 'connected' : 'disconnected'}"></span>
      <span class="status-text">${isConnected ? 'Live' : 'Reconnecting...'}</span>
      <span class="event-count">${eventCount.value} events</span>
    </div>
  `
}

function InterveneRailBadge() {
  const snapshot = operatorSnapshot.value
  const pendingConfirms = snapshot?.pending_confirms.length ?? 0
  if (pendingConfirms === 0) return null
  return html`
    <button
      class="rail-intervene-badge warn"
      onClick=${() => navigate('intervene')}
      title="확인 대기 ${pendingConfirms}건"
    >
      <span class="rail-badge-count">${pendingConfirms}</span>
      <span class="rail-badge-label">확인 대기</span>
    </button>
  `
}

function SideRail() {
  const current = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === current)
  const currentSection = DASHBOARD_NAV_SECTIONS.find(section => section.id === currentView?.group)

  return html`
    <aside class="dashboard-rail">
      <section class="rail-card rail-card-compact">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${currentSection ? html`<span class="rail-section-chip">${currentSection.label}</span>` : null}
        </div>
        ${DASHBOARD_NAV_SECTIONS.map(section => html`
          <div class="rail-nav-group" key=${section.id}>
            <div class="rail-group-label">${section.label}</div>
            <div class="rail-tab-list">
              ${DASHBOARD_NAV_ITEMS
                .filter(item => item.group === section.id)
                .map(item => html`
                  <button
                    class="rail-tab-btn ${current === item.id ? 'active' : ''}"
                    onClick=${() => navigate(item.id)}
                    title=${item.description}
                  >
                    <span class="rail-tab-icon">${item.icon}</span>
                    <strong>${item.label}</strong>
                  </button>
                `)}
            </div>
          </div>
        `)}
      </section>
      <${InterveneRailBadge} />
    </aside>
  `
}

function TabContent() {
  const tab = route.value.tab

  switch (tab) {
    case 'mission':
      return html`<${Mission} />`
    case 'intervene':
      return html`<${Ops} />`
    case 'command':
      return html`<${Command} />`
    case 'overview':
      return html`<${Mission} />`
    case 'ops':
      return html`<${Ops} />`
    case 'board':
      return html`<${Board} />`
    case 'agents':
      return html`<${Agents} />`
    case 'goals':
      return html`<${Goals} />`
    case 'trpg':
      return html`<${Trpg} />`
    default:
      return html`<${Mission} />`
  }
}

export function App() {
  useEffect(() => {
    // Initialize hash router and compatible deep links
    initRouter()

    // Connect SSE and start data fetching
    connectSSE()
    refreshDashboard()
    refreshDashboardSemantics()

    // Setup SSE → store reaction (debounced refresh on events)
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
    const interval = setInterval(() => {
      const tab = route.value.tab
      if (tab === 'command') {
        void refreshCommandPlaneCurrentSurface()
        void refreshCommandPlaneChainSummary()
        if (commandPlaneSurface.value === 'swarm') {
          void refreshCommandPlaneSwarm()
        }
      }
      else if (tab === 'mission' || tab === 'overview') {
        void refreshMissionSnapshot()
      }
      else if (tab === 'intervene' || tab === 'ops') {
        void refreshOperatorSnapshot()
        void refreshOperatorRoomDigest()
      }
      else if (tab === 'board') void refreshBoard()
      else if (tab === 'trpg') void refreshTrpg()
      else if (tab === 'goals') {
        void refreshGoals()
        void refreshMdal()
      }
    }, 15000)

    return () => {
      clearInterval(interval)
    }
  }, [])

  // Fetch tab-specific data when tab changes
  useEffect(() => {
    const tab = route.value.tab
    if (tab === 'command') {
      refreshCommandPlaneCurrentSurface()
      refreshCommandPlaneChainSummary()
      if (commandPlaneSurface.value === 'swarm') {
        refreshCommandPlaneSwarm()
      }
    }
    if (tab === 'mission' || tab === 'overview') {
      refreshMissionSnapshot()
    }
    if (tab === 'intervene' || tab === 'ops') {
      refreshOperatorSnapshot()
      refreshOperatorRoomDigest()
    }
    if (tab === 'board') refreshBoard()
    if (tab === 'trpg') refreshTrpg()
    if (tab === 'goals') {
      refreshGoals()
      refreshMdal()
    }
  }, [route.value.tab])

  const currentTab = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === currentTab)

  return html`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${currentView?.description ?? 'Decision and execution operations console'}</p>
        </div>
        <div class="header-right">
          <button
            class="activity-panel-toggle ${activityPanelOpen.value ? 'active' : ''}"
            onClick=${toggleActivityPanel}
            title="Toggle Activity Panel"
          >
            Activity
          </button>
          <${ConnectionStatus} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${SideRail} />
        <main class="dashboard-main">
          ${dashboardLoading.value && !connected.value
            ? html`<div class="loading-indicator">Loading dashboard...</div>`
            : html`<${TabContent} />`}
        </main>
      </div>

      ${activityPanelOpen.value ? html`
        <div class="activity-panel-backdrop" onClick=${closeActivityPanel} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${closeActivityPanel}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${Activity} />
          </div>
        </aside>
      ` : null}

      <${KeeperDetailOverlay} />
      <${AgentDetailOverlay} />
      <${ToastContainer} />
    </div>
  `
}
