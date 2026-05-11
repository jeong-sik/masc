import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { activeIdeFile } from './ide-state'
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

// Re-export to preserve the public path used by existing callers. The
// canonical source now lives in `./ide-state` to avoid circular imports.
export { activeIdeFile }

type ViewTab = IdeEditorView
type IdeFocus = 'review'

const IDE_LAYER_KINDS = new Set(IDE_LAYERS.map(layer => layer.kind))
const IDE_LAYER_LABELS = new Map(IDE_LAYERS.map(layer => [layer.kind, layer.label]))
export const REVIEW_FOCUS_LAYERS = ['keeper-trace', 'approve', 'notes'] as const
const REVIEW_FOCUS_LAYER_PARAM = REVIEW_FOCUS_LAYERS.join(',')
const EMPTY_LAYER_PARAM = 'none'

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
            diffRows=${coordinator.diffRows}
            findOpen=${findOpen}
            onFindOpen=${handleFindOpen}
            onFindClose=${handleFindClose}
            onKeeperLineSelect=${pinInspectorKeeper}
            annotations=${coordinator.annotations}
          />
          <${OverlayKeeperTrace} active=${activeLayers.has('keeper-trace')} />
        </div>
        ${railsCollapsed
          ? null
          : html`
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
              <${InspectorKeeperBDI} traceActive=${activeLayers.has('keeper-trace')} />
              <${IdeConversationRailMock} />
            </div>
          `}
        ${railsCollapsed
          ? null
          : html`
            <div class="ide-plane-activity" style=${{ minHeight: 0 }}>
              <${IdeActivityMock} />
            </div>
          `}
      </div>
      ${terminalOpen
        ? html`<${KeeperShellDrawer} keeperName=${terminalKeeper} />`
        : null}
      <${IdeInterjectMock} keeperName=${terminalKeeper} />
    </section>
  `
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
  useEffect(() => activeIdeFile.subscribe(f => setFilePath(f)), [])

  const segments = filePath.split('/')
  // segments is non-empty because String.prototype.split('/') always returns ≥1 element
  // (even '' → ['']), but TS noUncheckedIndexedAccess requires a fallback.
  const fileName = segments[segments.length - 1] ?? ''
  const ext = fileName.includes('.') ? fileName.slice(fileName.lastIndexOf('.')) : ''
  const icon = FILE_ICONS[ext] ?? '📄'

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
          <span key=${`breadcrumb-seg-${i}`}>
            ${i > 0 ? html`<span class="text-[var(--color-fg-disabled)]">/</span>` : null}
            <span
              class=${i === segments.length - 1 ? 'text-[var(--color-fg-primary)]' : ''}
              style=${{ whiteSpace: 'nowrap' }}
            >${seg}</span>
          </span>
        `)}
      </span>
    </div>
  `
}
