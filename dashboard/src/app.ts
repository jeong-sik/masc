// MASC Dashboard — Root component
// Sticky app shell with tab routing and live status rail

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { route, initRouter, navigate } from './router'
import { connected, eventCount, connectSSE, disconnectSSE } from './sse'
import {
  refreshDashboard,
  refreshExecution,
  refreshDashboardSemantics,
  refreshBoard,
  refreshGoals,
  refreshShell,
  refreshTrpg,
  setupSSEReaction,
  startPeriodicRefresh,
  stopPeriodicRefresh,
  dashboardLoading,
  agents,
  tasks,
  keepers,
} from './store'
import { Mission } from './components/mission'
import { Command } from './components/command'
import { Ops } from './components/ops'
import { Memory } from './components/memory'
import { Execution } from './components/agents'
import { Planning } from './components/goals'
import { Governance } from './components/governance'
import { Lab } from './components/lab'
import { KeeperDetailOverlay } from './components/keeper-detail'
import { AgentDetailOverlay } from './components/agent-detail'
import { ToastContainer } from './components/common/toast'
import { PanelSemanticDetails, SurfaceSemanticIntro } from './components/common/semantic-layer'
import { DASHBOARD_NAV_ITEMS, DASHBOARD_NAV_SECTIONS } from './config/navigation'
import { operatorSnapshot, refreshOperatorRoomDigest, refreshOperatorSnapshot } from './operator-store'
import { refreshMissionSnapshot } from './mission-store'
import {
  commandPlaneSurface,
  refreshCommandPlaneChainSummary,
  refreshCommandPlaneCurrentSurface,
  refreshCommandPlaneSwarm,
} from './command-store'

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

function SnapshotCard({ currentTab, currentSectionLabel }: { currentTab: string; currentSectionLabel: string }) {
  const liveConnected = connected.value
  return html`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${PanelSemanticDetails} panelId="side_rail.snapshot" compact=${true} />
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
        <span>${currentSectionLabel} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${() => {
            refreshDashboard()
            refreshDashboardSemantics()
            if (currentTab === 'command') {
              refreshCommandPlaneCurrentSurface()
              refreshCommandPlaneChainSummary()
              if (commandPlaneSurface.value === 'swarm') {
                refreshCommandPlaneSwarm()
              }
            }
            if (currentTab === 'mission') {
              refreshMissionSnapshot()
            }
            if (currentTab === 'execution') {
              refreshExecution()
            }
            if (currentTab === 'intervene') {
              refreshOperatorSnapshot()
              refreshOperatorRoomDigest()
            }
            if (currentTab === 'memory') refreshBoard()
            if (currentTab === 'planning') {
              refreshGoals()
            }
            if (currentTab === 'lab') refreshTrpg()
          }}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${() => navigate('intervene')}>
          Open Intervene
        </button>
      </div>
    </section>
  `
}

function InterveneRailCard() {
  const snapshot = operatorSnapshot.value
  const pendingConfirms = snapshot?.pending_confirms.length ?? 0
  const sessionCount = snapshot?.sessions.length ?? 0
  const keeperCount = snapshot?.keepers.length ?? 0
  return html`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${PanelSemanticDetails} panelId="side_rail.quick_actions" compact=${true} />
        <span class="rail-section-chip ${pendingConfirms > 0 ? 'warn' : 'ok'}">${pendingConfirms > 0 ? '확인 필요' : '준비됨'}</span>
      </div>
      <div class="rail-snapshot-copy">
        <span>구조화된 개입은 전용 화면에서 처리합니다</span>
        <span>rail은 요약만, 실제 조작은 Intervene에서</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>확인 대기</span>
          <strong>${pendingConfirms}</strong>
        </div>
        <div class="rail-stat-card">
          <span>세션</span>
          <strong>${sessionCount}</strong>
        </div>
        <div class="rail-stat-card">
          <span>keepers</span>
          <strong>${keeperCount}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${() => {
            refreshOperatorSnapshot()
            refreshOperatorRoomDigest()
          }}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${() => navigate('intervene')}>
          개입 열기
        </button>
      </div>
    </section>
  `
}

function SideRail() {
  const current = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === current)
  const currentSection = DASHBOARD_NAV_SECTIONS.find(section => section.id === currentView?.group)

  return html`
    <aside class="dashboard-rail">
      <${SurfaceSemanticIntro} surfaceId="side_rail" compact=${true} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          <${PanelSemanticDetails} panelId="side_rail.navigate" compact=${true} />
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

      <${SnapshotCard} currentTab=${current} currentSectionLabel=${currentSection?.label ?? 'Observe'} />
      <${InterveneRailCard} />
    </aside>
  `
}

function TabContent() {
  const tab = route.value.tab

  switch (tab) {
    case 'mission':
      return html`<${Mission} />`
    case 'execution':
      return html`<${Execution} />`
    case 'memory':
      return html`<${Memory} />`
    case 'governance':
      return html`<${Governance} />`
    case 'planning':
      return html`<${Planning} />`
    case 'intervene':
      return html`<${Ops} />`
    case 'command':
      return html`<${Command} />`
    case 'lab':
      return html`<${Lab} />`
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
    refreshShell()
    refreshExecution()
    refreshDashboardSemantics()
    refreshMissionSnapshot()

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
      else if (tab === 'mission') {
        void refreshMissionSnapshot()
      }
      else if (tab === 'execution') {
        void refreshExecution()
      }
      else if (tab === 'intervene') {
        void refreshOperatorSnapshot()
        void refreshOperatorRoomDigest()
      }
      else if (tab === 'memory') void refreshBoard()
      else if (tab === 'planning') {
        void refreshGoals()
      }
      else if (tab === 'lab') void refreshTrpg()
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
    if (tab === 'mission') {
      refreshMissionSnapshot()
    }
    if (tab === 'execution') {
      refreshExecution()
    }
    if (tab === 'intervene') {
      refreshOperatorSnapshot()
      refreshOperatorRoomDigest()
    }
    if (tab === 'memory') refreshBoard()
    if (tab === 'planning') {
      refreshGoals()
    }
    if (tab === 'lab') refreshTrpg()
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
          <p class="header-subtitle">${currentView?.description ?? 'Operator-first decision and execution console'}</p>
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
