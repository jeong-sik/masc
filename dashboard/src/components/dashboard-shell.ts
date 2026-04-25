import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { lazy, Suspense } from 'preact/compat'
import { useEffect } from 'preact/hooks'
import { route } from '../router'
import { connected, reconnectCount, lastDisconnectedAt } from '../sse'
import { dashboardLoading, serverStatus } from '../store'
import { missionSnapshot, missionLoading } from '../mission-signals'
import { namespaceTruthInitializing } from '../namespace-truth-store'
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
import { ScrollToTopButton } from './common/scroll-to-top'
import { CopyIdButton } from './common/copy-id-button'
import { formatElapsedCompact } from '../lib/format-time'
import { unacknowledgedCount } from './common/error-notification-state'
import { ErrorPanel } from './common/error-panel'
import { Bell } from 'lucide-preact'

const buildIdentityOpen = signal(false)

const LazyOverview = lazy(async () => ({ default: (await import('./overview/overview')).Overview }))
const LazyStatus = lazy(async () => ({ default: (await import('./status')).Status }))
const LazyWork = lazy(async () => ({ default: (await import('./work')).Work }))
const LazyOperations = lazy(async () => ({ default: (await import('./control')).Operations }))
const LazyConnectors = lazy(async () => ({ default: (await import('./connector-status')).ConnectorStatusPanel }))
const LazyLabSurface = lazy(async () => ({ default: (await import('./lab')).Lab }))
const LazyLogViewer = lazy(async () => ({ default: (await import('./logs')).LogViewer }))

function lazyTabFallback(label: string) {
  return html`<${LoadingState}>${label} 불러오는 중...<//>`
}

/** Pure: describe a "reconnecting" state as a user-facing label plus
    tooltip. Reference UIs: Discord shows "Reconnecting... (5s · try 3)";
    Slack shows "Trying to reconnect..." with timestamp on hover;
    Linear flashes a subtle red dot + tooltip. Goal here: operator can
    tell at a glance whether a flicker (sub-5s) is worth noticing and,
    on hover, see when the last successful session ended + cumulative
    reconnect count — so a reconnect loop is diagnosable without
    opening devtools.

    Inputs are all primitives so the helper is trivially testable. */
export function describeReconnecting(args: {
  disconnectedAt: number
  now: number
  reconnects: number
}): { label: string; title: string } {
  const { disconnectedAt, now, reconnects } = args
  if (disconnectedAt === 0) {
    return { label: '재연결 중...', title: '' }
  }
  const sec = Math.max(0, Math.round((now - disconnectedAt) / 1000))
  const elapsed = sec < 5
    ? ''
    : sec < 60
      ? ` · ${sec}s`
      : ` · ${Math.round(sec / 60)}m`
  const label = `재연결 중${elapsed}`
  const titleParts: string[] = []
  if (sec >= 5) {
    const d = new Date(disconnectedAt)
    const pad = (n: number) => String(n).padStart(2, '0')
    const when = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
    titleParts.push(`연결 끊김 ${when}`)
  }
  if (reconnects > 0) {
    titleParts.push(`누적 재연결 ${reconnects}회`)
  }
  return { label, title: titleParts.join(' · ') }
}

export function ConnectionStatus() {
  const isConnected = connected.value
  const snap = missionSnapshot.value
  const attentionCount = snap?.attention_queue?.length ?? 0
  const reconn = reconnectCount.value

  const statusLabel = isConnected
    ? reconn > 0 ? '재연결됨' : '연결됨'
    : describeReconnecting({
        disconnectedAt: lastDisconnectedAt.value,
        now: Date.now(),
        reconnects: reconn,
      }).label
  const titleAttr = isConnected
    ? reconn > 0 ? `누적 재연결 ${reconn}회` : ''
    : describeReconnecting({
        disconnectedAt: lastDisconnectedAt.value,
        now: Date.now(),
        reconnects: reconn,
      }).title

  return html`
    <div
      class="flex items-center gap-1.5 whitespace-nowrap text-xs ${isConnected ? 'text-[#9af3ba]' : 'text-[#f7b7b7]'}"
      title=${titleAttr || undefined}
    >
      <span class="inline-block size-[8px] rounded-sm ${isConnected ? 'bg-[var(--ok)] shadow-[0_0_7px_rgba(74,222,128,0.75)]' : 'bg-[var(--bad)]'}"></span>
      <span class="status-text">${statusLabel}</span>
      ${attentionCount > 0 ? html`
        <${RouteLink}
          tab="overview"
          class="inline-flex items-center justify-center rounded-sm border border-[var(--card-border)] bg-[var(--white-4)] px-2 py-0.5 tabular-nums attention-badge"
        >주의 ${attentionCount}건<//>
      ` : null}
    </div>
  `
}

const errorPanelOpen = signal(false)

export function ErrorCounterBadge() {
  const count = unacknowledgedCount.value
  const open = errorPanelOpen.value

  return html`
    <div class="relative" role="status">
      <button type="button"
        class="flex items-center gap-1.5 cursor-pointer rounded px-1 py-0.5 transition-colors hover:bg-[var(--white-5)] ${count > 0 ? 'text-[var(--bad)]' : 'text-[var(--text-muted)]'}"
        title=${count > 0 ? `미확인 에러 ${count}건` : '에러 없음'}
        aria-label=${count > 0 ? `미확인 에러 ${count}건` : '에러 없음'}
        onClick=${() => { errorPanelOpen.value = !errorPanelOpen.value }}
        aria-expanded=${open}
        aria-haspopup="true"
      >
        <${Bell} size=${14} aria-hidden="true" />
        ${count > 0 ? html`
          <span class="inline-flex items-center justify-center min-w-4 h-4 px-1 rounded-full bg-[var(--bad)] text-2xs font-semibold text-white tabular-nums">${count > 99 ? '99+' : count}</span>
        ` : null}
      </button>
      ${open ? html`<${ErrorPanel} onClose=${() => { errorPanelOpen.value = false }} />` : null}
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


/** Pure: compose a multi-line native-title tooltip for the build
    identity badge so hovering reveals version + commit + uptime
    without needing to open the dropdown. Reference UIs: Vercel
    deployment pill, Render build badge, Railway service chip — all
    surface the one-glance summary on hover and reserve the click for
    \"deep details\". \n renders verbatim in native tooltips. */
export function composeBuildBadgeTitle(
  build: { release_version?: string | null; commit?: string | null; uptime_seconds?: number | null } | null | undefined,
  fallbackVersion: string | null | undefined,
): string {
  if (!build && !fallbackVersion) return '버전 정보 없음'
  const lines: string[] = ['서버 빌드']
  const version = build?.release_version ?? fallbackVersion
  if (version != null && version !== '') {
    const commit = build?.commit != null && build.commit !== ''
      ? ` · ${shortCommit(build.commit)}`
      : ' · dev'
    lines.push(`  · v${version}${commit}`)
  }
  const uptime = formatUptimeSecondsHuman(build?.uptime_seconds)
  if (uptime !== '알 수 없음') {
    lines.push(`  · 업타임 ${uptime}`)
  }
  lines.push('  · 클릭하여 상세 보기')
  return lines.join('\n')
}

export function BuildIdentityBadge() {
  const status = serverStatus.value
  const build = status?.build
  const label = build
    ? `v${build.release_version} · ${shortCommit(build.commit)}`
    : status?.version
      ? `v${status.version} · dev`
      : '버전 정보 없음'
  const hoverTitle = composeBuildBadgeTitle(build, status?.version)

  return html`
    <div class="relative">
      <button type="button"
        class="cursor-pointer rounded-sm border border-[var(--white-10)] bg-[var(--white-4)] px-2.5 py-[5px] text-3xs text-[var(--text-muted)] transition-colors duration-150 hover:border-[var(--accent-20)] hover:text-[var(--text-strong)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-0)]"
        aria-expanded=${buildIdentityOpen.value}
        aria-label=${`서버 빌드 정보 ${label}`}
        title=${hoverTitle}
        onClick=${() => {
          buildIdentityOpen.value = !buildIdentityOpen.value
        }}
      >
        ${label}
      </button>
      ${buildIdentityOpen.value
        ? html`
            <div class="absolute top-[calc(100%+8px)] right-0 min-w-70 rounded border border-solid border-[var(--card-border)] bg-[var(--bg-panel)] px-3 py-2.5 shadow-[0_10px_24px_rgba(0,0,0,0.22)] grid gap-1.5">
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



/** Pure: gather the top-N attention-item summaries as tooltip lines so
    hovering the bottom-left health dot answers "what are the N
    things?" without a click. Reference UIs: Datadog monitor rollup
    tooltip, Vercel deployment status footer, Gmail "2 unread" with
    sender preview — all reveal the contributing items on hover so the
    operator decides whether to navigate. Exposed for tests. */
export function summarizeAttentionPreview(
  items: ReadonlyArray<{ summary?: string | null; kind?: string | null }>,
  max = 3,
): string[] {
  // Two-pass: first filter to valid (non-empty summary or kind), then
  // cap. This separates "skipped for noise" from "truncated for max"
  // so the tail count only reflects genuinely pending items that
  // didn't fit — never padding from null/empty rows.
  const valid: string[] = []
  for (const item of items) {
    if (!item) continue
    const summary = item.summary?.trim()
    const kind = item.kind?.trim()
    const raw = (summary && summary !== '') ? summary : (kind && kind !== '' ? kind : '')
    if (raw === '') continue
    valid.push(raw.length > 60 ? `${raw.slice(0, 57)}...` : raw)
  }
  if (valid.length <= max) return valid
  return [...valid.slice(0, max), `… 외 ${valid.length - max}건`]
}

/** Pure: compose the full title-attribute string for the health
    indicator — label on the first line, attention previews indented
    under it. Newlines render in native title tooltips on all major
    browsers, so no HTML escaping or markup is needed. */
export function composeHealthIndicatorTitle(
  label: string,
  attentionLines: ReadonlyArray<string>,
): string {
  if (attentionLines.length === 0) return label
  const indented = attentionLines.map(line => `  · ${line}`)
  return [label, ...indented].join('\n')
}

function HealthIndicator({ collapsed }: { collapsed?: boolean }) {
  const live = connected.value
  const snap = missionSnapshot.value
  const sessions = snap?.sessions ?? []
  let blockers = 0
  for (let i = 0; i < sessions.length; i++) {
    if (sessions[i]?.blocker_summary) blockers++
  }
  const attentionQueue = snap?.attention_queue ?? []
  const attentionCount = attentionQueue.length

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

  const attentionLines = attentionCount > 0 ? summarizeAttentionPreview(attentionQueue) : []
  const titleText = composeHealthIndicatorTitle(label, attentionLines)

  const dot = html`<span class="block size-2 shrink-0 rounded-sm ${dotClass} shadow-[0_0_6px_rgba(0,0,0,0.4)]"></span>`

  if (collapsed) {
    return html`<div class="flex justify-center" title=${titleText} role="img" aria-label=${label}>${dot}</div>`
  }

  return html`
    <div class="flex items-center gap-2 px-1" role="status" aria-label=${label} title=${titleText}>
      ${dot}
      <span class="text-2xs text-[var(--text-muted)] truncate">${label}</span>
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
            <div class="text-3xs font-bold uppercase tracking-[0.2em] text-[var(--text-muted)]">내비게이션</div>
            <div class="mt-0.5 text-sm font-semibold tracking-[-0.02em] text-[var(--text-strong)]">MASC Core</div>
          </div>
        ` : null}
        <button type="button"
          class="flex size-7 items-center justify-center rounded text-[var(--text-muted)] cursor-pointer transition-colors duration-200 hover:bg-[var(--white-10)] hover:text-[var(--text-strong)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-1)]"
          aria-label=${collapsed ? '사이드바 펼치기' : '사이드바 접기'}
          onClick=${onToggle}
          title=${collapsed ? '사이드바 펼치기' : '사이드바 접기'}
        >
          ${collapsed ? html`<${ChevronRight} size=${16} />` : html`<${ChevronLeft} size=${16} />`}
        </button>
      </div>

      <div class="flex-1 overflow-y-auto custom-scrollbar px-2 py-1.5">
        <div class="flex flex-col gap-2">
          ${visibleSurfaces.map(surface => {
            const isSurfaceActive = surface.id === currentTab
            const sections = visibleSectionItemsForTab(surface.id)

            if (collapsed) {
              return html`
                <${RouteLink}
                  tab=${surface.defaultTab}
                  params=${surface.defaultParams}
                  class="flex items-center justify-center w-full rounded border p-2 cursor-pointer transition-[background-color,border-color,color,box-shadow] duration-200 ${isSurfaceActive ? 'bg-[var(--accent-soft)] text-[var(--text-strong)] shadow-[inset_0_1px_1px_var(--white-10)] border-[var(--accent-20)]' : 'border-transparent text-[var(--text-muted)] hover:bg-[var(--white-5)]'}"
                  title=${surface.label}
                  aria-label=${surface.label}
                  ariaCurrent=${isSurfaceActive ? 'page' : undefined}
                >
                  <span class="text-xl drop-shadow-sm" aria-hidden="true">${surface.icon}</span>
                <//>
              `
            }

            return html`
              <div class="flex flex-col gap-1">
                <${RouteLink}
                  tab=${surface.defaultTab}
                  params=${surface.defaultParams}
                  class="flex items-center gap-2 w-full rounded border px-2 py-1.5 text-left cursor-pointer transition-[background-color,border-color,color,box-shadow] duration-200 ${isSurfaceActive && sections.length === 0 ? 'bg-[linear-gradient(135deg,rgba(71,184,255,0.14),rgba(71,184,255,0.04))] text-[var(--text-strong)] shadow-[inset_0_1px_1px_var(--white-10)] border-[var(--accent-20)]' : 'bg-transparent border-transparent text-[var(--text-strong)] hover:bg-[var(--white-5)]'}"
                  ariaCurrent=${isSurfaceActive && sections.length === 0 ? 'page' : undefined}
                >
                  <span class="flex h-7 w-7 shrink-0 items-center justify-center rounded border border-[var(--white-10)] bg-[var(--white-3)] text-base" aria-hidden="true">
                    ${surface.icon}
                  </span>
                  <div class="flex-1 min-w-0">
                    <div class="text-base font-medium truncate leading-none ${isSurfaceActive ? 'text-[var(--accent)]' : ''}" title=${surface.label}>${surface.label}</div>
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
                          class="w-full rounded border px-2 py-1 text-left cursor-pointer text-sm transition-[background-color,border-color,color,box-shadow] duration-200 ${isSectionActive ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium shadow-[inset_0_1px_1px_var(--white-10)] border-[var(--accent-soft)]' : 'border-transparent text-[var(--text-muted)] hover:bg-[var(--white-5)] hover:text-[var(--text-body)]'}"
                          ariaCurrent=${isSectionActive ? 'page' : undefined}
                        >
                          <div class="truncate" title=${item.label}>${item.label}</div>
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

function TabContent() {
  const tab = route.value.tab

  switch (tab) {
    case 'overview':
      return html`
        <${Suspense} fallback=${lazyTabFallback('개요 화면')}>
          <${LazyOverview} />
        <//>
      `
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
      return html`
        <${Suspense} fallback=${lazyTabFallback('개요 화면')}>
          <${LazyOverview} />
        <//>
      `
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
interface BreadcrumbCrumb {
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


/** Pure: compose the browser tab title from the current surface +
    section. Reference: every polished SPA (GitHub / Linear / Notion /
    Vercel) sets document.title so operators with multiple tabs open
    can distinguish them from the browser's tab list. Without this,
    4 dashboard tabs all say \"MASC Dashboard\" — users lose track.

    Format: \"MASC · {section}\" when drilled into a section,
            \"MASC · {tab}\" when on a tab default,
            \"MASC Dashboard\" on home / unknown (original fallback). */
export function composeDocumentTitle(
  tabLabel: string | null,
  sectionLabel: string | null,
): string {
  const leaf = sectionLabel ?? tabLabel
  if (leaf === null || leaf.trim() === '') return 'MASC Dashboard'
  return `MASC · ${leaf}`
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

  // Sync document.title — syncing to an external system (the browser
  // tab title) is a legitimate useEffect. Keyed on the two labels so
  // the effect only re-runs on actual navigation, not every render.
  useEffect(() => {
    document.title = composeDocumentTitle(currentView?.label ?? null, currentSection?.label ?? null)
  }, [currentView?.label, currentSection?.label])

  return html`
    <div class="mb-3 flex flex-col gap-1.5">
      ${trail.length > 0
        ? html`<nav
            class="flex items-center gap-1 text-2xs text-[var(--text-dim)]"
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
      ${description ? html`<p class="m-0 text-sm leading-normal text-[var(--text-dim)]">${description}</p>` : null}
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
      <div class="mb-3 shrink-0 rounded border border-solid border-[rgba(230,167,0,0.22)] bg-[rgba(230,167,0,0.1)] px-4 py-1.5 text-center text-[0.78rem] text-[#e6a700]">서버 데이터 준비 중 — 잠시 후 자동 갱신됩니다</div>
    ` : null}
    <${SurfaceLead} />
    <${ObservatoryFilterBar} />
    <${ErrorBoundary} key=${routeLabel} label=${routeLabel || 'dashboard'}>
      <div class="animate-in fade-in slide-in-from-bottom-2 duration-300 fill-mode-both">
        <${TabContent} />
      </div>
    <//>
    <${ScrollToTopButton} />
  `
}
