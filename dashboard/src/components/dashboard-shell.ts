import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { signal } from '@preact/signals'
import { route, navigate } from '../router'
import { connected, eventCount } from '../sse'
import {
  refreshDashboard,
  refreshDashboardSemantics,
  dashboardLoading,
  agents,
  tasks,
  keepers,
  serverStatus,
} from '../store'
import { refreshForTab } from '../tab-refresh'
import { Mission } from './mission'
import { Proof } from './proof'
import { Command } from './command'
import { Ops } from './ops'
import { Memory } from './memory'
import { Execution } from './agents'
import { Planning } from './goals'
import { Governance } from './governance'
import { Lab } from './lab'
import { Live } from './live'
import { TimeAgo } from './common/time-ago'
import { PanelSemanticDetails, SurfaceSemanticIntro } from './common/semantic-layer'
import { DASHBOARD_NAV_ITEMS, DASHBOARD_NAV_SECTIONS } from '../config/navigation'
import { operatorSnapshot, refreshOperatorRoomDigest, refreshOperatorSnapshot } from '../operator-store'

const buildIdentityOpen = signal(false)

export function ConnectionStatus() {
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

export function BuildIdentityBadge() {
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

function renderRuntimeStat(label: string, value: ComponentChildren) {
  return html`
    <div class="build-badge-row">
      <span>${label}</span>
      <strong>${value}</strong>
    </div>
  `
}

function renderResidentRuntimeCard(
  title: string,
  statusLabel: string,
  tone: 'ok' | 'warn' | 'bad',
  rows: ComponentChildren[],
  hint?: ComponentChildren,
) {
  return html`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${title}</h3>
        <span class="rail-section-chip ${tone}">${statusLabel}</span>
      </div>
      ${rows}
      ${hint ? html`<div class="rail-build-hint">${hint}</div>` : null}
    </div>
  `
}

function SnapshotCard({ currentTab }: { currentTab: string }) {
  const liveConnected = connected.value
  const build = serverStatus.value?.build
  const lodge = serverStatus.value?.lodge
  const gardener = serverStatus.value?.gardener
  const guardian = serverStatus.value?.guardian
  const sentinel = serverStatus.value?.sentinel
  const residentCards: ComponentChildren[] = []

  if (lodge) {
    residentCards.push(
      renderResidentRuntimeCard(
        'Lodge',
        lodge.enabled ? (lodge.quiet_active ? 'Quiet' : 'Live') : 'Disabled',
        lodge.enabled ? (lodge.quiet_active ? 'warn' : 'ok') : 'bad',
        [
          renderRuntimeStat('Ticks', lodge.total_ticks ?? 0),
          renderRuntimeStat('Checkins', lodge.total_checkins ?? 0),
          renderRuntimeStat(
            'Last result',
            lodge.last_tick_result?.activity_report ?? lodge.last_skip_reason ?? 'none',
          ),
        ],
      ),
    )
  }

  if (gardener) {
    residentCards.push(
      renderResidentRuntimeCard(
        'Gardener',
        gardener.alive ? 'Live' : gardener.enabled ? 'Starting' : 'Disabled',
        gardener.alive ? 'ok' : gardener.enabled ? 'warn' : 'bad',
        [
          renderRuntimeStat(
            'Last tick',
            gardener.last_tick_completed_at
              ? html`<${TimeAgo} timestamp=${gardener.last_tick_completed_at} />`
              : 'never',
          ),
          renderRuntimeStat(
            'Decision',
            `${gardener.last_intervention ?? 'none'} · ${gardener.last_decision_source ?? 'none'}`,
          ),
          renderRuntimeStat(
            'Backlog',
            `${gardener.health_summary?.todo_count ?? 0} todo · P1/2 ${gardener.health_summary?.high_priority_todo ?? 0}`,
          ),
        ],
        gardener.last_reason ?? gardener.last_error ?? undefined,
      ),
    )
  }

  if (guardian) {
    const guardianLive = guardian.masc_loops_running || guardian.lodge_loop_started || guardian.lodge_running
    residentCards.push(
      renderResidentRuntimeCard(
        'Guardian',
        guardianLive ? 'Live' : guardian.enabled ? 'Idle' : 'Disabled',
        guardianLive ? 'ok' : guardian.enabled ? 'warn' : 'bad',
        [
          renderRuntimeStat('Mode', guardian.mode ?? 'unknown'),
          renderRuntimeStat(
            'Loops',
            `zombie ${guardian.zombie_loop_running ? 'on' : 'off'} · gc ${guardian.gc_loop_running ? 'on' : 'off'}`,
          ),
          renderRuntimeStat('Owner', guardian.runtime_owner ?? 'none'),
        ],
        guardian.last_lodge_result?.message
          ?? guardian.last_gc_result
          ?? guardian.last_zombie_result
          ?? undefined,
      ),
    )
  }

  if (sentinel) {
    residentCards.push(
      renderResidentRuntimeCard(
        'Sentinel',
        sentinel.started ? 'Live' : sentinel.enabled ? 'Starting' : 'Disabled',
        sentinel.started ? 'ok' : sentinel.enabled ? 'warn' : 'bad',
        [
          renderRuntimeStat('Agent', sentinel.agent_name ?? 'sentinel'),
          renderRuntimeStat('Consumers', sentinel.consumers?.length ?? 0),
          renderRuntimeStat('Guardian owner', sentinel.guardian_runtime_owner ?? 'none'),
        ],
        sentinel.llm_enabled === true ? 'LLM-enabled housekeeping resident' : undefined,
      ),
    )
  }

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
      ${residentCards.length > 0
        ? html`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${residentCards}
            </div>
          `
        : null}
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

export function SideRail() {
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

export function TabContent() {
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

export function DashboardMain() {
  return dashboardLoading.value && !connected.value
    ? html`<div class="loading-indicator">Loading dashboard...</div>`
    : html`<${TabContent} />`
}
