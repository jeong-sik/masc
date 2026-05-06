import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { createIdeDataCoordinator } from './ide-data-coordinator'
import { IdeExplorer } from './ide-explorer'
import { IdeEditor, type IdeEditorView } from './ide-editor'
import { IdeConversationRailMock } from './ide-conversation-rail-mock'
import { IdeActivityMock } from './ide-activity-mock'
import { IdeKeeperWorkPanel } from './ide-keeper-work-panel'
import { IdeInterjectMock } from './ide-interject-mock'
import { KeeperShellDrawer } from './keeper-shell-drawer'
import { IdePresenceStrip } from './ide-presence-strip'
import { IDE_LAYERS, IdeToolbar } from './ide-toolbar'
import { InspectorKeeperBDI, pinInspectorKeeper } from './inspector-keeper-bdi'
import { OverlayKeeperTrace } from './overlay-keeper-trace'
import { IdePersistencePanel } from './ide-persistence-panel'
import { IdeBranchContextPanel } from './ide-branch-context-panel'
import { navigate, route } from '../../router'
import { activeKeeperName } from '../../keeper-state'
import { keepers } from '../../store'
import {
  parseActive,
  serializeActive,
} from '../../../design-system/headless-core/layered-overlay'

export const activeIdeFile = signal<string>('package.json')

type ViewTab = IdeEditorView
const IDE_LAYER_KINDS = new Set(IDE_LAYERS.map(layer => layer.kind))

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

function layersFromRoute(raw: string | null | undefined): ReadonlySet<string> {
  return parseActive(raw ?? '', IDE_LAYER_KINDS)
}

function keeperFromRoute(): string {
  const routeKeeper = route.value.params.keeper?.trim()
  if (routeKeeper) return routeKeeper
  const active = activeKeeperName.value.trim()
  if (active) return active
  return keepers.value[0]?.name?.trim() ?? ''
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
  } else {
    delete next.layers
  }
  return next
}

export function IdeShell() {
  const coordinator = useMemo(() => createIdeDataCoordinator(), [])

  useEffect(() => () => coordinator.dispose(), [coordinator])

  const [activeView, setActiveView] = useState<ViewTab>(() => viewFromRoute(route.value.params.view))
  const activeLayers = layersFromRoute(route.value.params.layers)
  const terminalOpen =
    route.value.params.terminal === 'open'
    || Boolean(route.value.params.keeper?.trim())
  const findOpen = route.value.params.find === 'open'
  const terminalKeeper = keeperFromRoute()

  useEffect(() => {
    const next = viewFromRoute(route.value.params.view)
    setActiveView(current => current === next ? current : next)
  }, [route.value.params.view])

  const handleViewChange = (next: ViewTab) => {
    setActiveView(next)
    navigate('code', { ...route.value.params, section: 'ide-shell', view: next })
  }

  const handleLayersChange = (nextLayers: ReadonlySet<string>) => {
    navigate('code', paramsWithLayers(route.value.params, activeView, nextLayers))
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
    >
      <header
        class="ide-plane-statusbar"
      >
        <span class="ide-plane-statusbar-title">MASC IDE</span>
        <span>·</span>
        <span
          class="chip sm is-brass"
          style=${{ flexShrink: 0 }}
        >LIVE WORKSPACE</span>
        <${IdePresenceStrip} />
        <span class="ide-plane-connection">● mcp · connected</span>
      </header>
      <${IdeToolbar}
        activeView=${activeView}
        activeLayers=${activeLayers}
        onViewChange=${handleViewChange}
        onLayersChange=${handleLayersChange}
        onTerminalOpen=${handleTerminalOpen}
        onFindOpen=${handleFindOpen}
      />
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
            diffRows=${coordinator.diffRows}
            findOpen=${findOpen}
            onFindOpen=${handleFindOpen}
            onFindClose=${handleFindClose}
            onKeeperLineSelect=${pinInspectorKeeper}
          />
          <${OverlayKeeperTrace} active=${activeLayers.has('keeper-trace')} />
        </div>
        <div
          class="ide-plane-conversation"
          style=${{
            display: 'grid',
            gridTemplateRows: 'auto auto auto auto 1fr',
            minHeight: 0,
            overflow: 'auto',
          }}
        >
          <${IdeBranchContextPanel}
            activeRepositoryId=${coordinator.activeRepositoryId}
            subscribeActiveRepositoryId=${coordinator.subscribeActiveRepositoryId}
          />
          <${IdeKeeperWorkPanel} keeperName=${terminalKeeper} />
          <${IdePersistencePanel} keeperName=${terminalKeeper} />
          <${InspectorKeeperBDI} />
          <${IdeConversationRailMock} />
        </div>
        <div class="ide-plane-activity" style=${{ minHeight: 0 }}>
          <${IdeActivityMock} />
        </div>
      </div>
      ${terminalOpen
        ? html`<${KeeperShellDrawer} keeperName=${terminalKeeper} />`
        : null}
      <${IdeInterjectMock} />
    </section>
  `
}
