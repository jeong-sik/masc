import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import {
  createLayeredOverlay,
  type OverlayLayer,
} from '../../../design-system/headless-core/layered-overlay'
import { useLayeredOverlay } from '../../../design-system/headless-preact/use-layered-overlay'

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

const LAYERS: ReadonlyArray<OverlayLayer> = [
  { kind: 'time', label: 'Time', description: '변경 timestamp gradient' },
  { kind: 'parallel', label: 'Parallel', description: '동시 keeper 작업 표시' },
  { kind: 'tools', label: 'Tools', description: 'MCP tool 호출' },
  { kind: 'approve', label: 'Approve', description: 'APPROVE thread 마커' },
  { kind: 'notes', label: 'Notes', description: 'NOTE/SUGGEST 마커' },
  { kind: 'explode', label: 'EXPLODE', description: 'per-keeper ghost copies', mutuallyExclusive: true },
]

interface IdeToolbarProps {
  readonly activeView: ViewTab
  readonly onViewChange: (id: ViewTab) => void
}

export function IdeToolbar({ activeView, onViewChange }: IdeToolbarProps) {
  const controller = useMemo(() => createLayeredOverlay(LAYERS), [])
  const { active, toggle, isActive } = useLayeredOverlay(controller)

  return html`
    <div
      role="toolbar"
      aria-label="IDE editor toolbar"
      style=${{
        display: 'grid',
        gridTemplateColumns: 'auto 1fr auto',
        alignItems: 'center',
        gap: 'var(--sp-3)',
        padding: 'var(--sp-2) var(--sp-3)',
        borderBottom: '1px solid var(--color-border-divider)',
        background: 'var(--color-bg-surface)',
      }}
    >
      <div role="tablist" aria-label="View mode" style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
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
      <span aria-hidden="true" />
      <div
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
        ${LAYERS.map(layer => html`
          <button
            type="button"
            aria-pressed=${isActive(layer.kind) ? 'true' : 'false'}
            onClick=${() => toggle(layer.kind)}
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
                  ? 'var(--color-status-warn, var(--warn))'
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
