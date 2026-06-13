import { html } from 'htm/preact'
import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import { KeeperBadge } from '../keeper-badge'
import type { LineOwnership } from './keeper-line-ownership-store'

const IDE_LAYER_ORDER = ['time', 'parallel', 'tools', 'approve', 'notes', 'runtime', 'keeper-trace', 'explode'] as const
export type IdeLayerKind = (typeof IDE_LAYER_ORDER)[number]

const LAYER_LABEL: Record<IdeLayerKind, string> = {
  time: 'Time',
  parallel: 'Parallel',
  tools: 'Tools',
  approve: 'Approve',
  notes: 'Notes',
  runtime: 'Runtime',
  'keeper-trace': 'Trace',
  explode: 'EXPLODE',
}

export function editorGridRows(hasLayerSummary: boolean, findOpen: boolean): string {
  const rows = ['auto']
  if (hasLayerSummary) rows.push('auto')
  if (findOpen) rows.push('auto')
  rows.push('1fr')
  return rows.join(' ')
}

export function activeLayersInDisplayOrder(activeLayers: ReadonlySet<string>): ReadonlyArray<IdeLayerKind> {
  return IDE_LAYER_ORDER.filter(kind => activeLayers.has(kind))
}

export function BlameTimeline(
  ownership: ReadonlyMap<number, LineOwnership>,
  keepers: ReadonlyArray<string>,
) {
  const latestEdit = latestEditMs(ownership)
  const stats = keeperOwnershipStats(ownership, keepers)
  return html`
    <div
      class="ide-blame-timeline"
      role="status"
      aria-label="Blame timeline"
    >
      <span class="ide-blame-title">BLAME</span>
      <span class="ide-blame-summary">${ownership.size} owned lines</span>
      <span class="ide-blame-keepers">
        ${stats.length > 0
          ? stats.map(stat => html`
              <span class="ide-blame-keeper" title=${`${stat.keeper}: ${stat.lines} lines`}>
                <${KeeperBadge} id=${stat.keeper} variant="sigil" size="sm" />
                <span>${stat.lines}</span>
              </span>
            `)
          : html`<span class="ide-blame-empty">no keeper edits</span>`}
      </span>
      <span class="ide-blame-latest">latest ${latestEdit === null ? 'no edits' : formatTime(latestEdit)}</span>
    </div>
  `
}

export function LayerOverlaySummary(
  activeLayerKinds: ReadonlyArray<IdeLayerKind>,
  ownership: ReadonlyMap<number, LineOwnership>,
  keepers: ReadonlyArray<string>,
  annotations: ReadonlyArray<IdeAnnotation>,
) {
  const annotationCount = annotations.length
  const latestEdit = latestEditMs(ownership)
  return html`
    <div
      role="status"
      aria-label="Active IDE overlays"
      style=${{
        display: 'flex',
        alignItems: 'center',
        gap: 'var(--sp-2)',
        padding: 'var(--sp-2) var(--sp-3)',
        borderBottom: '1px solid var(--color-border-divider)',
        color: 'var(--color-fg-muted)',
        background: 'var(--color-bg-surface)',
        fontSize: 'var(--fs-11)',
        overflowX: 'auto',
      }}
    >
      <span style=${{ font: 'var(--type-eyebrow)', color: 'var(--color-fg-primary)' }}>Active overlays</span>
      ${activeLayerKinds.map(kind => html`
        <span
          style=${{
            display: 'inline-flex',
            alignItems: 'center',
            gap: 'var(--sp-1)',
            padding: '1px var(--sp-2)',
            border: '1px solid var(--color-border-default)',
            borderRadius: 'var(--r-2)',
            background: kind === 'explode' ? 'var(--color-bg-muted)' : 'var(--color-bg-elevated)',
            color: kind === 'explode' ? 'var(--color-accent-fg)' : 'var(--color-fg-secondary)',
            whiteSpace: 'nowrap',
          }}
        >
          <span>${layerLabel(kind)}</span>
          <span style=${{ color: 'var(--color-fg-muted)' }}>${layerSummary(kind, latestEdit, keepers, annotationCount)}</span>
        </span>
      `)}
    </div>
  `
}

function latestEditMs(ownership: ReadonlyMap<number, LineOwnership>): number | null {
  let latest: number | null = null
  for (const owner of ownership.values()) {
    if (latest === null || owner.last_edit_ms > latest) latest = owner.last_edit_ms
  }
  return latest
}

function keeperOwnershipStats(
  ownership: ReadonlyMap<number, LineOwnership>,
  keepers: ReadonlyArray<string>,
): ReadonlyArray<{ keeper: string; lines: number }> {
  const counts = new Map<string, number>()
  for (const owner of ownership.values()) {
    counts.set(owner.keeper_id, (counts.get(owner.keeper_id) ?? 0) + 1)
  }
  for (const keeper of keepers) {
    if (!counts.has(keeper)) counts.set(keeper, 0)
  }
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([keeper, lines]) => ({ keeper, lines }))
}

function formatTime(ms: number): string {
  return new Date(ms).toISOString().slice(11, 16)
}

function layerLabel(kind: IdeLayerKind): string {
  return LAYER_LABEL[kind]
}

function layerSummary(kind: IdeLayerKind, latestEdit: number | null, keepers: ReadonlyArray<string>, annotationCount: number = 0): string {
  if (kind === 'time') return latestEdit === null ? 'no edits' : `latest ${formatTime(latestEdit)}`
  if (kind === 'parallel') return `${keepers.length} keepers`
  if (kind === 'tools') return '0 anchored'
  if (kind === 'approve') return '0 approval'
  if (kind === 'notes') return annotationCount === 1 ? '1 note' : `${annotationCount} notes`
  if (kind === 'runtime') return '0 hits'
  if (kind === 'keeper-trace') return 'stitched trace'
  if (kind === 'explode') return 'exclusive ghost view'
  return ''
}
