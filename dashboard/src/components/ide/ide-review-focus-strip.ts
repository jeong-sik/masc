import { html } from 'htm/preact'
import { IDE_LAYER_LABELS, REVIEW_FOCUS_LAYERS } from './ide-toolbar'

export function IdeReviewFocusStrip({ activeLayers }: { readonly activeLayers: ReadonlySet<string> }) {
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
      <span class="ml-auto font-mono text-[var(--color-fg-disabled)]">context rail</span>
    </div>
  `
}
