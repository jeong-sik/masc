import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { lazy, Suspense } from 'preact/compat'
import { route, navigate } from '../router'
import { connected, reconnectCount, lastDisconnectedAt } from '../sse'
import { dashboardLoading, serverStatus } from '../store'
import { missionSnapshot } from '../mission-store'
import { roomTruthInitializing } from '../room-truth-store'
import { Overview } from './overview/overview'
import { ErrorBoundary } from './common/error-boundary'
import { TimeAgo } from './common/time-ago'
import {
  DASHBOARD_SURFACES,
  DASHBOARD_NAV_ITEMS,
  currentSectionForRoute,
  sectionItemsForTab,
  surfaceForTab,
} from '../config/navigation'
import { InterveneRailCard, SnapshotCard } from './resident-runtime-rail'

const buildIdentityOpen = signal(false)

const LazyStatus = lazy(async () => ({ default: (await import('./status')).Status }))
const LazyWork = lazy(async () => ({ default: (await import('./work')).Work }))
const LazyOperations = lazy(async () => ({ default: (await import('./control')).Operations }))
const LazyLabSurface = lazy(async () => ({ default: (await import('./lab-unified')).LabSurface }))
const LazyLogViewer = lazy(async () => ({ default: (await import('./logs')).LogViewer }))

function lazyTabFallback(label: string) {
  return html`<div class="text-center border border-dashed border-[var(--card-border)] rounded-xl py-12 px-4 text-[color:var(--text-muted)]">${label} 불러오는 중...</div>`
}

function formatDisconnectDuration(): string {
  const ts = lastDisconnectedAt.value
  if (ts === 0) return ''
  const sec = Math.round((Date.now() - ts) / 1000)
  if (sec < 5) return ''
  if (sec < 60) return ` (${sec}s)`
  return ` (${Math.round(sec / 60)}m)`
}

export function ConnectionStatus() {
  const isConnected = connected.value
  const snap = missionSnapshot.value
  const attentionCount = snap?.attention_queue?.length ?? 0
  const reconn = reconnectCount.value

  const statusLabel = isConnected
    ? reconn > 0 ? '재연결됨' : '연결됨'
    : `재연결 중...${formatDisconnectDuration()}`

  return html`
    <div class="flex items-center gap-2 text-[length:var(--fs-sm)] text-[color:var(--text-muted)] whitespace-nowrap connection-status ${isConnected ? 'connected' : 'disconnected'}">
      <span class="size-[9px] rounded-full inline-block status-dot ${isConnected ? 'connected' : 'disconnected'}"></span>
      <span class="status-text">${statusLabel}</span>
      ${attentionCount > 0 ? html`
        <span
          class="event-count rounded-full attention-badge cursor-pointer"
          onClick=${() => navigate('home')}
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
    <div class="relative">
      <button
        class="text-[11px] py-[2px] px-[9px] rounded-full border border-solid border-[rgba(71,184,255,0.35)] bg-[var(--accent-soft)] text-[#9ad9ff] build-badge-trigger"
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
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>릴리즈</span>
                <strong class="text-[color:var(--text-strong)] text-right">${build?.release_version ?? status?.version ?? 'unknown'}</strong>
              </div>
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>커밋</span>
                <strong class="text-[color:var(--text-strong)] text-right">${build?.commit ?? '커밋 정보 없음'}</strong>
              </div>
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>서버 시작</span>
                <strong class="text-[color:var(--text-strong)] text-right">${build?.started_at ? html`<${TimeAgo} timestamp=${build.started_at} />` : '알 수 없음'}</strong>
              </div>
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>업타임</span>
                <strong class="text-[color:var(--text-strong)] text-right">${typeof build?.uptime_seconds === 'number' ? `${build.uptime_seconds}s` : '알 수 없음'}</strong>
              </div>
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>쉘 스냅샷</span>
                <strong class="text-[color:var(--text-strong)] text-right">${status?.generated_at ? html`<${TimeAgo} timestamp=${status.generated_at} />` : '알 수 없음'}</strong>
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
  const currentSection = currentSectionForRoute(route.value)
  const sectionItems = sectionItemsForTab(current)

  return html`
    <aside class="dashboard-rail">
      <section class="rail-card rounded-xl py-2.5 px-3">
        <div class="flex items-center justify-between gap-3">
          <h3 class="mb-0">탐색</h3>
        </div>

        <!-- Primary surfaces (5 items) -->
        <div class="rail-tab-list grid grid-cols-1 gap-1.5">
          ${DASHBOARD_SURFACES.map(surface => {
            const isActive = surface.id === currentSurface
            return html`
              <button
                class="rail-tab-btn ${isActive ? 'active' : ''}"
                key=${surface.id}
                onClick=${() => navigate(surface.defaultTab, surface.defaultParams)}
              >
                <span class="text-base leading-[1.2]">${surface.icon}</span>
                <span class="min-w-0 grid gap-0.5">
                  <strong class="text-[color:var(--text-strong)] text-[13px] leading-[1.3]">${surface.label}</strong>
                  <span class="text-[color:var(--text-muted)] text-[11px] leading-[1.4]">${surface.description}</span>
                </span>
              </button>
            `
          })}
        </div>

        <!-- Sub-tabs within current surface -->
        ${(() => {
          if (sectionItems.length === 0) return null
          return html`
            <div class="rail-nav-group mt-3">
              <div class="rail-group-label">${currentView?.label ?? currentSurface} 하위</div>
              <div class="rail-tab-list grid grid-cols-1 gap-1.5 mt-1.5">
                ${sectionItems.map(item => html`
                  <button
                    class="rail-tab-btn py-2 px-2.5 ${currentSection?.id === item.id ? 'active' : ''}"
                    key=${item.id}
                    onClick=${() => navigate(currentSurface, item.params)}
                  >
                    <span class="min-w-0 grid gap-0.5">
                      <strong class="text-[color:var(--text-strong)] text-xs leading-[1.3]">${item.label}</strong>
                      <span class="text-[color:var(--text-muted)] text-[11px] leading-[1.4]">${item.description}</span>
                    </span>
                  </button>
                `)}
              </div>
            </div>
          `
        })()}

        <div class="mt-3.5 pt-2.5 border-t border-[var(--card-border)] grid gap-1">
          <div class="text-[color:var(--text-muted)] text-[11px] tracking-[0.06em] uppercase">현재 화면</div>
          <strong class="text-[color:var(--text-strong)] text-sm">${currentSection ? `${currentView?.label ?? current} · ${currentSection.label}` : currentView?.label ?? current}</strong>
          <p class="text-[color:var(--text-muted)] text-xs leading-[1.45]">${currentSection?.description ?? currentView?.description ?? '운영 화면'}</p>
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
    case 'status':
      return html`
        <${Suspense} fallback=${lazyTabFallback('현황 화면')}>
          <${LazyStatus} />
        <//>
      `
    case 'work':
      return html`
        <${Suspense} fallback=${lazyTabFallback('작업 화면')}>
          <${LazyWork} />
        <//>
      `
    case 'operations':
      return html`
        <${Suspense} fallback=${lazyTabFallback('운영 화면')}>
          <${LazyOperations} />
        <//>
      `
    case 'lab':
      return html`
        <${Suspense} fallback=${lazyTabFallback('실험실 화면')}>
          <${LazyLabSurface} />
        <//>
      `
    case 'logs':
      return html`
        <${Suspense} fallback=${lazyTabFallback('시스템 로그')}>
          <${LazyLogViewer} />
        <//>
      `
    default:
      return html`<${Overview} />`
  }
}

export function DashboardMain() {
  if (dashboardLoading.value && !connected.value && !roomTruthInitializing.value) {
    return html`<div class="text-center border border-dashed border-[var(--card-border)] rounded-xl py-12 px-4 text-[color:var(--text-muted)]">대시보드 불러오는 중...</div>`
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
    ${roomTruthInitializing.value ? html`
      <div class="text-center py-[6px] px-4 bg-[rgba(230,167,0,0.12)] border-b border-solid border-b-[rgba(230,167,0,0.3)] text-[#e6a700] text-[0.8rem] shrink-0">서버 데이터 준비 중 — 잠시 후 자동 갱신됩니다</div>
    ` : null}
    <${ErrorBoundary} key=${routeLabel} label=${routeLabel || 'dashboard'}>
      <${TabContent} />
    <//>
  `
}
