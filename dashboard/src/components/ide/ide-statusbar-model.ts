import type { Repository } from '../../api/repositories'
import type { WorkspaceSource } from '../../api/workspace-source'
import { dashboardWsOnlyEnabled } from '../../dashboard-ws-cutover'
import { dashboardWsConnected, dashboardWsSseFallbackActive } from '../../dashboard-ws-state'
import { connected } from '../../sse'
import type { IdeContextFocus, IdeContextFocusRouteLink } from './ide-state'
import { IDE_LAYER_LABELS } from './ide-toolbar'
import type { IdeEditorView } from './ide-editor'
import { routeFocusLine, routeParam } from './ide-route-helpers'

type IdeStatusbarChipTone = 'brass' | 'ghost' | 'info' | 'ok'
type IdeConnectionTone = 'ok' | 'warn'

export interface IdeStatusbarChip {
  readonly id: string
  readonly label: string
  readonly tone: IdeStatusbarChipTone
  readonly title: string
}

export interface IdeStatusbarModel {
  readonly workspaceLabel: string
  readonly chips: ReadonlyArray<IdeStatusbarChip>
  readonly connectionLabel: string
  readonly connectionTone: IdeConnectionTone
}

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

const STATUSBAR_VIEW_LABELS: Readonly<Record<IdeEditorView, string>> = {
  source: 'SOURCE',
  unified: 'UNIFIED',
  'split-diff': 'SPLIT DIFF',
  blame: 'BLAME',
}

export interface IdeStatusbarInput {
  readonly activeView: IdeEditorView
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
  readonly dashboardConnected?: boolean
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

export function dashboardRuntimeConnected(): boolean {
  if (dashboardWsOnlyEnabled()) {
    return dashboardWsConnected.value || dashboardWsSseFallbackActive.value
  }
  return connected.value
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
  dashboardConnected = false,
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
    chips,
    connectionLabel: dashboardConnected ? 'runtime · live' : 'runtime · reconnecting',
    connectionTone: dashboardConnected ? 'ok' : 'warn',
  }
}
