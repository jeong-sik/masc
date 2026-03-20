import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { lazy, Suspense } from 'preact/compat'
import { route, navigate } from '../router'
import { connected } from '../sse'
import { dashboardLoading, serverStatus } from '../store'
import { missionSnapshot } from '../mission-store'
import { roomTruthInitializing } from '../room-truth-store'
import { Mission } from './mission'
import { Overview } from './overview/overview'
import { ErrorBoundary } from './common/error-boundary'
import { TimeAgo } from './common/time-ago'
import { PanelSemanticDetails } from './common/semantic-layer'
import {
  DASHBOARD_NAV_ITEMS,
  DASHBOARD_SURFACES,
  surfaceForTab,
} from '../config/navigation'
import { InterveneRailCard, SnapshotCard } from './resident-runtime-rail'

const buildIdentityOpen = signal(false)

const LazyAgentsUnified = lazy(async () => ({ default: (await import('./agents-unified')).AgentsUnified }))
const LazyActivity = lazy(async () => ({ default: (await import('./activity')).Activity }))
const LazyWork = lazy(async () => ({ default: (await import('./work')).Work }))
const LazyControl = lazy(async () => ({ default: (await import('./control')).Control }))
const LazyLabUnified = lazy(async () => ({ default: (await import('./lab-unified')).LabUnified }))

function lazyTabFallback(label: string) {
  return html`<div class="loading-indicator">${label} 불러오는 중...</div>`
}

export function ConnectionStatus() {
  const isConnected = connected.value
  const snap = missionSnapshot.value
  const attentionCount = snap?.attention_queue?.length ?? 0

  return html`
    <div class="connection-status ${isConnected ? 'connected' : 'disconnected'}">
      <span class="status-dot ${isConnected ? 'connected' : 'disconnected'}"></span>
      <span class="status-text">${isConnected ? '연결됨' : '재연결 중...'}</span>
      ${attentionCount > 0 ? html`
        <span
          class="event-count attention-badge"
          onClick=${() => navigate('home')}
          style="cursor: pointer;"
        >주의 ${attentionCount}건</span>
      ` : null}
    </div>
  `
}

function shortCommit(commit: string | null | undefined): string {
  const value = commit?.trim()
  if (!value) return '커밋 정보 없음'
  return value.length > 10 ? value.slice(0, 10) : value
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

export function SideRail() {
  const current = route.value.tab
  const currentSurface = surfaceForTab(current)
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === current)

  return html`
    <aside class="dashboard-rail">
      <section class="rail-card rail-card-compact">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${PanelSemanticDetails} panelId="side_rail.navigate" compact=${true} />
        </div>

        <!-- Primary surfaces (5 items) -->
        <div class="rail-tab-list">
          ${DASHBOARD_SURFACES.map(surface => {
            const isActive = surface.id === currentSurface
            return html`
              <button
                class="rail-tab-btn ${isActive ? 'active' : ''}"
                key=${surface.id}
                onClick=${() => navigate(surface.defaultTab)}
              >
                <span class="rail-tab-icon">${surface.icon}</span>
                <span class="rail-tab-copy">
                  <strong>${surface.label}</strong>
                  <span>${surface.description}</span>
                </span>
              </button>
            `
          })}
        </div>

        <!-- Sub-tabs within current surface -->
        ${(() => {
          const activeSurface = DASHBOARD_SURFACES.find(s => s.id === currentSurface)
          if (!activeSurface || activeSurface.tabs.length <= 1) return null
          const subItems = DASHBOARD_NAV_ITEMS.filter(item =>
            activeSurface.tabs.includes(item.id) && item.id !== 'home'
          )
          if (subItems.length === 0) return null
          return html`
            <div class="rail-nav-group" style="margin-top: 12px;">
              <div class="rail-group-label">${activeSurface.label} 하위</div>
              <div class="rail-tab-list" style="margin-top: 6px;">
                ${subItems.map(item => html`
                  <button
                    class="rail-tab-btn ${current === item.id ? 'active' : ''}"
                    key=${item.id}
                    onClick=${() => navigate(item.id)}
                    style="padding: 8px 10px;"
                  >
                    <span class="rail-tab-icon" style="font-size: 14px;">${item.icon}</span>
                    <span class="rail-tab-copy">
                      <strong style="font-size: 12px;">${item.label}</strong>
                    </span>
                  </button>
                `)}
              </div>
            </div>
          `
        })()}

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
    case 'home':
      return html`<${Overview} />`
    case 'situation':
      return html`<${Mission} />`
    case 'agents':
      return html`
        <${Suspense} fallback=${lazyTabFallback('에이전트 화면')}>
          <${LazyAgentsUnified} />
        <//>
      `
    case 'activity':
      return html`
        <${Suspense} fallback=${lazyTabFallback('활동 화면')}>
          <${LazyActivity} />
        <//>
      `
    case 'work':
      return html`
        <${Suspense} fallback=${lazyTabFallback('작업 화면')}>
          <${LazyWork} />
        <//>
      `
    case 'control':
      return html`
        <${Suspense} fallback=${lazyTabFallback('제어 화면')}>
          <${LazyControl} />
        <//>
      `
    case 'lab':
      return html`
        <${Suspense} fallback=${lazyTabFallback('실험실 화면')}>
          <${LazyLabUnified} />
        <//>
      `
    default:
      return html`<${Overview} />`
  }
}

export function DashboardMain() {
  if (roomTruthInitializing.value) {
    return html`<div class="loading-indicator">서버가 데이터를 준비하고 있습니다. 잠시 후 자동으로 새로고침됩니다...</div>`
  }
  if (dashboardLoading.value && !connected.value) {
    return html`<div class="loading-indicator">대시보드 불러오는 중...</div>`
  }

  const routeLabel = [
    route.value.tab,
    route.value.params.section,
    route.value.params.surface,
    route.value.params.session_id,
    route.value.params.operation_id,
  ]
    .filter(Boolean)
    .join(':')

  return html`
    <${ErrorBoundary} key=${routeLabel} label=${routeLabel || 'dashboard'}>
      <${TabContent} />
    <//>
  `
}
