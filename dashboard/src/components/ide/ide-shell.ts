import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { IdeExplorer } from './ide-explorer'
import { IdeEditorMock } from './ide-editor-mock'
import { IdeConversationRailMock } from './ide-conversation-rail-mock'
import { IdeActivityMock } from './ide-activity-mock'
import { IdeInterjectMock } from './ide-interject-mock'
import { IDE_LAYERS, IdeToolbar } from './ide-toolbar'
import { navigate, route } from '../../router'
import {
  parseActive,
  serializeActive,
} from '../../../design-system/headless-core/layered-overlay'

// PR-3: 4-pane CODE mode shell with editor toolbar (view tabs + LAYERS
// toggle, RFC 0020 controller). Layout matches the cockpit IdePlane
// prototype's grid (`design-system/ui_kits/cockpit/cockpit.css`
// `.ide-v2-tree / .ide-v2-center / .ide-v2-right / .ide-v2-terminal`);
// production tokens are v0.4 Semantic-tier only.
//
// Each child mock cites the implementation PR that replaces it:
//   EXPLORER          -> Phase 2 PR-4 (file-tree-store, RFC 0014)
//   editor            -> Phase 2 PR-5 (Shiki + RFC 0019 blame)
//   CONVERSATION rail -> Phase 2 PR-6 (RFC 0021)
//   ACTIVITY          -> Phase 2 PR-6 (sse-store-backed stream)
//   INTERJECT         -> Phase 2 PR-7 (keeper-actions wiring)
//
// Audit reference:
//   dashboard/design-system/audits/2026-04-30-ide-mockup-vs-v0.4-mapping.md

type ViewTab = 'source' | 'split-diff' | 'unified' | 'blame'
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
      aria-label="Code IDE shell (Phase 1 PR-3 — toolbar + 4-pane mock)"
      style=${{
        display: 'grid',
        gridTemplateRows: 'auto auto 1fr auto',
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
        <span>* runtime / main / nick0cave@dkr-a1 / improver@wt-run-47</span>
        <span style=${{ marginLeft: 'auto', color: 'var(--color-status-ok, var(--ok))' }}>● mcp · connected</span>
      </header>
      <${IdeToolbar}
        activeView=${activeView}
        activeLayers=${activeLayers}
        onViewChange=${handleViewChange}
        onLayersChange=${handleLayersChange}
      />
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
        <div class="ide-plane-editor" style=${{ minHeight: 0 }}>
          <${IdeEditorMock} />
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
