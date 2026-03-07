// MASC Dashboard — Root component
// Sticky app shell with tab routing and live status rail

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
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
import { Command } from './components/command'
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
import { DASHBOARD_NAV_ITEMS, DASHBOARD_NAV_SECTIONS } from './config/navigation'
import { refreshOperatorSnapshot } from './operator-store'
import { refreshCommandPlaneSnapshot } from './command-store'

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
  const currentSection = DASHBOARD_NAV_SECTIONS.find(section => section.id === currentView?.group)
  const [quickActionsOpen, setQuickActionsOpen] = useState(false)

  return html`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${currentSection ? html`<span class="rail-section-chip">${currentSection.label}</span>` : null}
        </div>
        ${DASHBOARD_NAV_SECTIONS.map(section => html`
          <div class="rail-nav-group" key=${section.id}>
            <div class="rail-group-label">${section.label}</div>
            <div class="rail-group-copy">${section.description}</div>
            <div class="rail-tab-list">
              ${DASHBOARD_NAV_ITEMS
                .filter(item => item.group === section.id)
                .map(item => html`
                  <button
                    class="rail-tab-btn ${current === item.id ? 'active' : ''}"
                    onClick=${() => navigate(item.id)}
                  >
                    <span class="rail-tab-icon">${item.icon}</span>
                    <span class="rail-tab-copy">
                      <strong>${item.label}</strong>
                      <span>${item.description}</span>
                    </span>
                  </button>
                `)}
            </div>
          </div>
        `)}
        <div class="rail-view-note">
          <div class="rail-view-note-label">Current focus</div>
          <strong>${currentView?.label ?? current}</strong>
          <p>${currentView?.description ?? 'Live operational view'}</p>
        </div>
      </section>

      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Snapshot</h3>
          <span class="rail-section-chip ${liveConnected ? 'ok' : 'bad'}">${liveConnected ? 'Live' : 'Offline'}</span>
        </div>
        <div class="rail-stat-grid">
          <div class="rail-stat-card">
            <span>Agents</span>
            <strong>${agents.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Keepers</span>
            <strong>${keepers.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Tasks</span>
            <strong>${tasks.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Events</span>
            <strong>${eventCount.value}</strong>
          </div>
        </div>
        <div class="rail-snapshot-copy">
          <span>Connection ${liveConnected ? 'healthy' : 'recovering'}</span>
          <span>${currentSection?.label ?? 'Observe'} workspace active</span>
        </div>
        <div class="rail-inline-actions">
          <button
            class="rail-refresh-btn"
            onClick=${() => {
              refreshDashboard()
              if (current === 'command') refreshCommandPlaneSnapshot()
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
          <button class="rail-secondary-btn" onClick=${() => navigate('ops')}>
            Open Ops
          </button>
        </div>
      </section>

      <section class="rail-card fold-card">
        <div class="rail-card-head">
          <h3>Quick Actions</h3>
          <span class="rail-section-chip">${quickActionsOpen ? 'Open' : 'Closed'}</span>
        </div>
        <button class="fold-toggle" onClick=${() => setQuickActionsOpen(open => !open)}>
          <span>${quickActionsOpen ? 'Hide inline actions' : 'Show inline actions'}</span>
          <span class="fold-toggle-meta">Join, broadcast, keeper DM, lodge poke</span>
        </button>
        ${quickActionsOpen
          ? html`<div class="rail-fold-body"><${ControlDock} /></div>`
          : html`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `
}

function TabContent() {
  const tab = route.value.tab

  switch (tab) {
    case 'command':
      return html`<${Command} />`
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
    if (tab === 'command') refreshCommandPlaneSnapshot()
    if (tab === 'ops') refreshOperatorSnapshot()
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

      <${KeeperDetailOverlay} />
      <${AgentDetailOverlay} />
      <${ToastContainer} />
    </div>
  `
}
