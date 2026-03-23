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
  currentSectionForRoute,
  sectionItemsForTab,
} from '../config/navigation'
import { SnapshotCard } from './resident-runtime-rail'

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
        class="text-[11px] py-[6px] px-[11px] rounded-md border border-solid border-[rgba(71,184,255,0.28)] bg-[rgba(71,184,255,0.12)] text-[#bfe7ff] cursor-pointer font-[inherit] transition-colors duration-150 hover:bg-[rgba(71,184,255,0.18)]"
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
            <div class="absolute top-[calc(100%+10px)] right-0 min-w-[300px] py-3 px-3.5 border border-solid border-[var(--card-border)] rounded-lg bg-[rgba(6,14,28,0.97)] shadow-lg grid gap-2">
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



export function SideRail({ collapsed, onToggle }: { collapsed?: boolean; onToggle?: () => void }) {
  const currentTab = route.value.tab
  const currentSection = currentSectionForRoute(route.value)

  return html`
    <nav class="flex flex-col h-full">
      <div class="flex items-center ${collapsed ? 'justify-center' : 'justify-between'} px-3 pt-3 pb-1">
        ${!collapsed ? html`
          <div class="px-1">
            <div class="text-[10px] font-semibold uppercase tracking-[0.18em] text-[rgba(154,217,255,0.68)]">Navigation</div>
            <div class="mt-0.5 text-[14px] font-semibold tracking-[-0.02em] text-[var(--text-strong)]">MASC Core</div>
          </div>
        ` : null}
        <button
          class="flex size-7 items-center justify-center rounded-md text-[var(--text-muted)] hover:bg-[rgba(255,255,255,0.06)] hover:text-[var(--text-body)] cursor-pointer transition-colors duration-150"
          onClick=${onToggle}
          title=${collapsed ? '사이드바 펼치기' : '사이드바 접기'}
        >
          ${collapsed ? '\u25B6' : '\u25C0'}
        </button>
      </div>

      <div class="flex-1 overflow-y-auto ${collapsed ? 'px-1.5' : 'px-3'} py-3">
        <div class="flex flex-col gap-3">
          ${DASHBOARD_SURFACES.map(surface => {
            const isSurfaceActive = surface.id === currentTab
            const sections = sectionItemsForTab(surface.id)

            if (collapsed) {
              return html`
                <button
                  class="flex items-center justify-center w-full rounded-lg p-2 cursor-pointer transition-colors duration-150 ${isSurfaceActive ? 'bg-[rgba(71,184,255,0.14)] text-[#d9f2ff]' : 'text-[var(--text-muted)] hover:bg-[rgba(255,255,255,0.06)]'}"
                  onClick=${() => navigate(surface.defaultTab, surface.defaultParams)}
                  title=${surface.label}
                >
                  <span class="text-[16px]">${surface.icon}</span>
                </button>
              `
            }

            return html`
              <div class="flex flex-col gap-1">
                <button
                  class="flex items-center gap-2.5 w-full rounded-lg px-2.5 py-2 text-left cursor-pointer transition-colors duration-150 ${isSurfaceActive && sections.length === 0 ? 'bg-[rgba(71,184,255,0.14)] text-[#d9f2ff]' : 'bg-transparent text-[var(--text-strong)] hover:bg-[rgba(255,255,255,0.04)]'}"
                  onClick=${() => navigate(surface.defaultTab, surface.defaultParams)}
                >
                  <span class="flex h-7 w-7 shrink-0 items-center justify-center rounded-lg border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.04)] text-[14px]">
                    ${surface.icon}
                  </span>
                  <div class="flex-1 min-w-0">
                    <div class="text-[13px] font-semibold truncate leading-none ${isSurfaceActive ? 'text-[#9ad9ff]' : ''}">${surface.label}</div>
                  </div>
                </button>

                ${sections.length > 0 ? html`
                  <div class="flex flex-col gap-0.5 pl-10 pr-1">
                    ${sections.map(item => {
                      const isSectionActive = isSurfaceActive && currentSection?.id === item.id
                      return html`
                        <button
                          class="w-full rounded-md px-2.5 py-1.5 text-left cursor-pointer text-[12px] transition-colors duration-150 ${isSectionActive ? 'bg-[rgba(71,184,255,0.12)] text-[#cfeaff] font-medium' : 'text-[var(--text-muted)] hover:bg-[rgba(255,255,255,0.04)] hover:text-[var(--text-body)]'}"
                          onClick=${() => navigate(surface.id, item.params)}
                        >
                          <div class="truncate">${item.label}</div>
                        </button>
                      `
                    })}
                  </div>
                ` : null}
              </div>
            `
          })}
        </div>
      </div>

      ${!collapsed ? html`
        <div class="shrink-0 border-t border-[rgba(255,255,255,0.06)] p-3">
          <${SnapshotCard} currentTab=${currentTab} />
        </div>
      ` : null}
    </nav>
  `
}

export function TabContent() {
  const tab = route.value.tab

  switch (tab) {
    case 'overview':
      return html`<${Overview} />`
    case 'monitoring':
      return html`
        <${Suspense} fallback=${lazyTabFallback('모니터링 화면')}>
          <${LazyStatus} />
        <//>
      `
    case 'workspace':
      return html`
        <${Suspense} fallback=${lazyTabFallback('작업 화면')}>
          <${LazyWork} />
        <//>
      `
    case 'command':
      return html`
        <${Suspense} fallback=${lazyTabFallback('지휘 통제 화면')}>
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
      <div class="text-center py-[6px] px-4 bg-[rgba(230,167,0,0.12)] border-b border-solid border-b-[rgba(230,167,0,0.3)] text-[#e6a700] text-[0.8rem] shrink-0 rounded-xl mb-4">서버 데이터 준비 중 — 잠시 후 자동 갱신됩니다</div>
    ` : null}
    <${ErrorBoundary} key=${routeLabel} label=${routeLabel || 'dashboard'}>
      <${TabContent} />
    <//>
  `
}
