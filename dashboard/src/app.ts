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
  agents,
  tasks,
  keepers,
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
            if (currentTab === 'mission' || currentTab === 'overview') {
              refreshMissionSnapshot()
            }
            if (currentTab === 'intervene' || currentTab === 'ops') {
              refreshOperatorSnapshot()
              refreshOperatorRoomDigest()
            }
            if (currentTab === 'board') refreshBoard()
            if (currentTab === 'trpg') refreshTrpg()
            if (currentTab === 'goals') {
              refreshGoals()
              refreshMdal()
            }
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
