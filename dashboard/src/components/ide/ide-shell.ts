import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { useSignalValue, useSubscribedSnapshot, useSubscribedValue } from './use-signal-value'
import {
  activeIdeFile,
  focusIdeContextAnchor,
  ideContextFocus,
  type IdeContextFocus,
  type IdeContextFocusRouteLink,
} from './ide-state'
import { getIdeDataWorkspaceStore } from './ide-workspace-singleton'
import { parsePositiveLineString } from '../common/normalize'
import { IdeExplorer } from './ide-explorer'
import { IdeEditor, type IdeEditorView } from './ide-editor'
import { IdeAnnotationComposer } from './ide-annotation-composer'
import { IdeConversationRail } from './ide-conversation-rail'
import { IdeActivityPanel } from './ide-activity-panel'
import { IdeKeeperWorkPanel } from './ide-keeper-work-panel'
import { IdeInterject } from './ide-interject'
import { ExecuteOutputDrawer } from './execute-output-drawer'
import { IdePresenceStrip } from './ide-presence-strip'
import {
  IDE_LAYERS,
  IDE_LAYER_LABELS,
  REVIEW_FOCUS_LAYERS,
  IdeToolbar,
} from './ide-toolbar'
import { IdeBreadcrumb } from './ide-breadcrumb'
import { IdeReviewFocusStrip } from './ide-review-focus-strip'
import { pinKeeper } from './multi-keeper-pin-store'
import { OverlayKeeperTrace } from './overlay-keeper-trace'
import { IdePersistencePanel } from './ide-persistence-panel'
import { IdeMemoryPanel } from './ide-memory-panel'
import { routeLinksForContext } from './ide-context-lens'
import {
  connectKeeperCursorStream,
  cursorOverlaySignal,
  getKeeperColor,
  type KeeperCursor,
  type KeeperCursorOverlay,
  type KeeperCursorStreamState,
} from './keeper-cursor-overlay'
import { lspStatusSnapshot, type LspStatusSnapshot, type SelectedAnnotation } from './ide-lsp-client'
import { deleteIdeAnnotation, type IdeAnnotationDeleteOutcome } from '../../api/ide'
import { showToast } from '../common/toast'
import { navigate, route } from '../../router'
import { activeKeeperName } from '../../keeper-state'
import { keepers } from '../../store'
import { connected } from '../../sse'
import { dashboardBearerToken } from '../../api/core'
import { devTokenBootstrapStatus } from '../../api/dev-token'
import { dashboardWsOnlyEnabled } from '../../dashboard-ws-cutover'
import { dashboardWsConnected, dashboardWsSseFallbackActive } from '../../dashboard-ws-state'
import type { Repository } from '../../api/repositories'
import type { WorkspaceSource } from '../../api/workspace-source'
import { KeeperBadge } from '../keeper-badge'
import type { WorkspaceFetchIssue } from './ide-data-workspace-store'
import {
  parseActive,
  serializeActive,
} from '../../../design-system/headless-core/layered-overlay'
import { viewFromRoute } from './ide-view-route'

type ViewTab = IdeEditorView
type IdeFocus = 'review'
type IdeRightRailTab = 'context' | 'activity' | 'cursors'
type IdeStatusbarChipTone = 'brass' | 'ghost' | 'info' | 'ok' | 'warn'
type IdeConnectionTone = 'ok' | 'warn'

interface IdeRightRailTabDescriptor {
  readonly id: IdeRightRailTab
  readonly label: string
  readonly title: string
}

export interface IdeStatusbarChip {
  readonly id: string
  readonly label: string
  readonly tone: IdeStatusbarChipTone
  readonly title: string
}

export interface IdeStatusbarModel {
  readonly workspaceLabel: string
  readonly workspaceBasePath: string | null
  readonly chips: ReadonlyArray<IdeStatusbarChip>
  readonly connectionLabel: string
  readonly connectionTone: IdeConnectionTone
}

const IDE_LAYER_KINDS = new Set(IDE_LAYERS.map(layer => layer.kind))
const IDE_ACTIVITY_POLL_MS = 10_000
const REVIEW_FOCUS_LAYER_PARAM = REVIEW_FOCUS_LAYERS.join(',')
const EMPTY_LAYER_PARAM = 'none'
export const IDE_TREE_WIDTH_STORAGE_KEY = 'dashboard:ide-tree-width'
export const IDE_TREE_WIDTH_DEFAULT = 230
export const IDE_TREE_WIDTH_MIN = 180
export const IDE_TREE_WIDTH_MAX = 360
const STATUSBAR_LAYER_PRIORITY: ReadonlyArray<string> = [
  'keeper-trace',
  'approve',
  'notes',
  'runtime',
  'time',
  'parallel',
  'tools',
  'explode',
]
const STATUSBAR_VIEW_LABELS: Readonly<Record<ViewTab, string>> = {
  source: 'SOURCE',
  unified: 'UNIFIED',
  'split-diff': 'SPLIT DIFF',
  blame: 'BLAME',
}
const IDE_RIGHT_RAIL_TABS: ReadonlyArray<IdeRightRailTabDescriptor> = [
  {
    id: 'context',
    label: 'Work Context',
    title: 'Keeper work, persistence, memory, and chat scoped to the active IDE context',
  },
  {
    id: 'activity',
    label: 'Run Activity',
    title: 'Workspace and keeper activity linked to the active file and repository',
  },
  {
    id: 'cursors',
    label: 'Keeper Cursors',
    title: 'Live keeper file focus and cursor stream status',
  },
]

export function normalizeIdeTreeWidth(value: unknown): number {
  const numeric = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(numeric)) return IDE_TREE_WIDTH_DEFAULT
  return Math.min(IDE_TREE_WIDTH_MAX, Math.max(IDE_TREE_WIDTH_MIN, Math.round(numeric)))
}

function readStoredIdeTreeWidth(): number {
  if (typeof window === 'undefined' || window.localStorage === undefined) {
    return IDE_TREE_WIDTH_DEFAULT
  }
  try {
    const raw = window.localStorage.getItem(IDE_TREE_WIDTH_STORAGE_KEY)
    if (!raw) return IDE_TREE_WIDTH_DEFAULT
    try {
      return normalizeIdeTreeWidth(JSON.parse(raw))
    } catch {
      return normalizeIdeTreeWidth(raw)
    }
  } catch {
    return IDE_TREE_WIDTH_DEFAULT
  }
}

function writeStoredIdeTreeWidth(width: number): void {
  if (typeof window === 'undefined' || window.localStorage === undefined) return
  try {
    window.localStorage.setItem(IDE_TREE_WIDTH_STORAGE_KEY, JSON.stringify(width))
  } catch {
    // localStorage can be unavailable or quota-limited; keep the in-memory width.
  }
}

interface IdeStatusbarInput {
  readonly activeView: ViewTab
  readonly activeLayers: ReadonlySet<string>
  readonly activeFilePath: string | null
  readonly contextFocus?: IdeContextFocus | null
  readonly findOpen: boolean
  readonly terminalOpen: boolean
  readonly railsCollapsed: boolean
  readonly reviewFocusActive: boolean
  readonly routeParams: Record<string, string>
  readonly repositories?: ReadonlyArray<Repository>
  readonly activeRepositoryId?: string | null
  readonly workspaceSource?: WorkspaceSource
  readonly workspaceBasePath?: string | null
  readonly workspaceIssues?: ReadonlyArray<WorkspaceFetchIssue>
  readonly dashboardConnected?: boolean
  readonly lspStatus?: LspStatusSnapshot
}

function focusFromRoute(raw: string | null | undefined): IdeFocus | null {
  return raw?.trim().toLowerCase() === 'review' ? 'review' : null
}

function layersFromRoute(raw: string | null | undefined, focus: IdeFocus | null): ReadonlySet<string> {
  if (raw?.trim().toLowerCase() === EMPTY_LAYER_PARAM) return new Set()
  if (focus === 'review' && !raw?.trim()) {
    return parseActive(REVIEW_FOCUS_LAYER_PARAM, IDE_LAYER_KINDS)
  }
  return parseActive(raw ?? '', IDE_LAYER_KINDS)
}

function keeperFromRoute(): string {
  const routeKeeper = route.value.params.keeper?.trim()
  if (routeKeeper) return routeKeeper
  const active = activeKeeperName.value.trim()
  if (active) return active
  return keepers.value[0]?.name?.trim() ?? ''
}

function routeFocusFile(params: Record<string, string>): string | undefined {
  return params.file?.trim() || params.file_path?.trim() || params.path?.trim() || undefined
}

function routeFocusLine(params: Record<string, string>): number | undefined {
  const raw = params.line?.trim() || params.lineno?.trim()
  if (!raw) return undefined
  return parsePositiveLineString(raw)
}

function routeFocusLabel(params: Record<string, string>, filePath: string): string {
  const label = params.label?.trim()
  if (label) return label
  return filePath.split('/').pop() || filePath
}

function routeFocusSourceId(params: Record<string, string>, filePath: string, line?: number): string {
  const sourceId = params.source_id?.trim() || params.source?.trim()
  if (sourceId) return sourceId
  return line !== undefined ? `route:${filePath}:${line}` : `route:${filePath}`
}

function routeParam(params: Record<string, string>, ...keys: ReadonlyArray<string>): string | undefined {
  for (const key of keys) {
    const value = params[key]?.trim()
    if (value) return value
  }
  return undefined
}

function shortStatusbarPath(path: string): string {
  const trimmed = path.trim()
  if (!trimmed) return 'no file'
  const parts = trimmed.split('/').filter(Boolean)
  if (parts.length <= 2) return trimmed
  return `${parts.at(-2)}/${parts.at(-1)}`
}

function compactStatusbarPath(path: string): string | undefined {
  const normalized = path.trim().replace(/\\/g, '/')
  if (!normalized) return undefined
  const parts = normalized.split('/').filter(Boolean)
  if (parts.length === 0) return undefined
  if (parts.length === 1) return parts[0]
  return `${parts.at(-2)}/${parts.at(-1)}`
}

function statusbarRepositoryLabel(repository: Repository | undefined): string | undefined {
  const name = repository?.name?.trim()
  if (name) return name
  return compactStatusbarPath(repository?.local_path ?? '') ?? repository?.id?.trim()
}

function activeStatusbarRepository(
  repositories: ReadonlyArray<Repository> | undefined,
  activeRepositoryId: string | null | undefined,
): Repository | undefined {
  if (!repositories || repositories.length === 0) return undefined
  return repositories.find(repository => activeRepositoryId && repository.id === activeRepositoryId)
    ?? repositories[0]
}

/**
 * Derive a browsable https web URL from a git clone URL so the repo-origin
 * block can render the prototype's `↗` external link.
 *
 * Total + deterministic: handles the two common clone forms
 * (`https://host/owner/repo[.git]` and `git@host:owner/repo[.git]`) and
 * returns `null` for anything else. A `null` result means "no usable web
 * link" — the caller omits the `<a>` rather than fabricating a destination.
 */
function deriveRepoWebUrl(cloneUrl: string | null | undefined): string | null {
  const raw = cloneUrl?.trim()
  if (!raw) return null
  const stripGitSuffix = (path: string): string => path.replace(/\.git$/i, '')
  if (/^https?:\/\//i.test(raw)) {
    try {
      const url = new URL(raw)
      if (url.protocol !== 'http:' && url.protocol !== 'https:') return null
      url.pathname = stripGitSuffix(url.pathname)
      url.username = ''
      url.password = ''
      return url.toString()
    } catch {
      return null
    }
  }
  // scp-like syntax: git@host:owner/repo(.git)
  const scpMatch = /^[^@\s]+@([^:\s]+):(.+)$/.exec(raw)
  if (scpMatch) {
    const host = scpMatch[1]
    const rawPath = scpMatch[2]
    if (!host || !rawPath) return null
    const path = stripGitSuffix(rawPath.replace(/^\/+/, ''))
    if (!path) return null
    return `https://${host}/${path}`
  }
  return null
}

function statusbarWorkspaceLabel(
  repositories: ReadonlyArray<Repository> | undefined,
  activeRepositoryId: string | null | undefined,
  workspaceSource: WorkspaceSource | undefined,
): string {
  const repositoryForId = (repoId: string): string =>
    statusbarRepositoryLabel(repositories?.find(repository => repository.id === repoId))
    ?? repoId

  switch (workspaceSource?.kind) {
    case 'repository':
      return repositoryForId(workspaceSource.repoId)
    case 'repository_missing':
      return `${repositoryForId(workspaceSource.repoId)} fallback`
    case 'repository_unknown':
      return `${workspaceSource.repoId} unknown`
    case 'playground':
      return `@${workspaceSource.keeper}`
    case 'playground_missing':
      return `@${workspaceSource.keeper} fallback`
    case 'keeper_unknown':
      return `@${workspaceSource.keeper} unknown`
    case 'project':
    case undefined:
      return statusbarRepositoryLabel(activeStatusbarRepository(repositories, activeRepositoryId)) ?? '(no workspace)'
  }
}

function dashboardRuntimeConnected(): boolean {
  if (dashboardWsOnlyEnabled()) {
    return dashboardWsConnected.value || dashboardWsSseFallbackActive.value
  }
  return connected.value
}

/**
 * Derive a human-readable label for the disconnected state so the statusbar
 * tells the user *why* rather than just "reconnecting".
 */
function disconnectionReasonLabel(): string {
  const hasToken = !!dashboardBearerToken()
  const bootstrap = devTokenBootstrapStatus.value

  if (!hasToken && bootstrap === 'no_endpoint') {
    return 'dashboard · auth required'
  }
  if (!hasToken && bootstrap === 'network') {
    return 'dashboard · server unreachable'
  }
  if (!hasToken && bootstrap === 'fetching') {
    return 'dashboard · bootstrapping...'
  }
  if (!hasToken) {
    return 'dashboard · no token'
  }
  return 'dashboard · reconnecting'
}

function statusbarLayerLabel(activeLayers: ReadonlySet<string>): string | null {
  if (activeLayers.size === 0) return null
  const labels = STATUSBAR_LAYER_PRIORITY
    .filter(layer => activeLayers.has(layer))
    .map(layer => IDE_LAYER_LABELS.get(layer) ?? layer)
  if (labels.length === 0) return `${activeLayers.size} layers`
  return labels.length === 1 ? labels[0]! : `${labels[0]} +${labels.length - 1}`
}

function normalizePrLabel(value: string): string {
  const normalized = value.trim().replace(/^#/, '')
  return normalized ? `#${normalized}` : value.trim()
}

function statusbarTelemetryLabel(params: Record<string, string>): string | undefined {
  const session = routeParam(params, 'session_id')
  const operation = routeParam(params, 'operation_id', 'op')
  const worker = routeParam(params, 'worker_run_id', 'worker')
  const query = routeParam(params, 'telemetry_q', 'q') ?? routeParam(params, 'log_id', 'log')
  const first = session ?? operation ?? worker ?? query
  return first ? `Telemetry ${first}` : undefined
}

function focusRouteLinkByLabel(
  focus: IdeContextFocus | null | undefined,
  ...labels: ReadonlyArray<string>
): IdeContextFocusRouteLink | undefined {
  const accepted = new Set(labels.map(label => label.toLowerCase()))
  return focus?.route_links?.find(link => accepted.has(link.label.trim().toLowerCase()))
}

function focusRouteParam(
  focus: IdeContextFocus | null | undefined,
  labels: ReadonlyArray<string>,
  ...keys: ReadonlyArray<string>
): string | undefined {
  const link = focusRouteLinkByLabel(focus, ...labels)
  if (!link) return undefined
  return routeParam(link.params, ...keys)
}

function statusbarTelemetryLabelFromFocus(focus: IdeContextFocus | null | undefined): string | undefined {
  const telemetry = focusRouteLinkByLabel(focus, 'Telemetry')
  if (!telemetry) return undefined
  const session = routeParam(telemetry.params, 'session_id')
  const operation = routeParam(telemetry.params, 'operation_id', 'op')
  const worker = routeParam(telemetry.params, 'worker_run_id', 'worker')
  const query = routeParam(telemetry.params, 'telemetry_q', 'q') ?? routeParam(telemetry.params, 'log_id', 'log')
  const first = session ?? operation ?? worker ?? query
  return first ? `Telemetry ${first}` : undefined
}

function workspaceIssueLabel(issue: WorkspaceFetchIssue): string {
  switch (issue.kind) {
    case 'repositories':
      return 'repos'
    case 'tree':
      return 'tree'
    case 'file':
      return issue.file_path ? `file ${shortStatusbarPath(issue.file_path)}` : 'file'
    case 'regions':
      return 'regions'
    case 'blame':
      return 'blame'
    case 'diff':
      return 'diff'
    case 'annotations':
      return 'annotations'
  }
}

function workspaceIssueTitle(issues: ReadonlyArray<WorkspaceFetchIssue>): string {
  return issues
    .map(issue => {
      const scope = [
        issue.file_path ? `file=${issue.file_path}` : null,
        issue.repo_id ? `repo=${issue.repo_id}` : null,
        issue.keeper ? `keeper=${issue.keeper}` : null,
      ].filter((part): part is string => part !== null)
      const scoped = scope.length > 0 ? ` (${scope.join(', ')})` : ''
      return `${workspaceIssueLabel(issue)}${scoped}: ${issue.message}`
    })
    .join('\n')
}

function lspOverlayOnlyStatus(status: LspStatusSnapshot | undefined): ReadonlyArray<string> {
  return (status?.langs ?? [])
    .filter(lang => lang.overlay_only)
    .map(lang => {
      const error = lang.last_error?.trim()
      return error ? `${lang.lang}: ${error}` : lang.lang
    })
}

function addStatusbarChip(
  chips: IdeStatusbarChip[],
  id: string,
  label: string | undefined,
  tone: IdeStatusbarChipTone,
  title: string,
) {
  const trimmed = label?.trim()
  if (!trimmed) return
  chips.push({ id, label: trimmed, tone, title })
}

export function deriveIdeStatusbarModel({
  activeView,
  activeLayers,
  activeFilePath,
  contextFocus = null,
  findOpen,
  terminalOpen,
  railsCollapsed,
  reviewFocusActive,
  routeParams,
  repositories,
  activeRepositoryId,
  workspaceSource,
  workspaceBasePath = null,
  workspaceIssues = [],
  dashboardConnected = false,
  lspStatus,
}: IdeStatusbarInput): IdeStatusbarModel {
  const chips: IdeStatusbarChip[] = []
  const viewLabel = STATUSBAR_VIEW_LABELS[activeView]
  addStatusbarChip(chips, 'view', viewLabel, reviewFocusActive ? 'brass' : 'ghost', `View: ${viewLabel}`)
  addStatusbarChip(
    chips,
    'file',
    activeFilePath === null ? 'no file' : shortStatusbarPath(activeFilePath),
    'ghost',
    `Active file: ${activeFilePath === null ? 'no file' : activeFilePath}`,
  )

  const layerLabel = statusbarLayerLabel(activeLayers)
  addStatusbarChip(chips, 'layers', layerLabel ?? undefined, 'info', layerLabel ? `Active layers: ${layerLabel}` : '')
  const issueLabels = [...new Set(workspaceIssues.map(workspaceIssueLabel))]
  addStatusbarChip(
    chips,
    'workspace-fetch',
    issueLabels.length > 0 ? `IDE fetch degraded ${issueLabels.join('/')}` : undefined,
    'warn',
    workspaceIssueTitle(workspaceIssues),
  )
  const lspOverlayOnly = lspOverlayOnlyStatus(lspStatus)
  addStatusbarChip(
    chips,
    'lsp-status',
    lspOverlayOnly.length > 0 ? `LSP overlay-only ${lspOverlayOnly.length}` : undefined,
    'warn',
    lspOverlayOnly.join('\n'),
  )
  if (terminalOpen) addStatusbarChip(chips, 'terminal', 'terminal', 'info', 'Execute output drawer open')
  if (findOpen) addStatusbarChip(chips, 'find', 'find', 'ghost', 'Current-file find panel open')
  if (railsCollapsed) addStatusbarChip(chips, 'rails', 'rails hidden', 'ghost', 'IDE side rails hidden')

  const routeLine = routeFocusLine(routeParams)
  const contextLine = contextFocus?.line ?? routeLine
  const routeSurface = contextFocus?.surface?.trim() || routeParams.surface?.trim()
  const routeLabel = contextFocus?.label?.trim() || routeParams.label?.trim()
  const routeFocusParts = [
    routeSurface,
    contextLine ? `L${contextLine}` : undefined,
    routeLabel,
  ].filter((part): part is string => Boolean(part?.trim()))
  addStatusbarChip(
    chips,
    'focus',
    routeFocusParts.length > 0 ? routeFocusParts.join(' ') : undefined,
    'brass',
    'Route-focused IDE context',
  )

  const goal = routeParam(routeParams, 'goal_id', 'goal')
    ?? focusRouteParam(contextFocus, ['Goal'], 'goal')
  const task = routeParam(routeParams, 'task_id', 'task')
    ?? focusRouteParam(contextFocus, ['Task'], 'task')
  const board = routeParam(routeParams, 'board_post_id', 'post')
    ?? focusRouteParam(contextFocus, ['Board'], 'post')
  const comment = routeParam(routeParams, 'comment_id', 'comment')
    ?? focusRouteParam(contextFocus, ['Comment'], 'comment')
  const pr = routeParam(routeParams, 'pr_id', 'pr')
    ?? focusRouteParam(contextFocus, ['PR'], 'pr')
  const git = routeParam(routeParams, 'git_ref', 'ref')
    ?? focusRouteParam(contextFocus, ['Git'], 'ref')
  const log = routeParam(routeParams, 'log_id', 'log')
    ?? focusRouteParam(contextFocus, ['Log'], 'log_id')
  const telemetry = statusbarTelemetryLabel(routeParams)
    ?? statusbarTelemetryLabelFromFocus(contextFocus)
  const keeper = routeParam(routeParams, 'keeper')
    ?? focusRouteParam(contextFocus, ['Keeper'], 'keeper')
    ?? contextFocus?.keeper_id

  addStatusbarChip(chips, 'goal', goal ? `Goal ${goal}` : undefined, 'brass', 'Focused goal')
  addStatusbarChip(chips, 'task', task ? `Task ${task}` : undefined, 'brass', 'Focused task')
  addStatusbarChip(chips, 'board', board ? `Board ${board}` : undefined, 'info', 'Focused board post')
  addStatusbarChip(chips, 'comment', comment ? `Comment ${comment}` : undefined, 'info', 'Focused comment')
  addStatusbarChip(chips, 'pr', pr ? `PR ${normalizePrLabel(pr)}` : undefined, 'info', 'Focused pull request')
  addStatusbarChip(chips, 'git', git ? `Git ${git}` : undefined, 'ghost', 'Focused git reference')
  addStatusbarChip(chips, 'log', log ? `Log ${log}` : undefined, 'info', 'Focused runtime log')
  addStatusbarChip(chips, 'telemetry', telemetry, 'info', 'Focused fleet telemetry')
  addStatusbarChip(chips, 'keeper', keeper ? `Keeper ${keeper}` : undefined, 'ok', 'Focused keeper')

  return {
    workspaceLabel: statusbarWorkspaceLabel(repositories, activeRepositoryId, workspaceSource),
    workspaceBasePath,
    chips,
    connectionLabel: dashboardConnected
      ? 'dashboard · live'
      : disconnectionReasonLabel(),
    connectionTone: dashboardConnected ? 'ok' : 'warn',
  }
}

function IdeDashboardConnectionChip({
  label,
  tone,
}: {
  readonly label: string
  readonly tone: IdeConnectionTone
}) {
  const title = tone === 'ok'
    ? 'Dashboard event transport is live. Repository tree loads, LSP, and keeper cursor streams report separate status.'
    : 'Dashboard event transport is not live. Repository tree loads, LSP, and keeper cursor streams report separate status.'
  return html`
    <span
      class=${`chip sm is-${tone}`}
      data-testid="ide-dashboard-connection"
      title=${title}
      aria-label=${`${label}; ${title}`}
    >${label}</span>
  `
}

function paramsWithLayers(
  params: Record<string, string>,
  view: ViewTab,
  activeLayers: ReadonlySet<string>,
): Record<string, string> {
  const next: Record<string, string> = { ...params, section: 'ide-shell', view }
  const serialized = serializeActive(activeLayers)
  if (serialized) {
    next.layers = serialized
  } else if (focusFromRoute(params.focus) === 'review' && view === 'unified') {
    next.layers = EMPTY_LAYER_PARAM
  } else {
    delete next.layers
  }
  return next
}

function paramsWithRails(
  params: Record<string, string>,
  view: ViewTab,
  collapsed: boolean,
): Record<string, string> {
  const next: Record<string, string> = { ...params, section: 'ide-shell', view }
  if (collapsed) {
    next.rails = 'hidden'
  } else {
    delete next.rails
  }
  return next
}

function shortCursorPath(path: string): string {
  const parts = path.trim().split('/').filter(Boolean)
  if (parts.length <= 2) return path.trim() || '(no file)'
  return `${parts.at(-2)}/${parts.at(-1)}`
}

function cursorAgeLabel(lastUpdate: number): string {
  if (!Number.isFinite(lastUpdate) || lastUpdate <= 0) return 'unknown age'
  const seconds = Math.max(0, Math.round((Date.now() - lastUpdate) / 1000))
  if (seconds < 60) return `${seconds}s ago`
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  return `${Math.round(minutes / 60)}h ago`
}

function cursorStreamStatusTone(status: KeeperCursorStreamState['status']): 'ghost' | 'info' | 'ok' | 'warn' {
  switch (status) {
    case 'connecting':
      return 'info'
    case 'live':
      return 'ok'
    case 'degraded':
      return 'warn'
    case 'closed':
      return 'ghost'
  }
}

function cursorStreamStatusLabel(stream: KeeperCursorStreamState): string {
  switch (stream.status) {
    case 'connecting':
      return 'stream connecting'
    case 'live':
      return 'stream live'
    case 'degraded':
      return stream.failedCount > 0
        ? `stream degraded ${stream.failedCount} failed`
        : 'stream degraded'
    case 'closed':
      return 'stream closed'
  }
}

function cursorStreamStatusTitle(stream: KeeperCursorStreamState): string {
  const parts = [cursorStreamStatusLabel(stream)]
  if (stream.lastOpenMs !== undefined) parts.push(`last open ${new Date(stream.lastOpenMs).toISOString()}`)
  if (stream.lastErrorMs !== undefined) parts.push(`last error ${new Date(stream.lastErrorMs).toISOString()}`)
  if (stream.error) parts.push(stream.error)
  return parts.join(' · ')
}

function sortedCursors(overlay: KeeperCursorOverlay): ReadonlyArray<KeeperCursor> {
  return [...overlay.cursors.values()].sort((left, right) => {
    if (right.last_update !== left.last_update) return right.last_update - left.last_update
    return left.keeper_id.localeCompare(right.keeper_id)
  })
}

function focusCursor(cursor: KeeperCursor): void {
  const filePath = cursor.file_path.trim()
  if (!filePath) return
  const line = cursor.line >= 1 ? cursor.line : undefined
  const label = cursor.tool_name ?? cursor.focus_mode
  const sourceId = `cursor:${cursor.keeper_id}:${filePath}:${line ?? 0}`
  focusIdeContextAnchor({
    file_path: filePath,
    line,
    surface: 'Keeper',
    label,
    source_id: sourceId,
    keeper_id: cursor.keeper_id,
    route_links: routeLinksForContext({
      filePath,
      line,
      surface: 'Keeper',
      label,
      sourceId,
      keeperId: cursor.keeper_id,
      telemetry: true,
      telemetryQuery: [
        cursor.keeper_id,
        cursor.focus_mode ? `mode:${cursor.focus_mode}` : null,
        cursor.tool_name ? `tool:${cursor.tool_name}` : null,
      ].filter((part): part is string => Boolean(part)).join(' '),
    }),
  })
}

function IdeCursorRailPanel() {
  const overlay = useSignalValue(cursorOverlaySignal)
  const cursors = useMemo(() => sortedCursors(overlay), [overlay])
  return html`
    <div
      class="ide-plane-cursors"
      data-testid="ide-cursor-rail"
      role="region"
      aria-label="Keeper cursor focus"
    >
      <div class="ide-rail-head">
        <span>KEEPER CURSORS</span>
        <span>${cursors.length} active</span>
      </div>
      ${overlay.stream ? html`
        <div
          class=${`ide-cursor-stream-status chip sm is-${cursorStreamStatusTone(overlay.stream.status)}`}
          data-testid="ide-cursor-stream-status"
          data-state=${overlay.stream.status}
          role="status"
          aria-live="polite"
          title=${cursorStreamStatusTitle(overlay.stream)}
        >${cursorStreamStatusLabel(overlay.stream)}</div>
      ` : null}
      ${overlay.active_file ? html`
        <div class="ide-cursor-rail-active-file" title=${overlay.active_file}>
          active file · ${shortCursorPath(overlay.active_file)}
        </div>
      ` : null}
      ${overlay.collisions.length > 0 ? html`
        <div class="ide-cursor-collision-list" role="status" aria-label="Cursor collision summary">
          ${overlay.collisions.slice(0, 4).map(collision => html`
            <span
              key=${`${collision.line}:${collision.keeper_ids.join(',')}`}
              data-risk=${collision.risk_level}
              title=${collision.keeper_ids.join(', ')}
            >
              L${collision.line} · ${collision.risk_level} · ${collision.keeper_ids.length}
            </span>
          `)}
        </div>
      ` : null}
      <ol class="ide-cursor-rail-list" aria-label="Active keeper cursors">
        ${cursors.length === 0
          ? html`<li class="ide-rail-empty" data-testid="ide-cursor-rail-empty">no active cursors</li>`
          : cursors.map(cursor => html`<${IdeCursorRailRow} key=${cursor.keeper_id} cursor=${cursor} />`)}
      </ol>
    </div>
  `
}

function IdeCursorRailRow({ cursor }: { readonly cursor: KeeperCursor }) {
  const color = getKeeperColor(cursor.keeper_id)
  const hasFile = cursor.file_path.trim() !== ''
  const selection = cursor.selection_end && cursor.selection_end.line !== cursor.line
    ? `-${cursor.selection_end.line}`
    : ''
  return html`
    <li
      class="ide-cursor-rail-row v2-ide-row"
      style=${{ '--ide-cursor-color': color.cursor }}
    >
      <div class="ide-cursor-rail-row-head">
        <${KeeperBadge} id=${cursor.keeper_id} variant="sigil" size="sm" />
        <span class="ide-cursor-rail-keeper">${cursor.keeper_id}</span>
        <span class="ide-cursor-rail-age">${cursorAgeLabel(cursor.last_update)}</span>
      </div>
      <div class="ide-cursor-rail-meta">
        <span>${cursor.focus_mode}</span>
        ${cursor.tool_name ? html`<span>${cursor.tool_name}</span>` : null}
        ${cursor.turn !== undefined ? html`<span>turn ${cursor.turn}</span>` : null}
      </div>
      <div class="ide-cursor-rail-path" title=${cursor.file_path}>
        ${hasFile ? `${shortCursorPath(cursor.file_path)}:${cursor.line}${selection}` : 'no file focus'}
      </div>
      <button
        type="button"
        class="v2-ide-action ide-cursor-rail-focus"
        disabled=${!hasFile}
        onClick=${() => focusCursor(cursor)}
      >Focus</button>
    </li>
  `
}

/**
 * Repo-origin block for the IDE top bar — prototype `.ide-repo` chrome.
 *
 * Renders the active repository's origin clone URL (copy-on-click), an
 * optional GitHub-style web link, and the default branch using the vendored
 * keeper-v2 `.ide-repo` / `.ide-remote` / `.ide-web` / `.br` skin classes.
 *
 */
function repositoryGitStatusView(repository: Repository) {
  const status = repository.git_status
  if (!status) {
    return html`<span data-state="missing" title="repository git_status 필드 미수신">변경 상태 없음</span>`
  }
  if (status.state === 'unavailable') {
    return html`
      <span data-state="unavailable" title=${status.error || 'git status unavailable'}>
        변경 확인 실패
      </span>
    `
  }
  if (!status.dirty) {
    return html`<span data-state="clean" title="git status --porcelain=v1: 변경 없음">변경 없음</span>`
  }
  const title = [
    `changed ${status.changed_files}`,
    `staged ${status.staged_files}`,
    `unstaged ${status.unstaged_files}`,
    `untracked ${status.untracked_files}`,
    `conflicted ${status.conflicted_files}`,
  ].join(' · ')
  return html`<span data-state="dirty" title=${title}>${status.changed_files}개 변경</span>`
}

function IdeRepoOrigin({
  repositories,
  activeRepositoryId,
}: {
  readonly repositories: ReadonlyArray<Repository> | undefined
  readonly activeRepositoryId: string | null | undefined
}) {
  const [copied, setCopied] = useState(false)
  const repository = activeStatusbarRepository(repositories, activeRepositoryId)
  if (!repository) return null

  const origin = repository.url.trim()
  const branch = repository.default_branch.trim()
  const webUrl = deriveRepoWebUrl(origin)

  const copyOrigin = () => {
    if (!origin) return
    const clipboard = typeof navigator !== 'undefined' ? navigator.clipboard : undefined
    if (!clipboard) return
    void clipboard.writeText(origin).then(() => {
      setCopied(true)
      window.setTimeout(() => setCopied(false), 1100)
    }).catch(() => {
      // Clipboard can be blocked by permissions; leave the label unchanged.
    })
  }

  return html`
    <span
      class="ide-repo"
      data-testid="ide-repo-origin"
      title=${`이 keeper 워크트리의 origin (git remote) · ${repository.local_path || repository.name}`}
    >
      ${origin
        ? html`
          <button
            type="button"
            class="ide-remote mono"
            title="origin 클론 URL 복사"
            onClick=${copyOrigin}
          >${copied ? '✓ 복사됨' : origin}</button>
        `
        : html`<span class="ide-remote mono" data-stub="repo-origin">origin URL 미수신</span>`}
      ${webUrl
        ? html`<a class="ide-web" href=${webUrl} target="_blank" rel="noreferrer" title="웹에서 보기 ↗">↗</a>`
        : null}
      ${branch ? html`<span class="br" title="기본 브랜치 (default_branch)">${branch}</span>` : null}
      ${' · '}
      ${repositoryGitStatusView(repository)}
    </span>
  `
}

export function IdeShell() {
  // App-lifetime singleton: the store survives IdeShell unmount (tab change),
  // so tree expansion / repo selection / diff / file content persist across
  // navigation instead of being disposed and refetched. Do NOT dispose on
  // unmount — the store is intentionally shared across all IdeShell mounts.
  const workspaceStore = useMemo(() => getIdeDataWorkspaceStore(), [])

  const annotations = useSubscribedSnapshot(
    workspaceStore.annotations,
    workspaceStore.subscribeAnnotations,
  )
  const diffRows = useSubscribedSnapshot(
    workspaceStore.diffRows,
    workspaceStore.subscribeDiffRows,
  )
  const repositories = useSubscribedValue(
    workspaceStore.repositories,
    workspaceStore.subscribeRepositories,
  )
  const activeRepositoryId = useSubscribedValue(
    workspaceStore.activeRepositoryId,
    workspaceStore.subscribeActiveRepositoryId,
  )
  const workspaceSource = useSubscribedValue(
    workspaceStore.workspaceSource,
    workspaceStore.subscribeWorkspaceSource,
  )
  const workspaceBasePath = useSubscribedValue(
    workspaceStore.workspaceBasePath,
    workspaceStore.subscribeWorkspaceBasePath,
  )
  const workspaceIssues = useSubscribedValue(
    workspaceStore.workspaceIssues,
    workspaceStore.subscribeWorkspaceIssues,
  )
  const [activeFilePath, setActiveFilePath] = useState(activeIdeFile.value)

  useEffect(() => {
    const unsubscribe = activeIdeFile.subscribe(setActiveFilePath)
    return () => unsubscribe()
  }, [])

  const [contextFocus, setContextFocus] = useState(ideContextFocus.value)
  useEffect(() => {
    const unsubscribe = ideContextFocus.subscribe(setContextFocus)
    return () => unsubscribe()
  }, [])

  useEffect(() => {
    const repoId = activeRepositoryId?.trim()
    if (!repoId) {
      cursorOverlaySignal.value = {
        ...cursorOverlaySignal.value,
        stream: { status: 'closed', failedCount: 0 },
      }
      return
    }
    return connectKeeperCursorStream('', (overlay) => {
      cursorOverlaySignal.value = { ...overlay, stream: cursorOverlaySignal.value.stream }
    }, {
      repoId,
      onStatus: stream => {
        cursorOverlaySignal.value = { ...cursorOverlaySignal.value, stream }
      },
    })
  }, [activeRepositoryId])

  const routeFileFocus = routeFocusFile(route.value.params)
  const routeLineFocus = routeFocusLine(route.value.params)
  const routeSurfaceFocus = route.value.params.surface?.trim() || 'Route'
  const routeLabelFocus = routeFileFocus ? routeFocusLabel(route.value.params, routeFileFocus) : ''
  const routeSourceFocus = routeFileFocus
    ? routeFocusSourceId(route.value.params, routeFileFocus, routeLineFocus)
    : ''
  const routeKeeperFocus = route.value.params.keeper?.trim() || undefined
  const routeGoalFocus = routeParam(route.value.params, 'goal_id', 'goal')
  const routeTaskFocus = routeParam(route.value.params, 'task_id', 'task')
  const routeBoardPostFocus = routeParam(route.value.params, 'board_post_id', 'post')
  const routeCommentFocus = routeParam(route.value.params, 'comment_id', 'comment')
  const routePrFocus = routeParam(route.value.params, 'pr_id', 'pr')
  const routeGitFocus = routeParam(route.value.params, 'git_ref', 'ref')
  const routeLogFocus = routeParam(route.value.params, 'log_id', 'log')
  const routeSessionFocus = routeParam(route.value.params, 'session_id')
  const routeOperationFocus = routeParam(route.value.params, 'operation_id', 'op')
  const routeWorkerRunFocus = routeParam(route.value.params, 'worker_run_id', 'worker')
  const routeTelemetryFocus = routeParam(route.value.params, 'telemetry_q', 'q') ?? routeLogFocus

  useEffect(() => {
    if (!routeFileFocus) return
    const telemetry = Boolean(
      routeTelemetryFocus
      || routeSessionFocus
      || routeOperationFocus
      || routeWorkerRunFocus,
    )
    focusIdeContextAnchor({
      file_path: routeFileFocus,
      line: routeLineFocus,
      surface: routeSurfaceFocus,
      label: routeLabelFocus,
      source_id: routeSourceFocus,
      keeper_id: routeKeeperFocus,
      route_links: routeLinksForContext({
        filePath: routeFileFocus,
        line: routeLineFocus,
        surface: routeSurfaceFocus,
        label: routeLabelFocus,
        sourceId: routeSourceFocus,
        goalId: routeGoalFocus,
        taskId: routeTaskFocus,
        boardPostId: routeBoardPostFocus,
        commentId: routeCommentFocus,
        prId: routePrFocus,
        gitRef: routeGitFocus,
        logId: routeLogFocus,
        sessionId: routeSessionFocus,
        operationId: routeOperationFocus,
        workerRunId: routeWorkerRunFocus,
        telemetryQuery: routeTelemetryFocus,
        keeperId: routeKeeperFocus,
        telemetry,
      }),
    })
  }, [
    routeFileFocus,
    routeLineFocus,
    routeSurfaceFocus,
    routeLabelFocus,
    routeSourceFocus,
    routeKeeperFocus,
    routeGoalFocus,
    routeTaskFocus,
    routeBoardPostFocus,
    routeCommentFocus,
    routePrFocus,
    routeGitFocus,
    routeLogFocus,
    routeSessionFocus,
    routeOperationFocus,
    routeWorkerRunFocus,
    routeTelemetryFocus,
  ])

  const activeFocus = focusFromRoute(route.value.params.focus)
  const [activeView, setActiveView] = useState<ViewTab>(() => viewFromRoute(route.value.params.view))
  const lspStatus = useSignalValue(lspStatusSnapshot)
  const reviewFocusActive = activeFocus === 'review' && activeView === 'unified'
  const activeLayers = layersFromRoute(route.value.params.layers, reviewFocusActive ? activeFocus : null)
  const terminalOpen =
    route.value.params.terminal === 'open'
    || Boolean(route.value.params.keeper?.trim())
  const findOpen = route.value.params.find === 'open'
  const terminalKeeper = keeperFromRoute()
  const railsCollapsed = route.value.params.rails === 'hidden'
  const [rightRailTab, setRightRailTab] = useState<IdeRightRailTab>('context')
  const [treeWidth, setTreeWidth] = useState<number>(readStoredIdeTreeWidth)
  const statusbar = deriveIdeStatusbarModel({
    activeView,
    activeLayers,
    activeFilePath,
    contextFocus,
    findOpen,
    terminalOpen,
    railsCollapsed,
    reviewFocusActive,
    routeParams: route.value.params,
    repositories,
    activeRepositoryId,
    workspaceSource,
    workspaceBasePath,
    workspaceIssues,
    dashboardConnected: dashboardRuntimeConnected(),
    lspStatus,
  })

  useEffect(() => {
    const next = viewFromRoute(route.value.params.view)
    setActiveView(current => current === next ? current : next)
  }, [route.value.params.view])

  const handleViewChange = (next: ViewTab) => {
    setActiveView(next)
    const nextParams: Record<string, string> = { ...route.value.params, section: 'ide-shell', view: next }
    if (next !== 'unified' && focusFromRoute(nextParams.focus) === 'review') {
      delete nextParams.focus
      if (nextParams.layers?.trim().toLowerCase() === EMPTY_LAYER_PARAM) delete nextParams.layers
    }
    navigate('code', nextParams)
  }

  const handleLayersChange = (nextLayers: ReadonlySet<string>) => {
    navigate('code', paramsWithLayers(route.value.params, activeView, nextLayers))
  }

  const handleRailsToggle = () => {
    navigate('code', paramsWithRails(route.value.params, activeView, !railsCollapsed))
  }

  const handleTerminalOpen = () => {
    const nextParams: Record<string, string> = {
      ...route.value.params,
      section: 'ide-shell',
      view: activeView,
      terminal: 'open',
    }
    if (terminalKeeper) nextParams.keeper = terminalKeeper
    navigate('code', nextParams)
  }

  // Annotation deletion (#23471 FE follow-up). Mirrors the composer's
  // contract: mutations need a repo scope (keeper_lane is read-only) and
  // ownership is decided server-side from the token identity, so the
  // handler translates each outcome into a toast instead of pre-judging
  // deletability in the FE.
  const handleAnnotationDelete = async (
    annotation: SelectedAnnotation,
  ): Promise<IdeAnnotationDeleteOutcome> => {
    const repoId = workspaceStore.activeRepositoryId()
    if (repoId === null) {
      showToast('주석 삭제에는 repo 선택이 필요합니다 (keeper_lane scope는 read-only)', 'error')
      return 'error'
    }
    const outcome = await deleteIdeAnnotation(annotation.id, { repoId })
    if (outcome === 'deleted') {
      showToast(`주석 삭제됨: ${annotation.file_path}:${annotation.line_start}`, 'success')
      workspaceStore.refresh()
    } else if (outcome === 'forbidden') {
      showToast('주석 삭제 거부 — 본인이 작성한 주석만 삭제할 수 있습니다', 'error')
    } else {
      showToast('주석 삭제 실패 — 서버/네트워크 오류', 'error')
    }
    return outcome
  }

  const handleFindOpen = () => {
    navigate('code', {
      ...route.value.params,
      section: 'ide-shell',
      view: activeView,
      find: 'open',
    })
  }

  const handleFindClose = () => {
    const nextParams: Record<string, string> = {
      ...route.value.params,
      section: 'ide-shell',
      view: activeView,
    }
    delete nextParams.find
    navigate('code', nextParams)
  }

  const setPersistentTreeWidth = (nextWidth: number) => {
    const normalized = normalizeIdeTreeWidth(nextWidth)
    setTreeWidth(normalized)
    writeStoredIdeTreeWidth(normalized)
  }

  const handleTreeResizePointerDown = (event: PointerEvent) => {
    if (event.button !== 0) return
    event.preventDefault()
    const startX = event.clientX
    const startWidth = treeWidth

    const handlePointerMove = (moveEvent: PointerEvent) => {
      setPersistentTreeWidth(startWidth + moveEvent.clientX - startX)
    }
    const stopTracking = () => {
      window.removeEventListener('pointermove', handlePointerMove)
      window.removeEventListener('pointerup', stopTracking)
      window.removeEventListener('pointercancel', stopTracking)
    }

    window.addEventListener('pointermove', handlePointerMove)
    window.addEventListener('pointerup', stopTracking, { once: true })
    window.addEventListener('pointercancel', stopTracking, { once: true })
  }

  const handleTreeResizeKeyDown = (event: KeyboardEvent) => {
    if (event.key === 'ArrowLeft') {
      event.preventDefault()
      setPersistentTreeWidth(treeWidth - 10)
    } else if (event.key === 'ArrowRight') {
      event.preventDefault()
      setPersistentTreeWidth(treeWidth + 10)
    } else if (event.key === 'Home') {
      event.preventDefault()
      setPersistentTreeWidth(IDE_TREE_WIDTH_MIN)
    } else if (event.key === 'End') {
      event.preventDefault()
      setPersistentTreeWidth(IDE_TREE_WIDTH_MAX)
    }
  }

  return html`
    <section
      class="ide-plane-shell ide-v2-surface v2-ide-surface ss-surface bg-surface-page"
      role="region"
      aria-label="Code IDE shell"
      data-terminal-open=${terminalOpen ? 'true' : 'false'}
      data-rails-collapsed=${railsCollapsed ? 'true' : 'false'}
      data-tree-width=${String(treeWidth)}
    >
      <div class="ide-v2-top">
        <header
          class="ide-plane-statusbar"
          aria-label="IDE operational status"
          data-testid="ide-statusbar"
        >
          <span class="ide-plane-statusbar-title">MASC IDE</span>
          <span
            class="chip sm is-warn"
            data-testid="ide-readiness-notice"
            title="IDE shell is observational; LSP, overlay, and shell flows are not a verified execution boundary."
          >experimental</span>
          <span>·</span>
          <span
            class="chip sm is-brass"
            style=${{ flexShrink: 0 }}
            data-testid="ide-statusbar-workspace"
            title=${statusbar.workspaceBasePath
              ? `base_path: ${statusbar.workspaceBasePath} (set MASC_BASE_PATH to change)`
              : undefined}
          >${statusbar.workspaceLabel}</span>
          <${IdeRepoOrigin}
            repositories=${repositories}
            activeRepositoryId=${activeRepositoryId}
          />
          <div
            class="ide-plane-statusbar-meta"
            aria-label="IDE operational context"
          >
            ${statusbar.chips.map(chip => html`
              <span
                key=${chip.id}
                class=${`chip sm is-${chip.tone}`}
                title=${chip.title}
                data-testid=${`ide-statusbar-chip-${chip.id}`}
              >${chip.label}</span>
            `)}
          </div>
          <${IdePresenceStrip} />
          <${IdeDashboardConnectionChip}
            label=${statusbar.connectionLabel}
            tone=${statusbar.connectionTone}
          />
        </header>
        <${IdeToolbar}
          activeView=${activeView}
          activeLayers=${activeLayers}
          onViewChange=${handleViewChange}
          onLayersChange=${handleLayersChange}
          railsCollapsed=${railsCollapsed}
          onRailsToggle=${handleRailsToggle}
          onTerminalOpen=${handleTerminalOpen}
          onFindOpen=${handleFindOpen}
        />
      </div>
      ${reviewFocusActive
        ? html`<${IdeReviewFocusStrip} activeLayers=${activeLayers} />`
        : html`<${IdeBreadcrumb} />`}
      <div
        class="ide-plane-grid ide-v2-body ${railsCollapsed ? 'no-rail' : ''}"
        role="presentation"
        style=${`--ide-tree-width: ${treeWidth}px;`}
      >
        <div class="ide-plane-tree ide-v2-tree v2-ide-panel">
          <${IdeExplorer}
            fileTreeStore=${workspaceStore.fileTreeStore}
            workspaceSource=${workspaceStore.workspaceSource}
            subscribeWorkspaceSource=${workspaceStore.subscribeWorkspaceSource}
            repositories=${workspaceStore.repositories}
            activeRepositoryId=${workspaceStore.activeRepositoryId}
            onRepositoryChange=${workspaceStore.setActiveRepositoryId}
            onRepositoryScan=${workspaceStore.scanRepositories}
            subscribeRepositories=${workspaceStore.subscribeRepositories}
          />
          <button
            type="button"
            class="ide-v2-tree-resize"
            aria-label="Resize file tree"
            aria-orientation="vertical"
            aria-valuemin=${IDE_TREE_WIDTH_MIN}
            aria-valuemax=${IDE_TREE_WIDTH_MAX}
            aria-valuenow=${treeWidth}
            data-testid="ide-tree-resize"
            onPointerDown=${handleTreeResizePointerDown}
            onKeyDown=${handleTreeResizeKeyDown}
          />
        </div>
        <div
          class="ide-plane-editor ide-v2-editor v2-ide-panel"
        >
          <${IdeAnnotationComposer}
            documentStore=${workspaceStore.documentStore}
            activeRepositoryId=${workspaceStore.activeRepositoryId}
            subscribeActiveRepositoryId=${workspaceStore.subscribeActiveRepositoryId}
            refresh=${workspaceStore.refresh}
          />
          <${IdeEditor}
            activeView=${activeView}
            activeLayers=${activeLayers}
            documentStore=${workspaceStore.documentStore}
            ownershipStore=${workspaceStore.ownershipStore}
            diffRows=${() => diffRows}
            findOpen=${findOpen}
            onFindOpen=${handleFindOpen}
            onFindClose=${handleFindClose}
            onKeeperLineSelect=${pinKeeper}
            annotations=${annotations}
            onAnnotationDelete=${handleAnnotationDelete}
          />
          <${OverlayKeeperTrace} active=${activeLayers.has('keeper-trace')} />
        </div>
        ${railsCollapsed
          ? null
          : html`
            <div
              class="ide-plane-conversation ide-v2-rail v2-ide-panel"
              data-testid="ide-right-rail"
            >
              <div class="ide-v2-rail-tabs ide-rail-tabs" role="tablist" aria-label="IDE right rail">
                ${IDE_RIGHT_RAIL_TABS.map(tab => html`
                  <button
                    key=${tab.id}
                    type="button"
                    role="tab"
                    aria-selected=${rightRailTab === tab.id ? 'true' : 'false'}
                    aria-label=${tab.title}
                    title=${tab.title}
                    class=${`ide-v2-rail-tab ide-rail-tab ${rightRailTab === tab.id ? 'on' : ''}`}
                    onClick=${() => setRightRailTab(tab.id)}
                  >${tab.label}</button>
                `)}
              </div>
              <div class="ide-v2-rail-scroll">
                ${rightRailTab === 'context' ? html`
                  <div
                    class="ide-plane-context-stack"
                    data-testid="ide-right-context-stack"
                  >
                    <${IdeKeeperWorkPanel} keeperName=${terminalKeeper} />
                    <${IdePersistencePanel} keeperName=${terminalKeeper} />
                    <${IdeMemoryPanel} keeperName=${terminalKeeper} repoId=${activeRepositoryId} />
                  </div>
                  <div
                    class="ide-plane-primary-rail"
                    data-testid="ide-primary-conversation-rail"
                  >
                    <${IdeConversationRail} />
                  </div>
                ` : null}
                ${rightRailTab === 'activity' ? html`
                  <div class="ide-plane-activity" style=${{ minHeight: 0 }}>
                    <${IdeActivityPanel}
                      activeFile=${activeFilePath}
                      repoId=${activeRepositoryId}
                      keeperLane=${terminalKeeper}
                      annotations=${annotations}
                      diffRows=${diffRows}
                      pollMs=${IDE_ACTIVITY_POLL_MS}
                    />
                  </div>
                ` : null}
                ${rightRailTab === 'cursors' ? html`<${IdeCursorRailPanel} />` : null}
              </div>
            </div>
          `}
      </div>
      ${terminalOpen
        ? html`<${ExecuteOutputDrawer} keeperName=${terminalKeeper} />`
        : null}
      <${IdeInterject} keeperName=${terminalKeeper} />
    </section>
  `
}
