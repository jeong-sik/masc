// MASC Dashboard — Root component
// Renders header, connection status, tab nav, and routed tab content

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { TabNav } from './components/common/tab-nav'
import { route, initRouter } from './router'
import { connected, eventCount, connectSSE, disconnectSSE } from './sse'
import {
  refreshDashboard,
  refreshBoard,
  refreshTrpg,
  setupSSEReaction,
  startPeriodicRefresh,
  stopPeriodicRefresh,
  dashboardLoading,
} from './store'
import { Overview } from './components/overview'
import { Board } from './components/board'
import { Activity } from './components/activity'
import { Agents } from './components/agents'
import { Tasks } from './components/tasks'
import { Journal } from './components/journal'
import { Trpg } from './components/trpg'

function ConnectionStatus() {
  const isConnected = connected.value
  return html`
    <div class="connection-status">
      <span class="status-dot ${isConnected ? 'connected' : ''}"></span>
      <span class="status-text">${isConnected ? 'Live' : 'Connecting...'}</span>
      ${eventCount.value > 0
        ? html`<span class="event-count">${eventCount.value} events</span>`
        : null}
    </div>
  `
}

function TabContent() {
  const tab = route.value.tab

  switch (tab) {
    case 'overview':
      return html`<${Overview} />`
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
    // Initialize hash router
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
    <div class="container">
      <header>
        <h1>
          MASC Dashboard
          <span class="version-badge">SPA</span>
        </h1>
        <${ConnectionStatus} />
      </header>

      <${TabNav} />

      <main>
        ${dashboardLoading.value && !connected.value
          ? html`<div class="loading-indicator">Loading dashboard...</div>`
          : html`<${TabContent} />`}
      </main>
    </div>
  `
}
