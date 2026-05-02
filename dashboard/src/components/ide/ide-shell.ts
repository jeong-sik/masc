import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { IdeExplorer } from './ide-explorer'
import { IdeEditorMock, type IdeEditorView } from './ide-editor-mock'
import { IdeConversationRailMock } from './ide-conversation-rail-mock'
import { IdeActivityMock } from './ide-activity-mock'
import { IdeInterjectMock } from './ide-interject-mock'
import { IdePresenceStrip } from './ide-presence-strip'
import { IDE_LAYERS, IdeToolbar } from './ide-toolbar'
import { WorldVisualizer } from '../world-visualizer'
import { COCKPIT_FRAME_SRC, shouldLoadCockpitFrame } from '../cockpit/cockpit-frame'
import { navigate, route } from '../../router'
import {
  parseActive,
  serializeActive,
} from '../../../design-system/headless-core/layered-overlay'

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

function CockpitPreview() {
  if (!shouldLoadCockpitFrame()) {
    return html`
      <section
        aria-label="MASC Cockpit preview"
        style=${{
          minHeight: 0,
          borderTop: '1px solid var(--color-border-divider)',
          background: '#000',
        }}
      />
    `
  }

  return html`
    <section
      aria-label="MASC Cockpit preview"
      style=${{
        display: 'grid',
        gridTemplateRows: 'auto 1fr',
        minHeight: 0,
        borderTop: '1px solid var(--color-border-divider)',
        background: '#000',
      }}
    >
      <div
        style=${{
          padding: 'var(--sp-2) var(--sp-3)',
          borderBottom: '1px solid rgba(255,255,255,0.12)',
          color: 'rgba(255,255,255,0.68)',
          font: 'var(--type-eyebrow)',
        }}
      >
        MASC Cockpit
      </div>
      <iframe
        src=${COCKPIT_FRAME_SRC}
        style=${{ width: '100%', height: '100%', minHeight: 0, border: 'none' }}
        title="MASC Dream IDE Cockpit"
      />
    </section>
  `
}

export function IdeShell() {
  const [activeView, setActiveView] = useState<ViewTab>(() => viewFromRoute(route.value.params.view))
  const activeLayers = layersFromRoute(route.value.params.layers)

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

  return html`
    <section
      class="ide-plane-shell"
      role="region"
      aria-label="Code IDE shell"
      style=${{
        display: 'grid',
        gridTemplateRows: 'auto auto auto 1fr auto',
        background: 'var(--color-bg-page)',
        color: 'var(--color-fg-primary)',
        minHeight: 'calc(100vh - var(--h-topbar) - var(--h-kpi))',
      }}
    >
      <header
        style=${{
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--sp-3)',
          padding: 'var(--sp-2) var(--sp-3)',
          background: 'var(--color-bg-surface)',
          borderBottom: '1px solid var(--color-border-default)',
          font: 'var(--type-eyebrow)',
          color: 'var(--color-fg-muted)',
        }}
      >
        <span style=${{ color: 'var(--color-fg-secondary)' }}>코드 IDE</span>
        <span>·</span>
        <${IdePresenceStrip} />
        <span style=${{ marginLeft: 'auto', color: 'var(--color-status-ok, var(--ok))' }}>● mcp · connected</span>
      </header>
      <${IdeToolbar}
        activeView=${activeView}
        activeLayers=${activeLayers}
        onViewChange=${handleViewChange}
        onLayersChange=${handleLayersChange}
      />
      <div style=${{ borderBottom: '1px solid var(--color-border-divider)' }}>
        <${WorldVisualizer} />
      </div>
      <div
        class="ide-plane-grid"
        role="presentation"
        style=${{
          minHeight: 0,
        }}
      >
        <div class="ide-plane-tree">
          <${IdeExplorer} />
        </div>
        <div
          class="ide-plane-editor"
          style=${{
            display: 'grid',
            gridTemplateRows: 'minmax(280px, 1fr) minmax(260px, 38vh)',
            minHeight: 0,
          }}
        >
          <${IdeEditorMock} activeView=${activeView} activeLayers=${activeLayers} />
          <${CockpitPreview} />
        </div>
        <div class="ide-plane-conversation" style=${{ minHeight: 0 }}>
          <${IdeConversationRailMock} />
        </div>
        <div class="ide-plane-activity" style=${{ minHeight: 0 }}>
          <${IdeActivityMock} />
        </div>
      </div>
      <${IdeInterjectMock} />
    </section>
  `
}
