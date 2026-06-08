import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { useSubscribedSnapshot, useSubscribedValue } from './use-signal-value'
import {
  activeIdeFile,
  focusIdeContextAnchor,
  ideContextFocus,
} from './ide-state'
import { createIdeDataWorkspaceStore } from './ide-data-workspace-store'
import { IdeExplorer } from './ide-explorer'
import { IdeEditor, type IdeEditorView } from './ide-editor'
import { IdeConversationRail } from './ide-conversation-rail'
import { IdeActivityPanel } from './ide-activity-panel'
import { IdeKeeperWorkPanel } from './ide-keeper-work-panel'
import { IdeInterject } from './ide-interject'
import { ExecuteOutputDrawer } from './execute-output-drawer'
import { IdePresenceStrip } from './ide-presence-strip'
import {
  IDE_LAYERS,
  REVIEW_FOCUS_LAYERS,
  IdeToolbar,
} from './ide-toolbar'
import { IdeBreadcrumb } from './ide-breadcrumb'
import { IdeReviewFocusStrip } from './ide-review-focus-strip'
import { InspectorKeeperBDI } from './inspector-keeper-bdi'
import { pinKeeper } from './multi-keeper-pin-store'
import { OverlayKeeperTrace } from './overlay-keeper-trace'
import { IdePersistencePanel } from './ide-persistence-panel'
import { IdeMemoryPanel } from './ide-memory-panel'
import { routeLinksForContext } from './ide-context-lens'
import { navigate, route } from '../../router'
import { activeKeeperName } from '../../keeper-state'
import { keepers } from '../../store'
import type { Repository } from '../../api/repositories'
import type { WorkspaceSource } from '../../api/workspace-source'
import {
  viewFromRoute,
  focusFromRoute,
  layersFromRoute,
  keeperFromRoute,
  routeFocusFile,
  routeFocusLine,
  routeFocusLabel,
  routeFocusSourceId,
  routeParam,
  paramsWithLayers,
  paramsWithRails,
  EMPTY_LAYER_PARAM,
} from './ide-route-helpers'
import {
  deriveIdeStatusbarModel,
  dashboardRuntimeConnected,
  type IdeStatusbarModel,
  type IdeStatusbarChip,
} from './ide-statusbar-model'

type ViewTab = IdeEditorView

const IDE_ACTIVITY_POLL_MS = 10_000

export function IdeShell() {
  const workspaceStore = useMemo(() => createIdeDataWorkspaceStore(), [])

  useEffect(() => () => workspaceStore.dispose(), [workspaceStore])
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
    contextFocus,
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
            fileTreeStore=${workspaceStore.fileTreeStore}
            workspaceSource=${workspaceStore.workspaceSource}
            subscribeWorkspaceSource=${workspaceStore.subscribeWorkspaceSource}
            repositories=${workspaceStore.repositories}
            activeRepositoryId=${workspaceStore.activeRepositoryId}
            onRepositoryChange=${workspaceStore.setActiveRepositoryId}
            onRepositoryScan=${workspaceStore.scanRepositories}
            subscribeRepositories=${workspaceStore.subscribeRepositories}
          />
        </div>
        <div
          class="ide-plane-editor"
        >
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
                <${IdeKeeperWorkPanel} keeperName=${terminalKeeper} />
                <${IdePersistencePanel} keeperName=${terminalKeeper} />
                <${IdeMemoryPanel} keeperName=${terminalKeeper} />
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
        ? html`<${ExecuteOutputDrawer} keeperName=${terminalKeeper} />`
        : null}
      <${IdeInterject} keeperName=${terminalKeeper} />
    </section>
  `
}

