import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { activeIdeFile, focusIdeContextAnchor } from './ide-state'
import { createIdeDataCoordinator } from './ide-data-coordinator'
import { IdeExplorer } from './ide-explorer'
import { IdeEditor, type IdeEditorView } from './ide-editor'
import { IdeConversationRail } from './ide-conversation-rail'
import { IdeActivityPanel } from './ide-activity-panel'
import { IdeKeeperWorkPanel } from './ide-keeper-work-panel'
import { IdeInterject } from './ide-interject'
import { KeeperShellDrawer } from './keeper-shell-drawer'
import { IdePresenceStrip } from './ide-presence-strip'
import { IDE_LAYERS, IdeToolbar } from './ide-toolbar'
import { InspectorKeeperBDI, pinInspectorKeeper } from './inspector-keeper-bdi'
import { OverlayKeeperTrace } from './overlay-keeper-trace'
import { IdePersistencePanel } from './ide-persistence-panel'
import { IdeBranchContextPanel } from './ide-branch-context-panel'
import { cursorOverlaySignal, getKeeperColor, type KeeperCursor } from './keeper-cursor-overlay'
import { routeLinksForContext } from './ide-context-lens'
import { navigate, route } from '../../router'
import { activeKeeperName } from '../../keeper-state'
import { keepers } from '../../store'
import { connected } from '../../sse'
import { dashboardWsOnlyEnabled } from '../../dashboard-ws-cutover'
import { dashboardWsConnected, dashboardWsSseFallbackActive } from '../../dashboard-ws-state'
import type { Repository } from '../../api/repositories'
import type { WorkspaceSource } from '../../api/workspace-source'
import {
  parseActive,
  serializeActive,
} from '../../../design-system/headless-core/layered-overlay'

// Re-export to preserve the public path used by existing callers. The
// canonical source now lives in `./ide-state` to avoid circular imports.
export { activeIdeFile }

type ViewTab = IdeEditorView
type IdeFocus = 'review'
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

const IDE_LAYER_KINDS = new Set(IDE_LAYERS.map(layer => layer.kind))
const IDE_LAYER_LABELS = new Map(IDE_LAYERS.map(layer => [layer.kind, layer.label]))
const IDE_ACTIVITY_POLL_MS = 10_000
export const REVIEW_FOCUS_LAYERS = ['keeper-trace', 'approve', 'notes'] as const
const REVIEW_FOCUS_LAYER_PARAM = REVIEW_FOCUS_LAYERS.join(',')
const EMPTY_LAYER_PARAM = 'none'
const STATUSBAR_LAYER_PRIORITY: ReadonlyArray<string> = [
  'keeper-trace',
  'approve',
  'notes',
  'cascade',
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

interface IdeStatusbarInput {
  readonly activeView: ViewTab
  readonly activeLayers: ReadonlySet<string>
  readonly activeFilePath: string
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

function viewFromRoute(raw: string | null | undefined): ViewTab {
  const normalized = raw
    ?.trim()
    .toLowerCase()
    .replace(/[_\s]+/g, '-')
  if (normalized === 'split' || normalized === 'split-diff' || normalized === 'merge') return 'split-diff'
  if (normalized === 'unified') return 'unified'
  if (normalized === 'blame') return 'blame'
  return 'source'
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
  if (!/^[1-9]\d*$/.test(raw)) return undefined
  const value = Number.parseInt(raw, 10)
  return Number.isSafeInteger(value) && value >= 1 ? value : undefined
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
      return statusbarRepositoryLabel(activeStatusbarRepository(repositories, activeRepositoryId)) ?? 'workspace'
  }
}

function dashboardRuntimeConnected(): boolean {
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
    shortStatusbarPath(activeFilePath),
    'ghost',
    `Active file: ${activeFilePath.trim() || 'no file'}`,
  )

  const layerLabel = statusbarLayerLabel(activeLayers)
  addStatusbarChip(chips, 'layers', layerLabel ?? undefined, 'info', layerLabel ? `Active layers: ${layerLabel}` : '')
  if (terminalOpen) addStatusbarChip(chips, 'terminal', 'terminal', 'info', 'Keeper shell drawer open')
  if (findOpen) addStatusbarChip(chips, 'find', 'find', 'ghost', 'Current-file find panel open')
  if (railsCollapsed) addStatusbarChip(chips, 'rails', 'rails hidden', 'ghost', 'IDE side rails hidden')

  const routeLine = routeFocusLine(routeParams)
  const routeSurface = routeParams.surface?.trim()
  const routeLabel = routeParams.label?.trim()
  const routeFocusParts = [
    routeSurface,
    routeLine ? `L${routeLine}` : undefined,
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
  const task = routeParam(routeParams, 'task_id', 'task')
  const board = routeParam(routeParams, 'board_post_id', 'post')
  const comment = routeParam(routeParams, 'comment_id', 'comment')
  const pr = routeParam(routeParams, 'pr_id', 'pr')
  const git = routeParam(routeParams, 'git_ref', 'ref')
  const log = routeParam(routeParams, 'log_id', 'log')
  const telemetry = statusbarTelemetryLabel(routeParams)
  const keeper = routeParam(routeParams, 'keeper')

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

export function IdeShell() {
  const coordinator = useMemo(() => createIdeDataCoordinator(), [])

  useEffect(() => () => coordinator.dispose(), [coordinator])
  const annotations = useSubscribedSnapshot(
    coordinator.annotations,
    coordinator.subscribeAnnotations,
  )
  const diffRows = useSubscribedSnapshot(
    coordinator.diffRows,
    coordinator.subscribeDiffRows,
  )
  const repositories = useSubscribedValue(
    coordinator.repositories,
    coordinator.subscribeRepositories,
  )
  const activeRepositoryId = useSubscribedValue(
    coordinator.activeRepositoryId,
    coordinator.subscribeActiveRepositoryId,
  )
  const workspaceSource = useSubscribedValue(
    coordinator.workspaceSource,
    coordinator.subscribeWorkspaceSource,
  )
  const [activeFilePath, setActiveFilePath] = useState(activeIdeFile.value)

  useEffect(() => {
    const unsubscribe = activeIdeFile.subscribe(setActiveFilePath)
    return () => unsubscribe()
  }, [])

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
  const reviewFocusActive = activeFocus === 'review' && activeView === 'unified'
  const activeLayers = layersFromRoute(route.value.params.layers, reviewFocusActive ? activeFocus : null)
  const terminalOpen =
    route.value.params.terminal === 'open'
    || Boolean(route.value.params.keeper?.trim())
  const findOpen = route.value.params.find === 'open'
  const terminalKeeper = keeperFromRoute()
  const railsCollapsed = route.value.params.rails === 'hidden'
  const statusbar = deriveIdeStatusbarModel({
    activeView,
    activeLayers,
    activeFilePath,
    findOpen,
    terminalOpen,
    railsCollapsed,
    reviewFocusActive,
    routeParams: route.value.params,
    repositories,
    activeRepositoryId,
    workspaceSource,
    dashboardConnected: dashboardRuntimeConnected(),
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

  return html`
    <section
      class="ide-plane-shell"
      role="region"
      aria-label="Code IDE shell"
      data-terminal-open=${terminalOpen ? 'true' : 'false'}
      data-rails-collapsed=${railsCollapsed ? 'true' : 'false'}
    >
      <header
        class="ide-plane-statusbar"
        aria-label="IDE operational status"
        data-testid="ide-statusbar"
      >
        <span class="ide-plane-statusbar-title">MASC IDE</span>
        <span>·</span>
        <span
          class="chip sm is-brass"
          style=${{ flexShrink: 0 }}
          data-testid="ide-statusbar-workspace"
        >${statusbar.workspaceLabel}</span>
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
        <span
          class="ide-plane-connection"
          data-state=${statusbar.connectionTone}
        >● ${statusbar.connectionLabel}</span>
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
      ${reviewFocusActive
        ? html`<${IdeReviewFocusStrip} activeLayers=${activeLayers} />`
        : html`<${IdeBreadcrumb} />`}
      <div
        class="ide-plane-grid"
        role="presentation"
      >
        <div class="ide-plane-tree">
          <${IdeExplorer}
            fileTreeStore=${coordinator.fileTreeStore}
            workspaceSource=${coordinator.workspaceSource}
            subscribeWorkspaceSource=${coordinator.subscribeWorkspaceSource}
            repositories=${coordinator.repositories}
            activeRepositoryId=${coordinator.activeRepositoryId}
            onRepositoryChange=${coordinator.setActiveRepositoryId}
            onRepositoryScan=${coordinator.scanRepositories}
            subscribeRepositories=${coordinator.subscribeRepositories}
          />
        </div>
        <div
          class="ide-plane-editor"
        >
          <${IdeEditor}
            activeView=${activeView}
            activeLayers=${activeLayers}
            documentStore=${coordinator.documentStore}
            ownershipStore=${coordinator.ownershipStore}
            diffRows=${() => diffRows}
            findOpen=${findOpen}
            onFindOpen=${handleFindOpen}
            onFindClose=${handleFindClose}
            onKeeperLineSelect=${pinInspectorKeeper}
            annotations=${annotations}
          />
          <${OverlayKeeperTrace} active=${activeLayers.has('keeper-trace')} />
        </div>
        ${railsCollapsed
          ? null
          : html`
            <div
              class="ide-plane-conversation"
              data-testid="ide-right-rail"
            >
              <div
                class="ide-plane-context-stack"
                data-testid="ide-right-context-stack"
              >
                <${IdeBranchContextPanel}
                  activeRepositoryId=${coordinator.activeRepositoryId}
                  subscribeActiveRepositoryId=${coordinator.subscribeActiveRepositoryId}
                />
                <${IdeKeeperWorkPanel} keeperName=${terminalKeeper} />
                <${IdePersistencePanel} keeperName=${terminalKeeper} />
                <${InspectorKeeperBDI} traceActive=${activeLayers.has('keeper-trace')} />
              </div>
              <div
                class="ide-plane-primary-rail"
                data-testid="ide-primary-conversation-rail"
              >
                <${IdeConversationRail} />
              </div>
            </div>
          `}
        ${railsCollapsed
          ? null
          : html`
            <div class="ide-plane-activity" style=${{ minHeight: 0 }}>
              <${IdeActivityPanel}
                activeFile=${activeFilePath}
                annotations=${annotations}
                diffRows=${diffRows}
                pollMs=${IDE_ACTIVITY_POLL_MS}
              />
            </div>
          `}
      </div>
      ${terminalOpen
        ? html`<${KeeperShellDrawer} keeperName=${terminalKeeper} />`
        : null}
      <${IdeInterject} keeperName=${terminalKeeper} />
    </section>
  `
}

function useSubscribedSnapshot<T>(
  read: () => ReadonlyArray<T>,
  subscribe: (listener: () => void) => () => void,
): ReadonlyArray<T> {
  const [value, setValue] = useState<ReadonlyArray<T>>(() => read())

  useEffect(() => {
    let current = read()
    setValue(previous => previous === current ? previous : current)

    let sawInitialSnapshot = false
    return subscribe(() => {
      const next = read()
      if (!sawInitialSnapshot) {
        sawInitialSnapshot = true
        if (next === current) return
      }
      current = next
      setValue(previous => previous === next ? previous : next)
    })
  }, [read, subscribe])

  return value
}

function useSubscribedValue<T>(
  read: () => T,
  subscribe: (listener: () => void) => () => void,
): T {
  const [value, setValue] = useState<T>(() => read())

  useEffect(() => {
    setValue(read())
    return subscribe(() => {
      setValue(read())
    })
  }, [read, subscribe])

  return value
}

function IdeReviewFocusStrip({ activeLayers }: { readonly activeLayers: ReadonlySet<string> }) {
  const layerLabels = REVIEW_FOCUS_LAYERS
    .filter(layer => activeLayers.has(layer))
    .map(layer => IDE_LAYER_LABELS.get(layer) ?? layer)

  return html`
    <div
      data-testid="ide-review-focus"
      class="flex flex-wrap items-center gap-2 border-b border-[var(--color-border-divider)] bg-[var(--color-bg-elevated)] px-3 py-2 text-2xs text-[var(--color-fg-muted)]"
    >
      <span class="font-mono uppercase tracking-[var(--track-caps)] text-[var(--color-accent-fg)]">review focus</span>
      <span class="font-mono">UNIFIED</span>
      <span class="text-[var(--color-fg-disabled)]">·</span>
      <span class="font-mono">${layerLabels.length > 0 ? layerLabels.join(' / ') : 'custom layers'}</span>
      <span class="ml-auto font-mono text-[var(--color-fg-disabled)]">branch graph rail</span>
    </div>
  `
}

// ── Editor Breadcrumb ────────────────────────────────────────────

const FILE_ICONS: Readonly<Record<string, string>> = {
  '.ts': '🟦', '.tsx': '🟦',
  '.js': '🟨', '.jsx': '🟨',
  '.py': '🐍', '.ml': '🐫', '.mli': '🐫',
  '.rs': '🦀', '.go': '🔵',
  '.json': '📋', '.md': '📝',
  '.html': '🌐', '.css': '🎨',
  '.toml': '⚙️', '.yaml': '⚙️', '.yml': '⚙️',
}

function IdeBreadcrumb() {
  const [filePath, setFilePath] = useState(activeIdeFile.value)
  useEffect(() => {
    const unsub = activeIdeFile.subscribe(f => setFilePath(f))
    return () => unsub()
  }, [])

  const [overlay, setOverlay] = useState(cursorOverlaySignal.value)
  useEffect(() => {
    const unsub = cursorOverlaySignal.subscribe(v => setOverlay(v))
    return () => unsub()
  }, [])

  const segments = filePath.split('/')
  const fileName = segments.at(-1) ?? ""
  const ext = fileName.includes('.') ? fileName.slice(fileName.lastIndexOf('.')) : ''
  const icon = FILE_ICONS[ext] ?? '📄'

  // Keepers currently on this file with activity detail
  const activeOnFile: Array<{
    readonly keeperId: string
    readonly color: string
    readonly focusMode: KeeperCursor['focus_mode']
    readonly toolName: string | undefined
    readonly turn: number | undefined
  }> = []
  for (const [keeperId, cursor] of overlay.cursors) {
    if (cursor.file_path === filePath) {
      activeOnFile.push({
        keeperId,
        color: getKeeperColor(keeperId).cursor,
        focusMode: cursor.focus_mode,
        toolName: cursor.tool_name,
        turn: cursor.turn,
      })
    }
  }

  return html`
    <div
      role="navigation"
      aria-label="File breadcrumb"
      data-testid="ide-breadcrumb"
      class="flex items-center gap-1.5 border-b border-[var(--color-border-divider)] bg-[var(--color-bg-elevated)] px-3 py-1 font-mono text-2xs"
    >
      <span aria-hidden="true" style=${{ fontSize: '12px', lineHeight: '16px' }}>${icon}</span>
      <span
        class="flex min-w-0 items-center gap-0.5 text-[var(--color-fg-secondary)]"
        style=${{ overflow: 'hidden' }}
      >
        ${segments.map((seg, i) => html`
          ${i > 0 ? html`<span class="text-[var(--color-fg-disabled)]">/</span>` : null}
          <span
            class=${i === segments.length - 1 ? 'text-[var(--color-fg-primary)]' : ''}
            style=${{ whiteSpace: 'nowrap' }}
          >${seg}</span>
        `)}
      </span>
      ${activeOnFile.length > 0
        ? html`
          <span class="flex items-center gap-1 ml-auto shrink-0">
            ${activeOnFile.map(k => html`
              <span
                key=${k.keeperId}
                class="flex items-center gap-1"
                title=${`${k.keeperId} · ${k.focusMode}${k.toolName ? ` · ${k.toolName}` : ''}${k.turn != null ? ` · turn ${k.turn}` : ''}`}
                style=${{ color: 'var(--color-fg-muted)' }}
              >
                <span
                  aria-hidden="true"
                  style=${{
                    width: '7px',
                    height: '7px',
                    borderRadius: '50%',
                    background: k.color,
                    display: 'inline-block',
                    boxShadow: k.focusMode === 'editing' ? `0 0 4px ${k.color}` : 'none',
                  }}
                />
                <span>${k.keeperId}</span>
                ${k.toolName ? html`<span class="text-[var(--color-fg-disabled)]" style=${{ fontSize: '10px' }}>${k.toolName}</span>` : null}
                ${k.turn != null ? html`<span style=${{ fontSize: '10px', color: 'var(--color-accent-fg)' }}>T${k.turn}</span>` : null}
              </span>
            `)}
          </span>
        `
        : null}
    </div>
  `
}
