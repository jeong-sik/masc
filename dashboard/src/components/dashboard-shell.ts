import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { lazy, Suspense } from 'preact/compat'
import { route } from '../router'
import { connected, reconnectCount, lastDisconnectedAt } from '../sse'
import { dashboardLoading, serverStatus } from '../store'
import { missionSnapshot, missionLoading } from '../mission-store'
import { namespaceTruthInitializing } from '../namespace-truth-store'
import { Overview } from './overview/overview'
import { ErrorBoundary } from './common/error-boundary'
import { TimeAgo } from './common/time-ago'
import { LoadingState } from './common/feedback-state'
import {
  DASHBOARD_SURFACES,
  DASHBOARD_NAV_ITEMS,
  currentSectionForRoute,
  visibleSectionItemsForTab,
} from '../config/navigation'
import { RouteLink } from './common/route-link'
import { ObservatoryFilterBar } from './common/observatory-filter-bar'
import { ChevronRight, ChevronLeft } from 'lucide-preact'
import { CopyIdButton } from './common/copy-id-button'
import { formatElapsedCompact } from '../lib/format-time'

const buildIdentityOpen = signal(false)

const LazyStatus = lazy(async () => ({ default: (await import('./status')).Status }))
const LazyWork = lazy(async () => ({ default: (await import('./work')).Work }))
const LazyOperations = lazy(async () => ({ default: (await import('./control')).Operations }))
const LazyConnectors = lazy(async () => ({ default: (await import('./connector-status')).ConnectorStatusPanel }))
const LazyLabSurface = lazy(async () => ({ default: (await import('./lab')).Lab }))
const LazyLogViewer = lazy(async () => ({ default: (await import('./logs')).LogViewer }))

function lazyTabFallback(label: string) {
  return html`<${LoadingState}>${label} 불러오는 중...<//>`
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
    <div class="flex items-center gap-1.5 whitespace-nowrap text-[12px] ${isConnected ? 'text-[#9af3ba]' : 'text-[#f7b7b7]'}">
      <span class="inline-block size-[8px] rounded-full ${isConnected ? 'bg-[var(--ok)] shadow-[0_0_7px_rgba(74,222,128,0.75)]' : 'bg-[var(--bad)]'}"></span>
      <span class="status-text">${statusLabel}</span>
      ${attentionCount > 0 ? html`
        <${RouteLink}
          tab="overview"
          class="inline-flex items-center justify-center rounded-full border border-[var(--card-border)] bg-[var(--white-4)] px-2 py-0.5 tabular-nums attention-badge"
        >주의 ${attentionCount}건<//>
      ` : null}
    </div>
  `
}

function shortCommit(commit: string | null | undefined): string {
  const value = commit?.trim()
  if (!value) return 'dev'
  return value.length > 10 ? value.slice(0, 10) : value
}

/** Canonical upstream repo. Used to resolve commit-hash text into a
    clickable GitHub permalink. Hard-coded because this is the only
    origin the dashboard is ever built from — a future fork would
    override this via a build-time constant, not a runtime flag. */
const UPSTREAM_REPO = 'jeong-sik/masc-mcp'

/** Pure: turn a raw commit hash into a GitHub commit URL. Returns
    null for empty / non-hex-looking input so the dropdown renders
    the plain string for dev builds without creating a bogus link.
    Reference: Vercel / Railway / Render deployment dashboards always
    link commit hashes out to the source host — operators who land
    on the build identity dropdown usually want the diff, not the
    hash itself. */
export function githubCommitUrl(commit: string | null | undefined): string | null {
  const value = commit?.trim() ?? ''
  if (value === '') return null
  // Accept full (40-char) or short (≥ 7 char) hex SHAs only. Anything
  // else (dev labels, semver, free text) gets rendered as plain text
  // so we never produce a link to github.com/.../commit/dev.
  if (!/^[0-9a-f]{7,40}$/i.test(value)) return null
  return `https://github.com/${UPSTREAM_REPO}/commit/${value}`
}

/** Pure: render uptime seconds as a human-readable duration for the
    build-identity dropdown. Delegates to formatElapsedCompact ("3s",
    "5m 10s", "2h 30m"). Negative / NaN / non-number inputs return
    \"알 수 없음\" so the dropdown never prints \"NaNs\" or \"-5s\". */
export function formatUptimeSecondsHuman(
  seconds: number | null | undefined,
): string {
  if (typeof seconds !== 'number' || Number.isNaN(seconds) || seconds < 0) {
    return '알 수 없음'
  }
  return formatElapsedCompact(seconds)
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
      <button type="button"
        class="cursor-pointer rounded-full border border-[var(--white-10)] bg-[var(--white-4)] px-[10px] py-[5px] text-[10px] text-[var(--text-muted)] transition-colors duration-150 hover:border-[var(--accent-20)] hover:text-[var(--text-strong)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[rgba(71,184,255,0.45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-0)]"
        aria-expanded=${buildIdentityOpen.value}
        aria-label=${`서버 빌드 정보 ${label}`}
        title="서버 빌드 정보"
        onClick=${() => {
          buildIdentityOpen.value = !buildIdentityOpen.value
        }}
      >
        ${label}
      </button>
      ${buildIdentityOpen.value
        ? html`
            <div class="absolute top-[calc(100%+8px)] right-0 min-w-[280px] rounded-lg border border-solid border-[var(--card-border)] bg-[var(--bg-panel)] px-3 py-2.5 shadow-[0_10px_24px_rgba(0,0,0,0.22)] grid gap-1.5">
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>릴리즈</span>
                <strong class="text-[color:var(--text-strong)] text-right">${build?.release_version ?? status?.version ?? 'unknown'}</strong>
              </div>
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>커밋</span>
                ${(() => {
                  const url = githubCommitUrl(build?.commit)
                  const text = build?.commit ?? 'git 미감지 (dev)'
                  return url !== null
                    ? html`<a
                        href=${url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="text-right font-bold text-[color:var(--text-strong)] underline decoration-dotted underline-offset-2 decoration-[color:var(--text-dim)] hover:decoration-[color:var(--accent)] hover:text-[color:var(--accent)]"
                        data-build-commit-link
                        title="GitHub에서 이 커밋 보기"
                      >${text} ↗</a>`
                    : html`<strong class="text-[color:var(--text-strong)] text-right">${text}</strong>`
                })()}
              </div>
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>서버 시작</span>
                <strong class="text-[color:var(--text-strong)] text-right">${build?.started_at ? html`<${TimeAgo} timestamp=${build.started_at} />` : '알 수 없음'}</strong>
              </div>
              <div class="flex justify-between gap-3 text-xs text-[color:var(--text-muted)]">
                <span>업타임</span>
                <strong
                  class="text-[color:var(--text-strong)] text-right tabular-nums"
                  title=${typeof build?.uptime_seconds === 'number' ? `${build.uptime_seconds}s raw` : undefined}
                >${formatUptimeSecondsHuman(build?.uptime_seconds)}</strong>
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



function HealthIndicator({ collapsed }: { collapsed?: boolean }) {
  const live = connected.value
  const snap = missionSnapshot.value
  const sessions = snap?.sessions ?? []
  let blockers = 0
  for (let i = 0; i < sessions.length; i++) {
    if (sessions[i]?.blocker_summary) blockers++
  }
  const attentionCount = (snap?.attention_queue ?? []).length

  let dotClass: string
  let label: string

  if (!live) {
    dotClass = 'bg-[var(--bad)]'
    label = '신호 없음'
  } else if (!snap) {
    dotClass = 'bg-[var(--text-muted)]'
    label = missionLoading.value ? '로딩 중' : '대기 중'
  } else if (blockers > 0 || attentionCount > 0) {
    dotClass = 'bg-[var(--warn)]'
    const total = blockers + attentionCount
    label = `주의 ${total}건`
  } else {
    dotClass = 'bg-[var(--ok)]'
    label = '정상'
  }

  const dot = html`<span class="block size-2 shrink-0 rounded-full ${dotClass} shadow-[0_0_6px_rgba(0,0,0,0.4)]"></span>`

  if (collapsed) {
    return html`<div class="flex justify-center" title=${label} role="img" aria-label=${label}>${dot}</div>`
  }

  return html`
    <div class="flex items-center gap-2 px-1" role="status" aria-label=${label}>
      ${dot}
      <span class="text-[11px] text-[var(--text-muted)] truncate">${label}</span>
    </div>
  `
}

export function SideRail({ collapsed, onToggle }: { collapsed?: boolean; onToggle?: () => void }) {
  const currentTab = route.value.tab
  const currentSection = currentSectionForRoute(route.value)
  const visibleSurfaces = DASHBOARD_SURFACES.filter(surface => surface.hidden !== true)

  return html`
    <nav class="flex flex-col h-full" aria-label="Dashboard navigation">
      <div class="flex items-center ${collapsed ? 'justify-center' : 'justify-between'} px-2 pt-2 pb-1">
        ${!collapsed ? html`
          <div class="px-1">
            <div class="text-[10px] font-bold uppercase tracking-[0.2em] text-[var(--text-muted)]">내비게이션</div>
            <div class="mt-0.5 text-[13px] font-semibold tracking-[-0.02em] text-[var(--text-strong)]">MASC Core</div>
          </div>
        ` : null}
        <button type="button"
          class="flex size-7 items-center justify-center rounded-lg text-[var(--text-muted)] cursor-pointer transition-colors duration-200 hover:bg-[var(--white-10)] hover:text-[var(--text-strong)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[rgba(71,184,255,0.45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-1)]"
          aria-label=${collapsed ? '사이드바 펼치기' : '사이드바 접기'}
          onClick=${onToggle}
          title=${collapsed ? '사이드바 펼치기' : '사이드바 접기'}
        >
          ${collapsed ? html`<${ChevronRight} size=${16} />` : html`<${ChevronLeft} size=${16} />`}
        </button>
      </div>

      <div class="flex-1 overflow-y-auto px-2 py-1.5">
        <div class="flex flex-col gap-2">
          ${visibleSurfaces.map(surface => {
            const isSurfaceActive = surface.id === currentTab
            const sections = visibleSectionItemsForTab(surface.id)

            if (collapsed) {
              return html`
                <${RouteLink}
                  tab=${surface.defaultTab}
                  params=${surface.defaultParams}
                  class="flex items-center justify-center w-full rounded-xl border p-2 cursor-pointer transition-[background-color,border-color,color,box-shadow] duration-200 ${isSurfaceActive ? 'bg-[var(--accent-soft)] text-[var(--text-strong)] shadow-[inset_0_1px_1px_var(--white-10)] border-[var(--accent-20)]' : 'border-transparent text-[var(--text-muted)] hover:bg-[var(--white-5)]'}"
                  title=${surface.label}
                  aria-label=${surface.label}
                  ariaCurrent=${isSurfaceActive ? 'page' : undefined}
                >
                  <span class="text-[18px] drop-shadow-md" aria-hidden="true">${surface.icon}</span>
                <//>
              `
            }

            return html`
              <div class="flex flex-col gap-1">
                <${RouteLink}
                  tab=${surface.defaultTab}
                  params=${surface.defaultParams}
                  class="flex items-center gap-2 w-full rounded-lg border px-2 py-1.5 text-left cursor-pointer transition-[background-color,border-color,color,box-shadow] duration-200 ${isSurfaceActive && sections.length === 0 ? 'bg-[linear-gradient(135deg,rgba(71,184,255,0.14),rgba(71,184,255,0.04))] text-[var(--text-strong)] shadow-[inset_0_1px_1px_var(--white-10)] border-[var(--accent-20)]' : 'bg-transparent border-transparent text-[var(--text-strong)] hover:bg-[var(--white-5)]'}"
                  ariaCurrent=${isSurfaceActive && sections.length === 0 ? 'page' : undefined}
                >
                  <span class="flex h-7 w-7 shrink-0 items-center justify-center rounded-lg border border-[var(--white-10)] bg-[var(--white-3)] text-[14px]" aria-hidden="true">
                    ${surface.icon}
                  </span>
                  <div class="flex-1 min-w-0">
                    <div class="text-[14px] font-medium truncate leading-none ${isSurfaceActive ? 'text-[var(--accent)]' : ''}">${surface.label}</div>
                  </div>
                <//>

                ${sections.length > 0 ? html`
                  <div class="ml-7 flex flex-col gap-0.5 border-l border-[var(--border-subtle)] pl-3" role="list">
                    ${sections.map(item => {
                      const isSectionActive = isSurfaceActive && currentSection?.id === item.id
                      return html`
                        <${RouteLink}
                          role="listitem"
                          tab=${surface.id}
                          params=${item.params}
                          class="w-full rounded-lg border px-2 py-1 text-left cursor-pointer text-[13px] transition-[background-color,border-color,color,box-shadow] duration-200 ${isSectionActive ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium shadow-[inset_0_1px_1px_var(--white-10)] border-[var(--accent-soft)]' : 'border-transparent text-[var(--text-muted)] hover:bg-[var(--white-5)] hover:text-[var(--text-body)]'}"
                          ariaCurrent=${isSectionActive ? 'page' : undefined}
                        >
                          <div class="truncate">${item.label}</div>
                        <//>
                      `
                    })}
                  </div>
                ` : null}
              </div>
            `
          })}
        </div>
      </div>

      <div class="shrink-0 border-t border-[var(--white-10)] px-2 py-2">
        <${HealthIndicator} collapsed=${collapsed} />
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
        <${Suspense} fallback=${lazyTabFallback('운영 화면')}>
          <${LazyOperations} />
        <//>
      `
    case 'connectors':
      return html`
        <${Suspense} fallback=${lazyTabFallback('커넥터 화면')}>
          <${LazyConnectors} />
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

/** Pure: build the shareable URL for the current section. Uses
    window.location as the truth source (the router writes to it
    already) so we never diverge from what the browser address bar
    shows. Returns empty string when window is unavailable
    (SSR/happy-dom without location) so the caller can hide the
    share affordance gracefully. */
export function currentSectionShareUrl(): string {
  if (typeof window === 'undefined' || window.location === undefined) {
    return ''
  }
  return window.location.href
}

/** Pure: derive the navigation trail rendered above the section title.
    Each crumb is either a clickable ancestor (tab) or the terminal
    leaf (current section label, non-navigable). Returns a flat array:
    [] when both tab + section are absent (home / unknown),
    [tab] when only tab is active (no section drilldown),
    [tab, section] when the operator has drilled into a per-section view.

    Why this exists: SurfaceLead previously rendered only the leaf
    label (\"Discord\"). The parent tab (\"Connectors\") was implied by
    the left nav but not surfaced in the content area — a newcomer
    opening a deep link had to infer the hierarchy. Every modern web
    app (GitHub / Linear / Notion / Vercel) renders the trail above
    the page title for exactly this reason. */
export interface BreadcrumbCrumb {
  label: string
  navigableTab: string | null
}
export function deriveBreadcrumbTrail(
  tabLabel: string | null,
  sectionLabel: string | null,
  tabId: string | null,
): BreadcrumbCrumb[] {
  if (tabLabel === null && sectionLabel === null) return []
  if (sectionLabel === null) {
    return tabLabel !== null ? [{ label: tabLabel, navigableTab: null }] : []
  }
  if (tabLabel === null) {
    return [{ label: sectionLabel, navigableTab: null }]
  }
  // Drilldown view — tab becomes a clickable parent crumb, section is
  // the non-navigable leaf (you're already there, clicking it would
  // be a no-op).
  return [
    { label: tabLabel, navigableTab: tabId },
    { label: sectionLabel, navigableTab: null },
  ]
}


function SurfaceLead() {
  const currentTab = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === currentTab)
  const currentSection = currentSectionForRoute(route.value)

  const description = currentSection?.description ?? currentView?.description ?? null
  const title = currentSection?.label ?? currentView?.label ?? '홈'
  const shareUrl = currentSectionShareUrl()
  // Only surface a trail when the operator has drilled into a section —
  // otherwise the crumb would be \"Connectors\" right above a \"Connectors\"
  // title, pure duplication.
  const trail = currentSection !== null
    ? deriveBreadcrumbTrail(currentView?.label ?? null, currentSection.label, currentTab)
    : []

  return html`
    <div class="mb-3 flex flex-col gap-1.5">
      ${trail.length > 0
        ? html`<nav
            class="flex items-center gap-1 text-[11px] text-[var(--text-dim)]"
            aria-label="페이지 경로"
            data-surface-breadcrumb
          >
            ${trail.map((crumb, i) => {
              const isLast = i === trail.length - 1
              const sep = i > 0
                ? html`<span aria-hidden="true" class="text-[var(--white-10)]">›</span>`
                : null
              const crumbEl = crumb.navigableTab !== null && !isLast
                ? html`<${RouteLink}
                    tab=${crumb.navigableTab}
                    class="cursor-pointer rounded px-1 py-0.5 hover:bg-[var(--white-5)] hover:text-[var(--text-body)]"
                  >${crumb.label}<//>`
                : html`<span
                    class="px-1 py-0.5 ${isLast ? 'text-[var(--text-body)]' : ''}"
                    aria-current=${isLast ? 'page' : undefined}
                  >${crumb.label}</span>`
              return html`${sep}${crumbEl}`
            })}
          </nav>`
        : null}
      <div class="flex items-center gap-2">
        <h2 class="text-[22px] font-bold tracking-tight text-[var(--text-strong)]">
          ${title}
        </h2>
        ${shareUrl !== ''
          ? html`<${CopyIdButton}
              value=${shareUrl}
              label=${`섹션 링크 (${title})`}
              ariaLabel="현재 섹션 URL 복사"
              size=${14}
            />`
          : null}
      </div>
      ${description ? html`<p class="m-0 text-[13px] leading-[1.5] text-[var(--text-dim)]">${description}</p>` : null}
    </div>
  `
}

export function DashboardMain() {
  if (dashboardLoading.value && !connected.value && !namespaceTruthInitializing.value) {
    return html`<${LoadingState}>대시보드 불러오는 중...<//>`
  }

  const routeLabel = [
    route.value.tab,
    route.value.params.section,
    route.value.params.session_id,
    route.value.params.operation_id,
    route.value.params.worker_run_id,
  ]
    .filter(Boolean)
    .join(':')

  return html`
    ${namespaceTruthInitializing.value ? html`
      <div class="mb-3 shrink-0 rounded-xl border border-solid border-[rgba(230,167,0,0.22)] bg-[rgba(230,167,0,0.1)] px-4 py-1.5 text-center text-[0.78rem] text-[#e6a700]">서버 데이터 준비 중 — 잠시 후 자동 갱신됩니다</div>
    ` : null}
    <${SurfaceLead} />
    <${ObservatoryFilterBar} />
    <${ErrorBoundary} key=${routeLabel} label=${routeLabel || 'dashboard'}>
      <div class="animate-in fade-in slide-in-from-bottom-2 duration-300 fill-mode-both">
        <${TabContent} />
      </div>
    <//>
  `
}
