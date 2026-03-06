// MASC Dashboard — Root component
// Sticky app shell with tab routing and live status rail

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { TabNav } from './components/common/tab-nav'
import { route, initRouter, navigate } from './router'
import { connected, eventCount, connectSSE, disconnectSSE } from './sse'
import {
  refreshDashboard,
  refreshBoard,
  refreshTrpg,
  refreshGoals,
  refreshMdal,
  setupSSEReaction,
  startPeriodicRefresh,
  stopPeriodicRefresh,
  dashboardLoading,
  agents,
  tasks,
  keepers,
} from './store'
import { Overview } from './components/overview'
import { Ops } from './components/ops'
import { Council } from './components/council'
import { Board } from './components/board'
import { Activity } from './components/activity'
import { Agents } from './components/agents'
import { Tasks } from './components/tasks'
import { Execution } from './components/execution'
import { Goals } from './components/goals'
import { Trpg } from './components/trpg'
import { ControlDock } from './components/control-dock'
import { KeeperDetailOverlay } from './components/keeper-detail'
import { AgentDetailOverlay } from './components/agent-detail'
import { ToastContainer } from './components/common/toast'
import { DASHBOARD_NAV_ITEMS } from './config/navigation'
import { refreshOperatorSnapshot } from './operator-store'

const VIEW_DESCRIPTIONS: Record<string, string> = {
  overview: 'Room health, keeper pressure, and top-line execution status',
  board: 'Human and agent discussion feed with system noise filtered by default',
  activity: 'Unified live stream for messages, task changes, board events, and keeper events',
  council: 'Debates, quorum status, and decision flow',
  goals: 'Goals and MDAL loops in one planning surface with freshness signals',
  execution: 'Queue readiness and assignee coverage',
  tasks: 'Kanban-style task distribution',
  agents: 'Live monitor for agent status, keeper pressure, and current execution focus',
  ops: 'Guided operator controls for room, sessions, and keepers',
  trpg: 'Narrative room control and state visibility',
}

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

function SideRail() {
  const current = route.value.tab
  const liveConnected = connected.value
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === current)

  return html`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${DASHBOARD_NAV_ITEMS.map(t => html`
            <button
              class="rail-tab-btn ${current === t.id ? 'active' : ''}"
              onClick=${() => navigate(t.id)}
            >
              ${t.icon} ${t.label}
            </button>
          `)}
        </div>
        <div class="rail-view-note">
          <div class="rail-view-note-label">Current focus</div>
          <strong>${currentView?.label ?? current}</strong>
          <p>${VIEW_DESCRIPTIONS[current] ?? 'Live operational view'}</p>
        </div>
      </section>

      <section class="rail-card">
        <h3>Live Snapshot</h3>
        <div class="rail-stats">
          <div class="rail-stat-row">
            <span>Connection</span>
            <strong>${liveConnected ? 'Online' : 'Offline'}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Agents</span>
            <strong>${agents.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${keepers.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${tasks.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${eventCount.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${() => {
            refreshDashboard()
            if (current === 'ops') refreshOperatorSnapshot()
            if (current === 'board') refreshBoard()
            if (current === 'trpg') refreshTrpg()
            if (current === 'goals') {
              refreshGoals()
              refreshMdal()
            }
          }}
        >
          Refresh Now
        </button>
      </section>

      <${ControlDock} />
    </aside>
  `
}

function TabContent() {
  const tab = route.value.tab

  switch (tab) {
    case 'overview':
      return html`<${Overview} />`
    case 'ops':
      return html`<${Ops} />`
    case 'council':
      return html`<${Council} />`
    case 'board':
      return html`<${Board} />`
    case 'execution':
      return html`<${Execution} />`
    case 'activity':
      return html`<${Activity} />`
    case 'agents':
      return html`<${Agents} />`
    case 'tasks':
      return html`<${Tasks} />`
    case 'goals':
      return html`<${Goals} />`
    case 'trpg':
      return html`<${Trpg} />`
    default:
      return html`<${Overview} />`
  }
}

export function App() {
  useEffect(() => {
    // Initialize hash router and compatible deep links
    initRouter()

    // Connect SSE and start data fetching
    connectSSE()
    refreshDashboard()
    refreshBoard()

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

  // Fetch tab-specific data when tab changes
  useEffect(() => {
    const tab = route.value.tab
    if (tab === 'ops') refreshOperatorSnapshot()
    if (tab === 'board') refreshBoard()
    if (tab === 'trpg') refreshTrpg()
    if (tab === 'goals') {
      refreshGoals()
      refreshMdal()
    }
  }, [route.value.tab])

  const currentTab = route.value.tab

  return html`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${VIEW_DESCRIPTIONS[currentTab] ?? 'Decision and execution operations console'}</p>
        </div>
        <div class="header-right">
          <${ConnectionStatus} />
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${TabNav} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${dashboardLoading.value && !connected.value
            ? html`<div class="loading-indicator">Loading dashboard...</div>`
            : html`<${TabContent} />`}
        </main>
        <${SideRail} />
      </div>

      <${KeeperDetailOverlay} />
      <${AgentDetailOverlay} />
      <${ToastContainer} />
    </div>
  `
}
