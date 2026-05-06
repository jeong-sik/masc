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

const TOOLBAR_BUTTON_BASE =
  'h-7 shrink-0 cursor-pointer rounded-[var(--r-1)] px-2 font-mono text-2xs uppercase tracking-[var(--track-caps)] transition-colors'

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
      role="toolbar"
      aria-label="IDE editor toolbar"
      data-testid="ide-toolbar"
      class="ide-toolbar grid min-w-0 grid-cols-1 items-center gap-2 border-b border-[var(--color-border-divider)] bg-[var(--color-bg-surface)] px-3 py-2 lg:grid-cols-[minmax(0,max-content)_minmax(12rem,16rem)_minmax(0,1fr)]"
    >
      <div
        class="ide-toolbar-tabs flex min-w-0 gap-1.5 overflow-x-auto pb-0.5"
        role="tablist"
        aria-label="View mode"
        data-testid="ide-toolbar-tabs"
      >
        ${VIEW_TABS.map(tab => html`
          <button
            type="button"
            role="tab"
            aria-selected=${tab.id === activeView ? 'true' : 'false'}
            tabIndex=${tab.id === activeView ? 0 : -1}
            onClick=${() => onViewChange(tab.id)}
            class=${TOOLBAR_BUTTON_BASE}
            style=${{
              background: 'transparent',
              color: tab.id === activeView ? 'var(--color-fg-primary)' : 'var(--color-fg-muted)',
              border: '1px solid transparent',
              borderBottom: tab.id === activeView ? '2px solid var(--color-accent-fg)' : '2px solid transparent',
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
      <div
        aria-label="Layers (multi-select)"
        data-testid="ide-toolbar-layers"
        class="ide-toolbar-layers flex min-w-0 items-center gap-1.5 overflow-x-auto pb-0.5 font-mono text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]"
      >
        <span class="shrink-0">LAYERS</span>
        ${IDE_LAYERS.map(layer => html`
          <button
            type="button"
            aria-pressed=${isActive(layer.kind) ? 'true' : 'false'}
            onClick=${() => handleLayerToggle(layer.kind)}
            title=${layer.description}
            class=${TOOLBAR_BUTTON_BASE}
            style=${{
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
            }}
          >${layer.label}</button>
        `)}
        ${active.size > 0
          ? html`<span class="shrink-0 text-[var(--color-fg-disabled)]">${active.size} active</span>`
          : null}
      </div>
    </div>
  `
}
