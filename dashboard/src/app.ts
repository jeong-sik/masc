// MASC Dashboard — Root component
// Sticky app shell with tab routing and live status rail

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
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
  dashboardLoading,
  agents,
  tasks,
  keepers,
  serverStatus,
} from './store'
import { setupSSEReaction, startPeriodicRefresh, stopPeriodicRefresh } from './sse-store'
import { Mission } from './components/mission'
import { Proof } from './components/proof'
import { Command } from './components/command'
import { Ops } from './components/ops'
import { Memory } from './components/memory'
import { Execution } from './components/agents'
import { Planning } from './components/goals'
import { Governance } from './components/governance'
import { Lab } from './components/lab'
import { Live } from './components/live'
import { KeeperDetailOverlay } from './components/keeper-detail'
import { AgentDetailOverlay } from './components/agent-detail'
import { TimeAgo } from './components/common/time-ago'
import { ToastContainer } from './components/common/toast'
import { PanelSemanticDetails, SurfaceSemanticIntro } from './components/common/semantic-layer'
import { DASHBOARD_NAV_ITEMS, DASHBOARD_NAV_SECTIONS } from './config/navigation'
import { operatorSnapshot, refreshOperatorRoomDigest, refreshOperatorSnapshot } from './operator-store'
import { refreshMissionBriefing, refreshMissionSnapshot } from './mission-store'
import { refreshProofSnapshot } from './proof-store'
import {
  commandPlaneSurface,
  refreshCommandPlaneChainSummary,
  refreshCommandPlaneCurrentSurface,
  refreshCommandPlaneOrchestra,
  refreshCommandPlaneSwarm,
} from './command-store'

const buildIdentityOpen = signal(false)

function ConnectionStatus() {
  const isConnected = connected.value
  return html`
    <div class="connection-status ${isConnected ? 'connected' : 'disconnected'}">
      <span class="status-dot ${isConnected ? 'connected' : 'disconnected'}"></span>
      <span class="status-text">${isConnected ? 'Live' : '재연결 중...'}</span>
      <span class="event-count">${eventCount.value} events</span>
    </div>
  `
}

function shortCommit(commit: string | null | undefined): string {
  const value = commit?.trim()
  if (!value) return 'commit unavailable'
  return value.length > 10 ? value.slice(0, 10) : value
}

function BuildIdentityBadge() {
  const status = serverStatus.value
  const build = status?.build
  const label = build
    ? `v${build.release_version} · ${shortCommit(build.commit)}`
    : status?.version
      ? `v${status.version} · commit unavailable`
      : 'version unavailable'
  return html`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${buildIdentityOpen.value}
        onClick=${() => {
          buildIdentityOpen.value = !buildIdentityOpen.value
        }}
      >
        Server Build · ${label}
      </button>
      ${buildIdentityOpen.value
        ? html`
            <div class="build-badge-panel">
              <div class="build-badge-row">
                <span>릴리즈</span>
                <strong>${build?.release_version ?? status?.version ?? 'unknown'}</strong>
              </div>
              <div class="build-badge-row">
                <span>커밋</span>
                <strong>${build?.commit ?? 'commit unavailable'}</strong>
              </div>
              <div class="build-badge-row">
                <span>서버 시작</span>
                <strong>${build?.started_at ? html`<${TimeAgo} timestamp=${build.started_at} />` : 'unknown'}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof build?.uptime_seconds === 'number' ? `${build.uptime_seconds}s` : 'unknown'}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${status?.generated_at ? html`<${TimeAgo} timestamp=${status.generated_at} />` : 'unknown'}</strong>
              </div>
            </div>
          `
        : null}
    </div>
  `
}

function refreshForTab(tab: string) {
  if (tab === 'command') {
    refreshCommandPlaneCurrentSurface()
    refreshCommandPlaneChainSummary()
    if (commandPlaneSurface.value === 'swarm' || commandPlaneSurface.value === 'warroom' || commandPlaneSurface.value === 'orchestra') {
      refreshCommandPlaneSwarm()
    }
    if (commandPlaneSurface.value === 'orchestra') {
      refreshCommandPlaneOrchestra()
    }
    if (commandPlaneSurface.value === 'warroom') {
      refreshOperatorSnapshot()
    }
  }
  if (tab === 'mission') {
    refreshMissionSnapshot()
    refreshMissionBriefing()
  }
  if (tab === 'proof') {
    refreshProofSnapshot(route.value.params.session_id, route.value.params.operation_id)
  }
  if (tab === 'execution') refreshExecution()
  if (tab === 'intervene') {
    refreshOperatorSnapshot()
    refreshOperatorRoomDigest()
  }
  if (tab === 'memory') refreshBoard()
  if (tab === 'planning') refreshGoals()
  if (tab === 'lab') refreshTrpg()
}

function SnapshotCard({ currentTab }: { currentTab: string }) {
  const liveConnected = connected.value
  const build = serverStatus.value?.build
  const gardener = serverStatus.value?.gardener
  return html`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${PanelSemanticDetails} panelId="side_rail.snapshot" compact=${true} />
        <span class="rail-section-chip ${liveConnected ? 'ok' : 'bad'}">${liveConnected ? 'Live' : 'Offline'}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agent</span>
          <strong>${agents.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keeper</span>
          <strong>${keepers.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Task</span>
          <strong>${tasks.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Event</span>
          <strong>${eventCount.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${() => {
            refreshDashboard()
            refreshDashboardSemantics()
            refreshForTab(currentTab)
          }}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${() => navigate('intervene')}>
          개입 열기
        </button>
      </div>
      ${build
        ? html`<div class="rail-build-hint">Server Build · v${build.release_version} · ${shortCommit(build.commit)}</div>`
        : null}
      ${gardener ? html`
        <div style="margin-top:12px; padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
          <div class="rail-card-head" style="margin:0;">
            <h3 style="font-size:12px;">Gardener</h3>
            <span class="rail-section-chip ${gardener.alive ? 'ok' : gardener.enabled ? 'warn' : 'bad'}">
              ${gardener.alive ? 'Live' : gardener.enabled ? 'Starting' : 'Disabled'}
            </span>
          </div>
          <div class="build-badge-row">
            <span>Last tick</span>
            <strong>${gardener.last_tick_completed_at ? html`<${TimeAgo} timestamp=${gardener.last_tick_completed_at} />` : 'never'}</strong>
          </div>
          <div class="build-badge-row">
            <span>Decision</span>
            <strong>${gardener.last_intervention ?? 'none'} · ${gardener.last_decision_source ?? 'none'}</strong>
          </div>
          <div class="build-badge-row">
            <span>Action</span>
            <strong>${gardener.last_action ?? 'none'}</strong>
          </div>
          <div class="build-badge-row">
            <span>Backlog</span>
            <strong>${gardener.health_summary?.todo_count ?? 0} todo · P1/2 ${gardener.health_summary?.high_priority_todo ?? 0}</strong>
          </div>
          ${gardener.last_reason
            ? html`<div class="rail-build-hint">Reason · ${gardener.last_reason}</div>`
            : null}
          ${gardener.last_error
            ? html`<div class="rail-build-hint" style="color:#fca5a5;">Error · ${gardener.last_error}</div>`
            : null}
        </div>
      ` : null}
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
        <span class="rail-section-chip ${pendingConfirms > 0 ? 'warn' : 'ok'}">${pendingConfirms > 0 ? '확인 필요' : '정상'}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>확인 대기</span>
          <strong>${pendingConfirms}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Session</span>
          <strong>${sessionCount}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keeper</span>
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
          <h3>탐색</h3>
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
          <div class="rail-view-note-label">현재 화면</div>
          <strong>${currentView?.label ?? current}</strong>
          <p>${currentView?.description ?? '운영 화면'}</p>
        </div>
      </section>

      <${SnapshotCard} currentTab=${current} />
      <${InterveneRailCard} />
    </aside>
  `
}

function TabContent() {
  const tab = route.value.tab

  switch (tab) {
    case 'mission':
      return html`<${Mission} />`
    case 'proof':
      return html`<${Proof} />`
    case 'execution':
      return html`<${Execution} />`
    case 'live':
      return html`<${Live} />`
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
      refreshForTab(route.value.tab)
    }, 15000)
    return () => { clearInterval(interval) }
  }, [])

  useEffect(() => {
    refreshForTab(route.value.tab)
  }, [route.value.tab])

  const currentTab = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === currentTab)

  return html`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <${BuildIdentityBadge} />
          </h1>
          <p class="header-subtitle">${currentView?.description ?? '운영자 의사결정 및 실행 콘솔'}</p>
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
