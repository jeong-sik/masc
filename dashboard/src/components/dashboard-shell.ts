import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { lazy, Suspense } from 'preact/compat'
import { useEffect } from 'preact/hooks'
import type { RouteState } from '../types'
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
import { ringFocusClasses } from './common/ring'
import { SurfaceIcon } from './surface-icon'

const buildIdentityOpen = signal(false)

function BuildInfoRow({ label, children }: { label: string; children: unknown }) {
  return html`
    <div class="flex justify-between gap-3 text-xs text-[color:var(--color-fg-muted)]">
      <span>${label}</span>
      ${children}
    </div>
  `
}

const LazyOverview = lazy(async () => ({ default: (await import('./overview/overview')).Overview }))
const LazyStatus = lazy(async () => ({ default: (await import('./status')).Status }))
const LazyWork = lazy(async () => ({ default: (await import('./work')).Work }))
const LazyOperations = lazy(async () => ({ default: (await import('./control')).Operations }))
const LazyConnectors = lazy(async () => ({ default: (await import('./connector-status')).ConnectorStatusPanel }))
const LazyLabSurface = lazy(async () => ({ default: (await import('./lab')).Lab }))
const LazyLogViewer = lazy(async () => ({ default: (await import('./logs')).LogViewer }))
const LazyIdeShell = lazy(async () => ({ default: (await import('./ide/ide-shell')).IdeShell }))

function lazyTabFallback(label: string) {
  return html`<${LoadingState}>Loading ${label}...<//>`
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
    return { label: 'Reconnecting...', title: '' }
  }
  const sec = Math.max(0, Math.round((now - disconnectedAt) / 1000))
  const elapsed = sec < 5
    ? ''
    : sec < 60
      ? ` · ${sec}s`
      : ` · ${Math.round(sec / 60)}m`
  const label = `Reconnecting${elapsed}`
  const titleParts: string[] = []
  if (sec >= 5) {
    const d = new Date(disconnectedAt)
    const pad = (n: number) => String(n).padStart(2, '0')
    const when = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
    titleParts.push(`Disconnected at ${when}`)
  }
  if (reconnects > 0) {
    titleParts.push(`Reconnect attempts ${reconnects}`)
  }
  return { label, title: titleParts.join(' · ') }
}

export function ConnectionStatus() {
  const isConnected = connected.value
  const snap = missionSnapshot.value
  const attentionCount = snap?.attention_queue?.length ?? 0
  const reconn = reconnectCount.value

  const statusLabel = isConnected
    ? reconn > 0 ? 'Reconnected' : 'Connected'
    : describeReconnecting({
        disconnectedAt: lastDisconnectedAt.value,
        now: Date.now(),
        reconnects: reconn,
      }).label
  const titleAttr = isConnected
    ? reconn > 0 ? `Reconnect attempts ${reconn}` : ''
    : describeReconnecting({
        disconnectedAt: lastDisconnectedAt.value,
        now: Date.now(),
        reconnects: reconn,
      }).title

  return html`
    <div
      class="flex items-center gap-1.5 whitespace-nowrap text-xs ${isConnected ? 'text-[var(--color-status-ok)]' : 'text-[var(--color-status-err)]'}"
      title=${titleAttr || undefined}
    >
      <span class="inline-block size-[8px] rounded-sm ${isConnected ? 'bg-[var(--color-status-ok)] shadow-[0_0_7px_rgb(var(--ok-glow)/0.75)]' : 'bg-[var(--color-status-err)]'}"></span>
      <span class="status-text">${statusLabel}</span>
      ${attentionCount > 0 ? html`
        <${RouteLink}
          tab="overview"
          class="inline-flex items-center justify-center rounded-sm border border-[var(--color-border-default)] bg-[var(--white-4)] px-2 py-0.5 tabular-nums attention-badge"
        >Attention ${attentionCount}<//>
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
      <button
        type="button"
        class="flex items-center gap-1.5 cursor-pointer rounded px-1 py-0.5 transition-colors hover:bg-[var(--white-5)] ${count > 0 ? 'text-[var(--color-status-err)]' : 'text-[var(--color-fg-muted)]'}"
        title=${count > 0 ? `${count} unacknowledged errors` : 'No errors'}
        onClick=${() => { errorPanelOpen.value = !errorPanelOpen.value }}
        aria-expanded=${open}
        aria-haspopup="true"
      >
        <${Bell} size=${14} />
        ${count > 0 ? html`
          <span class="inline-flex items-center justify-center min-w-4 h-4 px-1 rounded-full bg-[var(--color-status-err)] text-2xs font-semibold text-white tabular-nums">${count > 99 ? '99+' : count}</span>
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
    "Unknown" so the dropdown never prints "NaNs" or "-5s". */
export function formatUptimeSecondsHuman(
  seconds: number | null | undefined,
): string {
  if (typeof seconds !== 'number' || Number.isNaN(seconds) || seconds < 0) {
    return 'Unknown'
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
  if (!build && !fallbackVersion) return 'Build unavailable'
  const lines: string[] = ['Server build']
  const version = build?.release_version ?? fallbackVersion
  if (version != null && version !== '') {
    const commit = build?.commit != null && build.commit !== ''
      ? ` · ${shortCommit(build.commit)}`
      : ' · dev'
    lines.push(`  · v${version}${commit}`)
  }
  const uptime = formatUptimeSecondsHuman(build?.uptime_seconds)
  if (uptime !== 'Unknown') {
    lines.push(`  · Uptime ${uptime}`)
  }
  lines.push('  · Click for details')
  return lines.join('\n')
}

export function BuildIdentityBadge() {
  const status = serverStatus.value
  const build = status?.build
  const label = build
    ? `v${build.release_version} · ${shortCommit(build.commit)}`
    : status?.version
      ? `v${status.version} · dev`
      : 'Build unavailable'
  const hoverTitle = composeBuildBadgeTitle(build, status?.version)

  return html`
    <div class="relative">
      <button type="button"
        class=${`cursor-pointer rounded-sm border border-[var(--white-10)] bg-[var(--white-4)] px-2.5 py-[5px] text-3xs text-[var(--color-fg-muted)] transition-colors duration-150 hover:border-[var(--accent-20)] hover:text-[var(--color-fg-secondary)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
        aria-expanded=${buildIdentityOpen.value}
        aria-label=${`Server build ${label}`}
        title=${hoverTitle}
        onClick=${() => {
          buildIdentityOpen.value = !buildIdentityOpen.value
        }}
      >
        ${label}
      </button>
      ${buildIdentityOpen.value
        ? html`
            <div class="absolute top-[calc(100%+8px)] right-0 min-w-70 rounded-[var(--r-1)] border border-solid border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2.5 shadow-xl grid gap-1.5">
              <${BuildInfoRow} label="Release">
                <strong class="text-[color:var(--color-fg-secondary)] text-right">${build?.release_version ?? status?.version ?? 'unknown'}</strong>
              <//>
              <${BuildInfoRow} label="Commit">
                ${(() => {
                  const url = githubCommitUrl(build?.commit)
                  const text = build?.commit ?? 'git not detected (dev)'
                  return url !== null
                    ? html`<a
                        href=${url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="text-right font-bold text-[color:var(--color-fg-secondary)] underline decoration-dotted underline-offset-2 decoration-[color:var(--color-fg-disabled)] hover:decoration-[color:var(--color-accent-fg)] hover:text-[color:var(--color-accent-fg)]"
                        data-build-commit-link
                        title="View this commit on GitHub"
                      >${text} ↗</a>`
                    : html`<strong class="text-[color:var(--color-fg-secondary)] text-right">${text}</strong>`
                })()}
              <//>
              <${BuildInfoRow} label="Server started">
                <strong class="text-[color:var(--color-fg-secondary)] text-right">${build?.started_at ? html`<${TimeAgo} timestamp=${build.started_at} />` : 'Unknown'}</strong>
              <//>
              <${BuildInfoRow} label="Uptime">
                <strong
                  class="text-[color:var(--color-fg-secondary)] text-right tabular-nums"
                  title=${typeof build?.uptime_seconds === 'number' ? `${build.uptime_seconds}s raw` : undefined}
                >${formatUptimeSecondsHuman(build?.uptime_seconds)}</strong>
              <//>
              <${BuildInfoRow} label="Shell snapshot">
                <strong class="text-[color:var(--color-fg-secondary)] text-right">${status?.generated_at ? html`<${TimeAgo} timestamp=${status.generated_at} />` : 'Unknown'}</strong>
              <//>
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
  return [...valid.slice(0, max), `... +${valid.length - max} more`]
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

export function dashboardRouteBoundaryKey(routeState: RouteState): string {
  const params = routeState.params
  const parts = [
    routeState.tab,
    params.section,
    params.view ? `view=${params.view}` : '',
    params.session_id ? `session=${params.session_id}` : '',
    params.operation_id ? `operation=${params.operation_id}` : '',
    params.worker_run_id ? `worker=${params.worker_run_id}` : '',
  ]

  if (routeState.tab === 'monitoring' && params.section === 'agents') {
    parts.push(
      params.agent ? `agent=${params.agent}` : '',
      params.keeper ? `keeper=${params.keeper}` : '',
    )
  }

  return parts.filter(Boolean).join(':')
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
    dotClass = 'bg-[var(--color-status-err)]'
    label = 'Offline'
  } else if (!snap) {
    dotClass = 'bg-[var(--color-fg-muted)]'
    label = missionLoading.value ? 'Loading' : 'Idle'
  } else if (blockers > 0 || attentionCount > 0) {
    dotClass = 'bg-[var(--color-status-warn)]'
    const total = blockers + attentionCount
    label = `Attention ${total}`
  } else {
    dotClass = 'bg-[var(--color-status-ok)]'
    label = 'Healthy'
  }

  const attentionLines = attentionCount > 0 ? summarizeAttentionPreview(attentionQueue) : []
  const titleText = composeHealthIndicatorTitle(label, attentionLines)

  const dot = html`<span class="block size-2 shrink-0 rounded-sm ${dotClass} shadow-sm"></span>`

  if (collapsed) {
    return html`<div class="flex justify-center" title=${titleText} role="img" aria-label=${label}>${dot}</div>`
  }

  return html`
    <div class="flex items-center gap-2 px-1" role="status" aria-label=${label} title=${titleText}>
      ${dot}
      <span class="text-2xs text-[var(--color-fg-muted)] truncate">${label}</span>
    </div>
  `
}

export function SideRail({ collapsed, onToggle }: { collapsed?: boolean; onToggle?: () => void }) {
  const currentTab = route.value.tab
  const currentSection = currentSectionForRoute(route.value)
  const visibleSurfaces = DASHBOARD_SURFACES.filter(surface => surface.hidden !== true)

  return html`
    <nav class="flex flex-col h-full" aria-label="Dashboard navigation">
      <div class="flex items-center ${collapsed ? 'justify-center' : 'justify-between'} border-b border-[var(--white-8)] px-2 pt-2 pb-2">
        ${!collapsed ? html`
          <div class="px-1 leading-none">
            <div class="font-mono text-[9px] font-bold uppercase tracking-[0.22em] text-[var(--color-fg-disabled)]">MASC</div>
            <div class="mt-1 font-mono text-[11px] font-semibold uppercase tracking-[0.14em] text-[var(--color-fg-secondary)]">Cockpit</div>
          </div>
        ` : null}
        <button type="button"
          class=${`flex size-6 items-center justify-center rounded-sm border border-transparent text-[var(--color-fg-muted)] cursor-pointer transition-[background-color,border-color,color] duration-[var(--t-med)] hover:border-[var(--white-10)] hover:bg-[var(--white-4)] hover:text-[var(--color-fg-secondary)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'surface' })}`}
          aria-label=${collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          onClick=${onToggle}
          title=${collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
        >
          ${collapsed ? html`<${ChevronRight} size=${14} />` : html`<${ChevronLeft} size=${14} />`}
        </button>
      </div>

      <div class="flex-1 overflow-y-auto px-2 py-2">
        ${!collapsed ? html`
          <div class="px-1 pb-1.5 font-mono text-[9px] font-bold uppercase tracking-[0.2em] text-[var(--color-fg-disabled)]">Surfaces</div>
        ` : null}
        <div class="flex flex-col gap-1">
          ${visibleSurfaces.map(surface => {
            const isSurfaceActive = surface.id === currentTab
            const sections = visibleSectionItemsForTab(surface.id)

            if (collapsed) {
              return html`
                <${RouteLink}
                  tab=${surface.defaultTab}
                  params=${surface.defaultParams}
                  class="flex h-7 w-full items-center justify-center rounded-sm border cursor-pointer transition-[background-color,border-color,color,box-shadow] duration-[var(--t-med)] ${isSurfaceActive ? 'border-[var(--select-20)] bg-[var(--select-10)] !text-[var(--select)] shadow-[inset_2px_0_0_var(--select)]' : 'border-transparent !text-[var(--color-fg-muted)] hover:border-[var(--white-8)] hover:bg-[var(--white-4)] hover:!text-[var(--color-fg-secondary)]'}"
                  title=${surface.label}
                  aria-label=${surface.label}
                  ariaCurrent=${isSurfaceActive ? 'page' : undefined}
                >
                  <span aria-hidden="true"><${SurfaceIcon} icon=${surface.icon} size=${15} /></span>
                  <span class="sr-only">${surface.label}</span>
                <//>
              `
            }

            return html`
              <div class="flex flex-col gap-0.5 border-t border-[var(--white-5)] pt-1 first:border-t-0 first:pt-0">
                <${RouteLink}
                  tab=${surface.defaultTab}
                  params=${surface.defaultParams}
                  class="flex min-h-7 w-full items-center gap-1.5 rounded-sm border px-1.5 py-1 text-left cursor-pointer transition-[background-color,border-color,color,box-shadow] duration-[var(--t-med)] ${isSurfaceActive ? 'border-[var(--select-20)] bg-[var(--select-10)] !text-[var(--color-fg-secondary)] shadow-[inset_2px_0_0_var(--select)]' : 'border-transparent bg-transparent !text-[var(--color-fg-muted)] hover:border-[var(--white-8)] hover:bg-[var(--white-4)] hover:!text-[var(--color-fg-secondary)]'}"
                  ariaCurrent=${isSurfaceActive && sections.length === 0 ? 'page' : undefined}
                >
                  <span class="flex size-5 shrink-0 items-center justify-center rounded-sm ${isSurfaceActive ? 'bg-[var(--select-10)] text-[var(--select)]' : 'bg-[var(--white-3)] text-[var(--color-fg-muted)]'}" aria-hidden="true">
                    <${SurfaceIcon} icon=${surface.icon} size=${13} />
                  </span>
                  <div class="flex-1 min-w-0">
                    <div class="truncate font-mono text-[11px] font-semibold uppercase leading-4 tracking-[0.08em] ${isSurfaceActive ? 'text-[var(--select)]' : ''}">${surface.label}</div>
                  </div>
                <//>

                ${sections.length > 0 ? html`
                  <div class="ml-2.5 flex flex-col gap-px border-l border-[var(--color-border-divider)] pl-2.5" role="list">
                    ${sections.map(item => {
                      const isSectionActive = isSurfaceActive && currentSection?.id === item.id
                      return html`
                        <div role="listitem">
                          <${RouteLink}
                            tab=${surface.id}
                            params=${item.params}
                            class="block w-full rounded-sm border px-2 py-0.5 text-left font-mono text-[10px] uppercase leading-5 tracking-[0.06em] cursor-pointer transition-[background-color,border-color,color,box-shadow] duration-[var(--t-med)] ${isSectionActive ? 'border-[var(--select-20)] bg-[var(--select-10)] !text-[var(--select)] shadow-[inset_2px_0_0_var(--select)]' : 'border-transparent !text-[var(--color-fg-muted)] hover:border-[var(--white-8)] hover:bg-[var(--white-4)] hover:!text-[var(--color-fg-primary)]'}"
                            ariaCurrent=${isSectionActive ? 'page' : undefined}
                          >
                            <div class="truncate">${item.label}</div>
                          <//>
                        </div>
                      `
                    })}
                  </div>
                ` : null}
              </div>
            `
          })}
        </div>
      </div>

      <div class="shrink-0 border-t border-[var(--white-8)] px-2 py-2">
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
        <${Suspense} fallback=${lazyTabFallback('Overview')}>
          <${LazyOverview} />
        <//>
      `
    case 'monitoring':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Monitor')}>
          <${LazyStatus} />
        <//>
      `
    case 'workspace':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Workspace')}>
          <${LazyWork} />
        <//>
      `
    case 'command':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Command')}>
          <${LazyOperations} />
        <//>
      `
    case 'connectors':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Connectors')}>
          <${LazyConnectors} />
        <//>
      `
    case 'lab':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Lab')}>
          <${LazyLabSurface} />
        <//>
      `
    case 'code':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Code IDE')}>
          <${LazyIdeShell} />
        <//>
      `
    case 'logs':
      return html`
        <${Suspense} fallback=${lazyTabFallback('System Logs')}>
          <${LazyLogViewer} />
        <//>
      `
    default:
      return html`
        <${Suspense} fallback=${lazyTabFallback('Overview')}>
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
  const title = currentSection?.label ?? currentView?.label ?? 'Home'
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
            class="flex items-center gap-1 font-mono text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]"
            aria-label="Page path"
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
                    class="cursor-pointer rounded px-1 py-0.5 hover:bg-[var(--white-5)] hover:text-[var(--color-fg-primary)]"
                  >${crumb.label}<//>`
                : html`<span
                    class="px-1 py-0.5 ${isLast ? 'text-[var(--color-fg-primary)]' : ''}"
                    aria-current=${isLast ? 'page' : undefined}
                  >${crumb.label}</span>`
              return html`${sep}${crumbEl}`
            })}
          </nav>`
        : null}
      <div class="flex items-center gap-2">
        <h2 class="text-lg font-semibold tracking-normal text-[var(--color-fg-secondary)] leading-tight">
          ${title}
        </h2>
        ${shareUrl !== ''
          ? html`<${CopyIdButton}
              value=${shareUrl}
              label=${`Section link (${title})`}
              ariaLabel="Copy current section URL"
              size=${14}
            />`
          : null}
      </div>
      ${description ? html`<p class="m-0 max-w-[72rem] text-xs leading-[var(--lh-body)] text-[var(--color-fg-muted)]">${description}</p>` : null}
    </div>
  `
}

export function DashboardMain() {
  if (dashboardLoading.value && !connected.value && !namespaceTruthInitializing.value) {
    return html`<${LoadingState}>Loading dashboard...<//>`
  }

  const routeLabel = dashboardRouteBoundaryKey(route.value)

  return html`
    ${namespaceTruthInitializing.value ? html`
      <div class="mb-3 shrink-0 rounded-[var(--r-2)] border border-solid border-[var(--warn-20)] bg-[var(--warn-10)] px-4 py-1.5 text-center text-xs text-[var(--color-status-warn)]">Server data warming; this view will refresh automatically.</div>
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
