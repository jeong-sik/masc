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
  return html`<div class="loading-state loading-pulse">${label} 불러오는 중...</div>`
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
    <div class="flex items-center gap-2 text-[length:var(--fs-sm)] whitespace-nowrap ${isConnected ? 'text-[#9af3ba]' : 'text-[#f7b7b7]'}">
      <span class="size-[9px] rounded-full inline-block ${isConnected ? 'bg-[var(--ok)] shadow-[0_0_9px_rgba(74,222,128,0.8)]' : 'bg-[var(--bad)]'}"></span>
      <span class="status-text">${statusLabel}</span>
      ${attentionCount > 0 ? html`
        <span
          class="inline-flex items-center justify-center py-0.5 px-2 min-w-[80px] border border-solid border-[var(--card-border)] bg-[var(--white-4)] tabular-nums rounded-full attention-badge cursor-pointer"
          onClick=${() => navigate('home')}
        >주의 ${attentionCount}건</span>
      ` : null}
    </div>
  `
}

function shortCommit(commit: string | null | undefined): string {
  const value = commit?.trim()
  if (!value) return 'dev'
  return value.length > 10 ? value.slice(0, 10) : value
}

export function BuildIdentityBadge() {
  const status = serverStatus.value
  const build = status?.build
  const label = build
    ? `v${build.release_version} · ${shortCommit(build.commit)}`
    : status?.version
      ? `v${status.version} · dev`
      : '버전 정보 없음'

  return html`
    <div class="relative">
      <button
        class="text-[11px] py-[2px] px-[9px] rounded-full border border-solid border-[rgba(71,184,255,0.35)] bg-[var(--accent-soft)] text-[#9ad9ff] cursor-pointer font-[inherit]"
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
            <div class="absolute top-[calc(100%+10px)] left-0 min-w-[280px] py-3 px-3.5 border border-solid border-[var(--card-border)] rounded-[var(--radius-md)] bg-[rgba(10,18,34,0.96)] shadow-[0_18px_34px_rgba(0,0,0,0.34)] grid gap-2">
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>릴리즈</span>
                <strong class="text-[color:var(--text-strong)] text-right">${build?.release_version ?? status?.version ?? 'unknown'}</strong>
              </div>
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>커밋</span>
                <strong class="text-[color:var(--text-strong)] text-right">${build?.commit ?? 'git 미감지 (dev)'}</strong>
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
    <nav class="flex flex-col h-full">
      <!-- Navigation -->
      <div class="flex-1 overflow-y-auto py-4 px-3">
        <div class="text-[10px] font-medium text-[var(--text-muted)] uppercase tracking-[0.1em] px-2 mb-2">탐색</div>

        <div class="flex flex-col gap-1">
          ${DASHBOARD_SURFACES.map(surface => {
            const isActive = surface.id === currentSurface
            return html`
              <button
                class="w-full flex items-center gap-2.5 px-2.5 py-2 rounded-lg text-left cursor-pointer border-l-2 border-t-0 border-r-0 border-b-0 border-solid transition-all duration-150 ${isActive ? 'border-l-[var(--accent)] bg-[var(--accent-soft)] text-[var(--accent)]' : 'border-l-transparent bg-transparent text-[var(--text-body)] hover:bg-[var(--white-6)] hover:border-l-[var(--white-20)]'}"
                key=${surface.id}
                onClick=${() => navigate(surface.defaultTab, surface.defaultParams)}
              >
                <span class="text-sm w-5 text-center shrink-0">${surface.icon}</span>
                <span class="text-[13px] font-medium truncate">${surface.label}</span>
              </button>
            `
          })}
        </div>

        <!-- Sub-sections -->
        ${(() => {
          if (sectionItems.length === 0) return null
          return html`
            <div class="mt-5 pt-4 mx-4 border-t border-[var(--border-slate-12)]">
              <div class="text-[10px] font-medium text-[var(--text-muted)] uppercase tracking-[0.1em] px-2 mb-2">${currentView?.label ?? currentSurface}</div>
              <div class="flex flex-col gap-1">
                ${sectionItems.map(item => html`
                  <button
                    class="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-md text-left cursor-pointer border-l-2 border-t-0 border-r-0 border-b-0 border-solid text-[13px] transition-all duration-150 ${currentSection?.id === item.id ? 'border-l-[var(--accent)] bg-[var(--accent-soft)] text-[var(--accent)] font-medium' : 'border-l-transparent bg-transparent text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)]'}"
                    key=${item.id}
                    onClick=${() => navigate(currentSurface, item.params)}
                  >
                    ${item.label}
                  </button>
                `)}
              </div>
            </div>
          `
        })()}
      </div>

      <!-- Status Footer -->
      <div class="shrink-0 border-t border-[var(--border-slate-12)] p-3">
        <${SnapshotCard} currentTab=${current} />
      </div>
    </nav>
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
    return html`<div class="loading-state loading-pulse">대시보드 불러오는 중...</div>`
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
