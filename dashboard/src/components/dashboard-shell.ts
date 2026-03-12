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
      <span class="status-text">${isConnected ? '연결됨' : '재연결 중...'}</span>
      <span class="event-count">이벤트 ${eventCount.value}</span>
    </div>
  `
}

function shortCommit(commit: string | null | undefined): string {
  const value = commit?.trim()
  if (!value) return '커밋 정보 없음'
  return value.length > 10 ? value.slice(0, 10) : value
}

function residentStatusLabel(
  kind: 'lodge' | 'gardener' | 'guardian' | 'sentinel',
  status: 'live' | 'quiet' | 'starting' | 'idle' | 'disabled',
) {
  if (status === 'live') return '가동 중'
  if (status === 'quiet') return '조용함'
  if (status === 'starting') return '기동 중'
  if (status === 'idle') return kind === 'guardian' ? '유휴' : '대기 중'
  return '비활성'
}

export function BuildIdentityBadge() {
  const status = serverStatus.value
  const build = status?.build
  const label = build
    ? `v${build.release_version} · ${shortCommit(build.commit)}`
    : status?.version
      ? `v${status.version} · 커밋 정보 없음`
      : '버전 정보 없음'

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
        서버 빌드 · ${label}
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
                <strong>${build?.commit ?? '커밋 정보 없음'}</strong>
              </div>
              <div class="build-badge-row">
                <span>서버 시작</span>
                <strong>${build?.started_at ? html`<${TimeAgo} timestamp=${build.started_at} />` : '알 수 없음'}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof build?.uptime_seconds === 'number' ? `${build.uptime_seconds}s` : '알 수 없음'}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${status?.generated_at ? html`<${TimeAgo} timestamp=${status.generated_at} />` : '알 수 없음'}</strong>
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
        lodge.enabled
          ? residentStatusLabel('lodge', lodge.quiet_active ? 'quiet' : 'live')
          : residentStatusLabel('lodge', 'disabled'),
        lodge.enabled ? (lodge.quiet_active ? 'warn' : 'ok') : 'bad',
        [
          renderRuntimeStat('틱', lodge.total_ticks ?? 0),
          renderRuntimeStat('체크인', lodge.total_checkins ?? 0),
          renderRuntimeStat(
            '최근 결과',
            lodge.last_tick_result?.activity_report ?? lodge.last_skip_reason ?? '없음',
          ),
        ],
      ),
    )
  }

  if (gardener) {
    residentCards.push(
      renderResidentRuntimeCard(
        'Gardener',
        gardener.alive
          ? residentStatusLabel('gardener', 'live')
          : gardener.enabled
            ? residentStatusLabel('gardener', 'starting')
            : residentStatusLabel('gardener', 'disabled'),
        gardener.alive ? 'ok' : gardener.enabled ? 'warn' : 'bad',
        [
          renderRuntimeStat(
            '최근 tick',
            gardener.last_tick_completed_at
              ? html`<${TimeAgo} timestamp=${gardener.last_tick_completed_at} />`
              : '기록 없음',
          ),
          renderRuntimeStat(
            '판단',
            `${gardener.last_intervention ?? '없음'} · ${gardener.last_decision_source ?? '없음'}`,
          ),
          renderRuntimeStat(
            '백로그',
            `미할당 ${gardener.health_summary?.todo_count ?? 0} · P1/2 ${gardener.health_summary?.high_priority_todo ?? 0}`,
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
        guardianLive
          ? residentStatusLabel('guardian', 'live')
          : guardian.enabled
            ? residentStatusLabel('guardian', 'idle')
            : residentStatusLabel('guardian', 'disabled'),
        guardianLive ? 'ok' : guardian.enabled ? 'warn' : 'bad',
        [
          renderRuntimeStat('모드', guardian.mode ?? '알 수 없음'),
          renderRuntimeStat(
            '루프',
            `zombie ${guardian.zombie_loop_running ? 'on' : 'off'} · gc ${guardian.gc_loop_running ? 'on' : 'off'}`,
          ),
          renderRuntimeStat('소유자', guardian.runtime_owner ?? '없음'),
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
        sentinel.started
          ? residentStatusLabel('sentinel', 'live')
          : sentinel.enabled
            ? residentStatusLabel('sentinel', 'starting')
            : residentStatusLabel('sentinel', 'disabled'),
        sentinel.started ? 'ok' : sentinel.enabled ? 'warn' : 'bad',
        [
          renderRuntimeStat('에이전트', sentinel.agent_name ?? 'sentinel'),
          renderRuntimeStat('소비자', sentinel.consumers?.length ?? 0),
          renderRuntimeStat('가디언 소유자', sentinel.guardian_runtime_owner ?? '없음'),
        ],
        sentinel.llm_enabled === true ? 'LLM 기반 housekeeping resident' : undefined,
      ),
    )
  }

  return html`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${PanelSemanticDetails} panelId="side_rail.snapshot" compact=${true} />
        <span class="rail-section-chip ${liveConnected ? 'ok' : 'bad'}">${liveConnected ? '연결됨' : '오프라인'}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>에이전트</span>
          <strong>${agents.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>키퍼</span>
          <strong>${keepers.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>태스크</span>
          <strong>${tasks.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>이벤트</span>
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
        ? html`<div class="rail-build-hint">서버 빌드 · v${build.release_version} · ${shortCommit(build.commit)}</div>`
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
          <span>키퍼</span>
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
    ? html`<div class="loading-indicator">대시보드 불러오는 중...</div>`
    : html`<${TabContent} />`
}
