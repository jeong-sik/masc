import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { useSignalValue } from './use-signal-value'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import type { UnifiedDiffRow } from '../../api/workspace'
import { KeeperBadge } from '../keeper-badge'
import { ideConversationThreadSnapshot } from './ide-context-bridge'
import { globalPresenceSnapshot, PRESENCE_DOT, presenceEntries, type KeeperPresenceSnapshot } from './keeper-presence-store'
import { cursorOverlaySignal, type KeeperCursorOverlay } from './keeper-cursor-overlay'
import {
  IdeContextLens,
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteLink,
} from './ide-context-lens'
import {
  lspDiagnosticSnapshot,
  type LspDiagnosticAnchor,
} from './ide-lsp-client'
import {
  focusIdeContextAnchor,
  normalizeIdeContextFilePath,
  normalizeIdeContextLine,
} from './ide-state'
import {
  createRunActivityStore,
  type RunActivityEvent,
} from './run-activity-store'
import { bridgeRunActivityEventsToTrace } from './run-activity-trace-bridge'
import { fetchActivityEvents, DEFAULT_WORKSPACE_ID } from './ide-activity-event-mapping'
import {
  deriveIdeRunProgressSummary,
  activityRouteLinks,
  activityContextSurface,
  type IdeRunProgressSummary,
  type IdeRunProgressSurfaceCount,
  type IdeRunProgressKeeperCount,
  type IdeRunProgressGoal,
} from './ide-activity-progress-model'

type ActivityRefreshTone = 'loading' | 'live' | 'stale' | 'offline'

interface ActivityRefreshState {
  readonly tone: ActivityRefreshTone
  readonly lastOkMs: number | null
  readonly lastAttemptMs: number | null
  readonly failedCount: number
}

const EMPTY_ACTIVITY: ReadonlyArray<RunActivityEvent> = []
const EMPTY_ANNOTATIONS: ReadonlyArray<IdeAnnotation> = []
const EMPTY_DIFF_ROWS: ReadonlyArray<UnifiedDiffRow> = []
const EMPTY_DIAGNOSTICS: ReadonlyArray<LspDiagnosticAnchor> = []
const INITIAL_REFRESH_STATE: ActivityRefreshState = {
  tone: 'loading',
  lastOkMs: null,
  lastAttemptMs: null,
  failedCount: 0,
}

export interface IdeActivityPanelProps {
  readonly activeFile?: string | null
  readonly annotations?: ReadonlyArray<IdeAnnotation>
  readonly diffRows?: ReadonlyArray<UnifiedDiffRow>
  readonly pollMs?: number
  readonly children?: unknown
}

function normalizedPollMs(value: number | undefined): number | null {
  if (value === undefined || value <= 0 || !Number.isFinite(value)) return null
  return Math.floor(value)
}

export function IdeActivityPanel(props: IdeActivityPanelProps = {}) {
  const {
    activeFile: rawActiveFile = '',
    annotations = EMPTY_ANNOTATIONS,
    diffRows = EMPTY_DIFF_ROWS,
    pollMs = 0,
  } = props
  const activeFile = rawActiveFile ?? ''
  const store = useMemo(() => {
    const store = createRunActivityStore(DEFAULT_WORKSPACE_ID)
    store.seed(EMPTY_ACTIVITY)
    return store
  }, [])
  const [refreshState, setRefreshState] = useState<ActivityRefreshState>(INITIAL_REFRESH_STATE)
  const emittedTraceIds = useRef<ReadonlySet<string>>(new Set())
  const refreshMs = normalizedPollMs(pollMs)

  useEffect(() => {
    let cancelled = false
    let timer: ReturnType<typeof setTimeout> | null = null
    const load = async () => {
      const attemptMs = Date.now()
      setRefreshState(prev => ({
        ...prev,
        lastAttemptMs: attemptMs,
        tone: prev.lastOkMs === null && prev.failedCount === 0 ? 'loading' : prev.tone,
      }))
      const { events, workspaceId, ok } = await fetchActivityEvents()
      if (cancelled) return
      if (ok) {
        store.reset(workspaceId)
        store.seed(events)
        setRefreshState({
          tone: 'live',
          lastOkMs: Date.now(),
          lastAttemptMs: attemptMs,
          failedCount: 0,
        })
      } else {
        setRefreshState(prev => ({
          tone: prev.lastOkMs === null ? 'offline' : 'stale',
          lastOkMs: prev.lastOkMs,
          lastAttemptMs: attemptMs,
          failedCount: prev.failedCount + 1,
        }))
      }
      if (refreshMs !== null) timer = setTimeout(load, refreshMs)
    }
    void load()
    return () => {
      cancelled = true
      if (timer !== null) clearTimeout(timer)
    }
  }, [store, refreshMs])

  useSignalValue(store)
  useSignalValue(globalPresenceSnapshot)
  useSignalValue(cursorOverlaySignal)
  useSignalValue(ideConversationThreadSnapshot)
  useSignalValue(lspDiagnosticSnapshot)

  const events = store.events()
  const keepers = store.knownKeepers()
  const presence = globalPresenceSnapshot.value
  const overlay = cursorOverlaySignal.value
  const threadSnapshot = ideConversationThreadSnapshot.value
  const threads = threadSnapshot.filePath === activeFile ? threadSnapshot.threads : []
  const activeFilePath = normalizeIdeContextFilePath(activeFile)
  const diagnostics = activeFilePath === null
    ? EMPTY_DIAGNOSTICS
    : lspDiagnosticSnapshot.value.get(activeFilePath) ?? EMPTY_DIAGNOSTICS
  const progress = deriveIdeRunProgressSummary(events, activeFile)

  useEffect(() => {
    emittedTraceIds.current = bridgeRunActivityEventsToTrace(events, emittedTraceIds.current)
  }, [events])

  return html`
    <div
      class="ide-rail-panel ide-activity-panel"
      role="region"
      aria-label="EVENT TIMELINE"
    >
      <div
        class="ide-rail-head"
      >
        <span>EVENT TIMELINE</span>
        <span class="ide-activity-head-meta">
          <span>${events.length} events &middot; ${keepers.length} keepers</span>
          <span
            class="ide-activity-refresh-status"
            data-state=${refreshState.tone}
            role="status"
            aria-label=${`Activity refresh ${activityRefreshLabel(refreshState, refreshMs)}`}
            title=${activityRefreshTitle(refreshState, refreshMs)}
          >
            ${activityRefreshLabel(refreshState, refreshMs)}
          </span>
        </span>
      </div>
      <${RunProgressStrip} summary=${progress} />
      <${IdeContextLens}
        filePath=${activeFile}
        annotations=${annotations}
        diffRows=${diffRows}
        events=${events}
        threads=${threads}
        diagnostics=${diagnostics}
        overlay=${overlay}
      />
      <ol
        class="ide-rail-list ide-activity-list"
      >
        ${events.length === 0
          ? html`<li class="ide-rail-empty">no recent activity</li>`
          : events.map(item => ActivityRow(item, presence, overlay))}
      </ol>
    </div>
  `
}

function RunProgressStrip({ summary }: { readonly summary: IdeRunProgressSummary }) {
  return html`
    <section class="ide-run-progress" aria-label="Run progress summary">
      <div class="ide-run-progress-head">
        <span>RUN PROGRESS</span>
        <span>${summary.linkedEvents}/${summary.totalEvents} linked</span>
      </div>
      <div class="ide-run-progress-coverage">
        <div class="ide-run-progress-coverage-head">
          <span>CONTEXT COVERAGE</span>
          <span>${summary.linkedCoverageLabel}</span>
        </div>
        <div
          class="ide-run-progress-coverage-bar"
          role="progressbar"
          aria-label=${`Linked context coverage ${summary.linkedEvents} of ${summary.totalEvents} events`}
          aria-valuemin="0"
          aria-valuemax="100"
          aria-valuenow=${summary.linkedCoveragePercent}
        >
          <span style=${{ width: summary.linkedCoverageLabel }} />
        </div>
      </div>
      <div class="ide-run-progress-stats" role="list" aria-label="Run progress stats">
        <span role="listitem"><strong>${summary.totalEvents}</strong> events</span>
        <span role="listitem"><strong>${summary.currentFileEvents}</strong> file</span>
        <span role="listitem"><strong>${summary.keeperTotalCount}</strong> keepers</span>
        <span role="listitem">${summary.latestAgeLabel}</span>
      </div>
      ${summary.activeGoal ? RunProgressGoalTrack(summary.activeGoal) : null}
      <div class="ide-run-progress-surfaces" role="list" aria-label="Linked operational surfaces">
        ${summary.surfaceCounts.map(surface => RunProgressSurfaceChip(surface))}
      </div>
      <div class="ide-run-progress-keepers" aria-label="Top active keepers">
        ${summary.keeperCounts.length === 0
          ? html`<span>no keeper activity</span>`
          : summary.keeperCounts.map(entry => RunProgressKeeperChip(entry))}
      </div>
    </section>
  `
}

function RunProgressKeeperChip(entry: IdeRunProgressKeeperCount) {
  const routeLink = entry.routeLink
  return html`
    <span
      title=${`${entry.keeper_id}: ${entry.count} events`}
      data-actionable=${routeLink ? 'true' : 'false'}
    >
      ${routeLink
        ? html`
          <button
            type="button"
            class="ide-run-progress-keeper-link"
            title=${routeLink.evidence}
            aria-label=${`Open ${routeLink.evidence}`}
            onClick=${() => openIdeContextRouteLink(routeLink)}
          >
            <${KeeperBadge} id=${entry.keeper_id} variant="sigil" size="sm" />
            <span>${entry.count}</span>
          </button>
        `
        : html`
          <${KeeperBadge} id=${entry.keeper_id} variant="sigil" size="sm" />
          <span>${entry.count}</span>
        `}
    </span>
  `
}

function RunProgressSurfaceChip(surface: IdeRunProgressSurfaceCount) {
  const routeLink = surface.routeLink
  return html`
    <span role="listitem" data-active=${surface.count > 0 ? 'true' : 'false'}>
      ${routeLink
        ? html`
          <button
            type="button"
            class="ide-run-progress-surface-link"
            title=${routeLink.evidence}
            aria-label=${`Open ${routeLink.evidence}`}
            onClick=${() => openIdeContextRouteLink(routeLink)}
          >
            <span>${surface.label}</span>
            <span>${surface.count}</span>
          </button>
        `
        : html`
          <span>${surface.label}</span>
          <span>${surface.count}</span>
        `}
    </span>
  `
}

function RunProgressGoalTrack(goal: IdeRunProgressGoal) {
  const percent = Math.round(goal.progress.ratio * 100)
  const links = routeLinksForContext({
    goalId: goal.goalId,
    taskId: goal.taskId ?? undefined,
  })
  return html`
    <div
      class="ide-run-progress-goal"
      role="status"
      aria-label=${`Run goal ${goal.goalId} progress ${goal.progressLabel}`}
    >
      <div class="ide-run-progress-goal-top">
        <span>GOAL TRACK</span>
        <span>${goal.horizon} &middot; ${goal.phase}</span>
      </div>
      <strong title=${goal.title}>${goal.title}</strong>
      <div class="ide-run-progress-goal-bar" aria-hidden="true">
        <span style=${{ width: `${percent}%` }} />
      </div>
      <div class="ide-run-progress-goal-meta">
        <span>${goal.progress.done}/${goal.progress.total} tasks</span>
        <span>${goal.progressLabel}</span>
        <span title=${goal.goalId}>${goal.goalId}</span>
      </div>
      ${links.length > 0
        ? html`
          <div class="ide-run-progress-goal-links" aria-label="Run goal planning links">
            ${links.map(link => html`
              <button
                key=${link.id}
                type="button"
                title=${link.evidence}
                onClick=${() => openIdeContextRouteLink(link)}
              >${link.label}</button>
            `)}
          </div>
        `
        : null}
    </div>
  `
}

function activityRefreshLabel(state: ActivityRefreshState, refreshMs: number | null): string {
  if (state.tone === 'loading') return 'syncing'
  if (state.tone === 'live') return refreshMs === null ? 'loaded' : 'live'
  const failures = state.failedCount === 1 ? '1 failed' : `${state.failedCount} failed`
  return state.tone === 'offline' ? `offline ${failures}` : `stale ${failures}`
}

function activityRefreshTitle(state: ActivityRefreshState, refreshMs: number | null): string {
  const parts = [`Activity refresh ${activityRefreshLabel(state, refreshMs)}`]
  if (state.lastOkMs !== null) parts.push(`last update ${formatActivityTime(state.lastOkMs)}`)
  if (state.lastAttemptMs !== null) parts.push(`last attempt ${formatActivityTime(state.lastAttemptMs)}`)
  if (refreshMs !== null) parts.push(`poll ${Math.max(1, Math.round(refreshMs / 1000))}s`)
  return parts.join(' | ')
}

function ActivityRow(
  item: RunActivityEvent,
  presence: KeeperPresenceSnapshot | null,
  overlay: KeeperCursorOverlay,
) {
  const hue = keeperHueIndex(item.keeper_id)
  const dot = `var(--color-keeper-${hue}-glow, var(--k-${hue}))`
  const entry = presenceEntries(presence).find(e => e.keeper_id === item.keeper_id)
  const statusDot = entry ? PRESENCE_DOT[entry.status] : null
  const cursor = overlay.cursors.get(item.keeper_id)
  const hasFocus = !!cursor && !!cursor.file_path && cursor.line >= 1
  const focusFile = hasFocus ? cursor.file_path.split('/').pop() : null
  const eventContextFile = item.context?.file_path
  const eventFocusFile = eventContextFile === undefined ? null : normalizeIdeContextFilePath(eventContextFile)
  const eventFocusLine = normalizeIdeContextLine(item.context?.line)
  const hasEventContextFocus = eventFocusFile !== null
  const routeLinks = activityRouteLinks(item)

  return html`
    <li
      class="ide-activity-row"
      style=${{
        '--ide-activity-dot': dot,
      }}
    >
      <span class="ide-activity-time">${formatActivityTime(item.timestamp_ms)}</span>
      <span class="ide-activity-dot" aria-hidden="true" />
      <div style=${{ display: 'flex', flexDirection: 'column', gap: '2px', minWidth: 0 }}>
        <span style=${{ fontSize: 'var(--fs-11)', display: 'flex', alignItems: 'center', gap: 'var(--sp-1)' }}>
          <${KeeperBadge} id=${item.keeper_id} variant="full" size="sm" />
          ${' '}${item.verb}${' '}<span style=${{ color: 'var(--color-fg-muted)' }}>${item.target}</span>
          ${statusDot ? html`
            <span
              role="status"
              aria-label=${`Current: ${statusDot.label}`}
              style=${{
                display: 'inline-flex',
                alignItems: 'center',
                gap: '3px',
                fontSize: 'var(--fs-10)',
                fontWeight: 600,
                letterSpacing: '0.04em',
                color: statusDot.color,
                marginLeft: 'auto',
                whiteSpace: 'nowrap',
                flexShrink: 0,
              }}
            >
              <span style=${{
                width: '4px',
                height: '4px',
                borderRadius: '50%',
                background: statusDot.color,
                display: 'inline-block',
              }} />
              ${statusDot.label}
            </span>
          ` : null}
        </span>
        ${item.detail ? html`<span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${item.detail}</span>` : null}
        ${hasEventContextFocus ? html`
          <button
            type="button"
            class="ide-activity-context-jump"
            aria-label=${activityContextLabel(item, eventFocusFile, eventFocusLine)}
            title=${activityContextTitle(eventFocusFile, eventFocusLine)}
            onClick=${() => focusIdeContextAnchor({
              file_path: eventFocusFile,
              line: eventFocusLine,
              surface: activityContextSurface(item),
              label: item.detail ?? `${item.verb} ${item.target}`,
              source_id: item.id,
              keeper_id: item.keeper_id,
              route_links: routeLinks,
            })}
          >
            &#8599; ${shortContextPath(eventFocusFile, eventFocusLine)}
          </button>
        ` : null}
        ${routeLinks.length > 0 ? html`
          <div class="ide-activity-route-links" aria-label="Activity operational links">
            <${ActivityRouteCount} count=${routeLinks.length} />
            ${routeLinks.map(link => ActivityRouteLink(link))}
          </div>
        ` : null}
        ${hasFocus ? html`
          <span style=${{
            fontSize: 'var(--fs-10)',
            fontFamily: 'var(--font-mono)',
            color: 'var(--color-accent-fg)',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}
          title=${cursor.file_path}
          >&#8599; ${focusFile}:${cursor.line}</span>
        ` : null}
      </div>
    </li>
  `
}

function ActivityRouteLink(link: IdeContextRouteLink) {
  return html`
    <button
      key=${link.id}
      type="button"
      class="ide-activity-route-link"
      title=${link.evidence}
      aria-label=${`Open ${link.evidence}`}
      onClick=${() => openIdeContextRouteLink(link)}
    >
      ${link.label}
    </button>
  `
}

function ActivityRouteCount({ count }: { count: number }) {
  return html`
    <span
      class="ide-activity-route-count"
      title=${`${count} linked activity context routes`}
      aria-label=${`${count} linked activity context routes`}
    >
      CTX ${count}
    </span>
  `
}

function activityContextLabel(
  item: RunActivityEvent,
  filePath: string,
  line: number | undefined,
): string {
  const suffix = line !== undefined ? ` line ${line}` : ''
  return `Focus ${activityContextSurface(item)} context ${filePath}${suffix}`
}

function activityContextTitle(filePath: string, line: number | undefined): string {
  return line !== undefined ? `${filePath}:${line}` : filePath
}

function shortContextPath(filePath: string, line: number | undefined): string {
  const fileLabel = filePath.split('/').pop() || filePath
  return line !== undefined ? `${fileLabel}:${line}` : fileLabel
}

function formatActivityTime(ms: number): string {
  return new Date(ms).toISOString().slice(11, 19)
}
