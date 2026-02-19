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
  setupSSEReaction,
  startPeriodicRefresh,
  stopPeriodicRefresh,
  dashboardLoading,
  agents,
  tasks,
  keepers,
} from './store'
import type { TabId } from './types'
import { Overview } from './components/overview'
import { Council } from './components/council'
import { Board } from './components/board'
import { Activity } from './components/activity'
import { Agents } from './components/agents'
import { Tasks } from './components/tasks'
import { Journal } from './components/journal'
import { Trpg } from './components/trpg'
import { ControlDock } from './components/control-dock'
import { KeeperDetailOverlay } from './components/keeper-detail'
import { ToastContainer } from './components/common/toast'

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

const RAIL_TABS: { id: TabId; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'council', label: 'Council' },
  { id: 'board', label: 'Board' },
  { id: 'activity', label: 'Activity' },
  { id: 'agents', label: 'Agents' },
  { id: 'tasks', label: 'Tasks' },
  { id: 'journal', label: 'Journal' },
  { id: 'trpg', label: 'TRPG' },
]

function SideRail() {
  const current = route.value.tab
  const liveConnected = connected.value

  return html`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${RAIL_TABS.map(t => html`
            <button
              class="rail-tab-btn ${current === t.id ? 'active' : ''}"
              onClick=${() => navigate(t.id)}
            >
              ${t.label}
            </button>
          `)}
        </div>
        <div class="rail-links">
          <a class="rail-link" href="/dashboard/lodge">Legacy Lodge</a>
          <a class="rail-link" href="/dashboard/credits">Legacy Credits</a>
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
            if (current === 'board') refreshBoard()
            if (current === 'trpg') refreshTrpg()
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
    case 'council':
      return html`<${Council} />`
    case 'board':
      return html`<${Board} />`
    case 'activity':
      return html`<${Activity} />`
    case 'agents':
      return html`<${Agents} />`
    case 'tasks':
      return html`<${Tasks} />`
    case 'journal':
      return html`<${Journal} />`
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
    if (tab === 'board') refreshBoard()
    if (tab === 'trpg') refreshTrpg()
  }, [route.value.tab])

  return html`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">Real-time multi-agent operations console</p>
        </div>
        <div class="header-right">
          <${ConnectionStatus} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
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
      <${ToastContainer} />
    </div>
  `
}
