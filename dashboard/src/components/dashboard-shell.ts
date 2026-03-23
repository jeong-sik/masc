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
        class="text-[11px] py-[6px] px-[11px] rounded-full border border-solid border-[rgba(71,184,255,0.28)] bg-[rgba(71,184,255,0.12)] text-[#bfe7ff] cursor-pointer font-[inherit] shadow-[inset_0_1px_0_rgba(255,255,255,0.05)] transition-colors duration-150 hover:bg-[rgba(71,184,255,0.18)]"
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
            <div class="absolute top-[calc(100%+10px)] right-0 min-w-[300px] py-3 px-3.5 border border-solid border-[var(--card-border)] rounded-[18px] bg-[rgba(6,14,28,0.97)] shadow-[0_24px_44px_rgba(0,0,0,0.36)] grid gap-2">
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

function SurfaceLead() {
  const currentTab = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === currentTab)
  const currentSection = currentSectionForRoute(route.value)
  const activeSectionCount = sectionItemsForTab(currentTab).length

  return html`
    <section class="mb-5 overflow-hidden rounded-[26px] border border-[rgba(138,163,211,0.16)] bg-[linear-gradient(135deg,rgba(9,22,42,0.96),rgba(6,12,24,0.92))] px-5 py-5 shadow-[inset_0_1px_0_rgba(255,255,255,0.04)]">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0 max-w-[820px]">
          <div class="flex flex-wrap items-center gap-2">
            ${currentView?.icon
              ? html`<span class="inline-flex h-9 w-9 items-center justify-center rounded-2xl border border-[rgba(71,184,255,0.18)] bg-[rgba(71,184,255,0.08)] text-[18px]">${currentView.icon}</span>`
              : null}
            <span class="text-[10px] font-semibold uppercase tracking-[0.22em] text-[rgba(154,217,255,0.72)]">Current Surface</span>
            ${currentSection && currentSection.label !== currentView?.label
              ? html`<span class="rounded-full border border-[rgba(255,255,255,0.12)] bg-[rgba(255,255,255,0.05)] px-2 py-0.5 text-[10px] font-medium text-[var(--text-muted)]">${currentSection.label}</span>`
              : null}
          </div>
          <h2 class="mt-3 text-[28px] font-semibold tracking-[-0.04em] text-[var(--text-strong)]">
            ${currentSection?.label ?? currentView?.label ?? '홈'}
          </h2>
          <p class="mt-2 max-w-[72ch] text-[13px] leading-relaxed text-[var(--text-muted)]">
            ${currentSection?.description ?? currentView?.description ?? '지금 필요한 신호를 가장 안정적으로 읽을 수 있는 기본 화면입니다.'}
          </p>
        </div>

        <div class="grid min-w-[240px] gap-2 rounded-[22px] border border-[rgba(255,255,255,0.07)] bg-[rgba(255,255,255,0.04)] p-3">
          <div class="flex items-center justify-between gap-3 text-[11px] text-[var(--text-muted)]">
            <span>현재 탭</span>
            <strong class="text-[var(--text-strong)]">${currentView?.label ?? currentTab}</strong>
          </div>
          <div class="flex items-center justify-between gap-3 text-[11px] text-[var(--text-muted)]">
            <span>하위 섹션</span>
            <strong class="text-[var(--text-strong)] tabular-nums">${activeSectionCount}</strong>
          </div>
          <div class="flex items-center justify-between gap-3 text-[11px] text-[var(--text-muted)]">
            <span>연결 상태</span>
            <strong class="${connected.value ? 'text-[#91f2b4]' : 'text-[#f7b7b7]'}">${connected.value ? 'live' : 'reconnecting'}</strong>
          </div>
        </div>
      </div>
    </section>
  `
}

export function SideRail() {
  const currentTab = route.value.tab
  const currentSection = currentSectionForRoute(route.value)

  return html`
    <nav class="flex flex-col h-full">
      <div class="flex-1 overflow-y-auto px-3 py-4">
        <div class="mb-4 px-3">
          <div class="text-[10px] font-semibold uppercase tracking-[0.18em] text-[rgba(154,217,255,0.68)]">Navigation</div>
          <div class="mt-1 text-[15px] font-semibold tracking-[-0.02em] text-[var(--text-strong)]">MASC Core</div>
        </div>

        <div class="flex flex-col gap-4">
          ${DASHBOARD_SURFACES.map(surface => {
            const isSurfaceActive = surface.id === currentTab
            const sections = sectionItemsForTab(surface.id)

            return html`
              <div class="flex flex-col gap-1">
                <button
                  class="flex items-center gap-3 w-full rounded-[14px] px-3 py-2.5 text-left cursor-pointer transition-all duration-150 ${isSurfaceActive && sections.length === 0 ? 'bg-[rgba(71,184,255,0.14)] text-[#d9f2ff] shadow-[inset_0_1px_0_rgba(255,255,255,0.03)]' : 'bg-transparent text-[var(--text-strong)] hover:bg-[rgba(255,255,255,0.04)]'}"
                  onClick=${() => navigate(surface.defaultTab, surface.defaultParams)}
                >
                  <span class="flex h-7 w-7 shrink-0 items-center justify-center rounded-xl border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.04)] text-[14px]">
                    ${surface.icon}
                  </span>
                  <div class="flex-1 min-w-0">
                    <div class="text-[13px] font-semibold truncate leading-none ${isSurfaceActive ? 'text-[#9ad9ff]' : ''}">${surface.label}</div>
                  </div>
                </button>
                
                ${sections.length > 0 ? html`
                  <div class="flex flex-col gap-0.5 pl-11 pr-2">
                    ${sections.map(item => {
                      const isSectionActive = isSurfaceActive && currentSection?.id === item.id
                      return html`
                        <button
                          class="w-full rounded-[10px] px-3 py-2 text-left cursor-pointer text-[12px] transition-all duration-150 ${isSectionActive ? 'bg-[rgba(71,184,255,0.12)] text-[#cfeaff] font-medium' : 'text-[var(--text-muted)] hover:bg-[rgba(255,255,255,0.04)] hover:text-[var(--text-body)]'}"
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

      <div class="shrink-0 border-t border-[rgba(255,255,255,0.06)] p-3">
        <${SnapshotCard} currentTab=${currentTab} />
      </div>
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
      <div class="text-center py-[6px] px-4 bg-[rgba(230,167,0,0.12)] border-b border-solid border-b-[rgba(230,167,0,0.3)] text-[#e6a700] text-[0.8rem] shrink-0">서버 데이터 준비 중 — 잠시 후 자동 갱신됩니다</div>
    ` : null}
    <${SurfaceLead} />
    <${ErrorBoundary} key=${routeLabel} label=${routeLabel || 'dashboard'}>
      <${TabContent} />
    <//>
  `
}
