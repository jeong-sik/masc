import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import {
  createLayeredOverlay,
  type OverlayLayer,
} from '../../../design-system/headless-core/layered-overlay'
import { useLayeredOverlay } from '../../../design-system/headless-preact/use-layered-overlay'
import { CommandBar, type CommandBarAction } from '../common/command-bar'

// Phase 1 PR-3: IDE editor toolbar — view tabs + LAYERS toggle.
// View tabs (SOURCE / SPLIT DIFF / UNIFIED / BLAME) are local UI state
// here; deep linking + editor mode wiring lands in Phase 2 PR-5 once
// the editor itself is real. The LAYERS toggle uses the RFC 0020
// controller from headless-core; overlay rendering still arrives in
// PR-5+ alongside the data sources for each layer.

type ViewTab = 'source' | 'split-diff' | 'unified' | 'blame'

const VIEW_TABS: ReadonlyArray<{ readonly id: ViewTab; readonly label: string }> = [
  { id: 'source', label: 'SOURCE' },
  { id: 'split-diff', label: 'SPLIT DIFF' },
  { id: 'unified', label: 'UNIFIED' },
  { id: 'blame', label: 'BLAME' },
]

export const IDE_LAYERS: ReadonlyArray<OverlayLayer> = [
  { kind: 'time', label: 'Time', description: '변경 timestamp gradient' },
  { kind: 'parallel', label: 'Parallel', description: '동시 keeper 작업 표시' },
  { kind: 'tools', label: 'Tools', description: 'MCP tool 호출' },
  { kind: 'approve', label: 'Approve', description: 'APPROVE thread 마커' },
  { kind: 'notes', label: 'Notes', description: 'NOTE/SUGGEST 마커' },
  { kind: 'cascade', label: 'Cascade', description: 'provider/model/cost/latency gutter chip' },
  {
    kind: 'keeper-trace',
    label: 'Trace',
    description: '4-source stitched gutter chip (anchored-thread / cascade-hop / bdi-snapshot / decision-log)',
    conflictsWith: ['cascade'],
  },
  { kind: 'explode', label: 'EXPLODE', description: 'per-keeper ghost copies', mutuallyExclusive: true },
]

interface IdeToolbarProps {
  readonly activeView: ViewTab
  readonly activeLayers: ReadonlySet<string>
  readonly onViewChange: (id: ViewTab) => void
  readonly onLayersChange: (active: ReadonlySet<string>) => void
  readonly onTerminalOpen?: () => void
}

export function IdeToolbar({
  activeView,
  activeLayers,
  onViewChange,
  onLayersChange,
  onTerminalOpen,
}: IdeToolbarProps) {
  const controller = useMemo(() => {
    const next = createLayeredOverlay(IDE_LAYERS)
    next.setActive(activeLayers)
    return next
  }, [])
  const { active, isActive } = useLayeredOverlay(controller)

  useEffect(() => {
    controller.setActive(activeLayers)
  }, [controller, activeLayers])

  const handleLayerToggle = (kind: string) => {
    controller.toggle(kind)
    onLayersChange(controller.active())
  }

  const commandActions: CommandBarAction[] = [
    ...VIEW_TABS.map(tab => ({
      id: `view-${tab.id}`,
      title: `View: ${tab.label}`,
      keywords: `${tab.id} ${tab.label} editor mode`,
      handler: () => onViewChange(tab.id),
    })),
    ...IDE_LAYERS.map(layer => ({
      id: `layer-${layer.kind}`,
      title: `${isActive(layer.kind) ? 'Hide' : 'Show'} ${layer.label} layer`,
      keywords: `toggle ${layer.kind} ${layer.description}`,
      handler: () => handleLayerToggle(layer.kind),
    })),
    ...(onTerminalOpen
      ? [{
          id: 'terminal-open',
          title: 'Open Keeper Terminal',
          keywords: 'terminal shell keeper output',
          handler: onTerminalOpen,
        }]
      : []),
  ]

  return html`
    <div
      class="ide-toolbar"
      role="toolbar"
      aria-label="IDE editor toolbar"
      style=${{
        display: 'grid',
        gridTemplateColumns: 'auto minmax(180px, 320px) 1fr auto',
        alignItems: 'center',
        gap: 'var(--sp-3)',
        padding: 'var(--sp-2) var(--sp-3)',
        borderBottom: '1px solid var(--color-border-divider)',
        background: 'var(--color-bg-surface)',
      }}
    >
      <div class="ide-toolbar-tabs" role="tablist" aria-label="View mode" style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
        ${VIEW_TABS.map(tab => html`
          <button
            type="button"
            role="tab"
            aria-selected=${tab.id === activeView ? 'true' : 'false'}
            tabIndex=${tab.id === activeView ? 0 : -1}
            onClick=${() => onViewChange(tab.id)}
            style=${{
              padding: '4px 10px',
              background: 'transparent',
              color: tab.id === activeView ? 'var(--color-fg-primary)' : 'var(--color-fg-muted)',
              border: 'none',
              borderBottom: tab.id === activeView ? '2px solid var(--color-accent-fg)' : '2px solid transparent',
              font: 'var(--type-eyebrow)',
              cursor: 'pointer',
            }}
          >${tab.label}</button>
        `)}
      </div>
      <${CommandBar}
        actions=${commandActions}
        placeholder="Run IDE command..."
        testId="ide-command-bar"
        className="min-w-0"
        inputClassName="h-7 w-full rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 font-mono text-2xs text-[var(--color-fg-primary)] outline-none transition-colors placeholder:text-[var(--color-fg-disabled)] focus:border-[var(--color-accent)] focus:ring-1 focus:ring-[var(--color-accent)]"
      />
      <span class="ide-toolbar-spacer" aria-hidden="true" />
      <div
        class="ide-toolbar-layers"
        aria-label="Layers (multi-select)"
        style=${{
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--sp-2)',
          color: 'var(--color-fg-muted)',
          font: 'var(--type-eyebrow)',
        }}
      >
        <span>LAYERS</span>
        ${IDE_LAYERS.map(layer => html`
          <button
            type="button"
            aria-pressed=${isActive(layer.kind) ? 'true' : 'false'}
            onClick=${() => handleLayerToggle(layer.kind)}
            title=${layer.description}
            style=${{
              padding: '2px 8px',
              background: isActive(layer.kind)
                ? 'var(--color-bg-elevated)'
                : 'transparent',
              color: isActive(layer.kind)
                ? 'var(--color-fg-primary)'
                : 'var(--color-fg-secondary)',
              border: '1px solid',
              borderColor: isActive(layer.kind)
                ? layer.mutuallyExclusive
                  ? 'var(--color-status-warn)'
                  : 'var(--color-accent-fg)'
                : 'var(--color-border-default)',
              borderRadius: 'var(--r-1)',
              font: 'var(--type-body)',
              cursor: 'pointer',
            }}
          >${layer.label}</button>
        `)}
        ${active.size > 0
          ? html`<span style=${{ color: 'var(--color-fg-disabled)', font: 'var(--fs-11)' }}>${active.size} active</span>`
          : null}
      </div>
    </div>
  `
}
