import { html } from 'htm/preact'
import type { UnifiedDiffRow } from '../../api/workspace'

// ── Shared diff types ─────────────────────────────────────────────

type DiffTone = 'context' | 'add' | 'delete'

interface SplitDiffCell {
  readonly line: number | null
  readonly text: string
  readonly kind: DiffTone
}

export interface SplitDiffRow {
  readonly before: SplitDiffCell | null
  readonly after: SplitDiffCell | null
}

// ── Unified diff view ─────────────────────────────────────────────

export function UnifiedDiffView(rows: ReadonlyArray<UnifiedDiffRow>) {
  return html`
    <ol
      aria-label="Unified diff preview"
      style=${{
        listStyle: 'none',
        padding: 'var(--sp-2) 0',
        margin: 0,
        overflow: 'auto',
        fontFamily: 'var(--font-mono)',
        fontSize: 'var(--fs-13)',
        lineHeight: 1.6,
      }}
    >
      ${rows.map(row => html`
        <li
          style=${{
            display: 'grid',
            gridTemplateColumns: '32px 40px 40px minmax(0, 1fr)',
            gap: 'var(--sp-2)',
            alignItems: 'center',
            padding: '0 var(--sp-3)',
            background: diffBackground(row.kind),
            color: row.kind === 'delete' ? 'var(--color-status-danger, var(--color-fg-secondary))' : 'var(--color-fg-secondary)',
          }}
        >
          <span style=${{ color: diffMarkerColor(row.kind), textAlign: 'center' }}>${diffMarker(row.kind)}</span>
          <span style=${{ color: 'var(--color-fg-disabled)', fontSize: 'var(--fs-11)', textAlign: 'right' }}>${row.oldLine ?? ''}</span>
          <span style=${{ color: 'var(--color-fg-disabled)', fontSize: 'var(--fs-11)', textAlign: 'right' }}>${row.newLine ?? ''}</span>
          <span style=${{ whiteSpace: 'pre', minWidth: 0 }}>${row.text}</span>
        </li>
      `)}
    </ol>
  `
}

// ── Split diff view ───────────────────────────────────────────────

export function SplitDiffView(rows: ReadonlyArray<UnifiedDiffRow>) {
  const splitRows: SplitDiffRow[] = buildSplitDiff(rows)
  return html`
    <div
      aria-label="Split diff preview"
      style=${{
        display: 'grid',
        gridTemplateRows: 'auto 1fr',
        minHeight: 0,
        overflow: 'hidden',
        fontFamily: 'var(--font-mono)',
        fontSize: 'var(--fs-13)',
        lineHeight: 1.6,
      }}
    >
      <div
        style=${{
          display: 'grid',
          gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)',
          borderBottom: '1px solid var(--color-border-divider)',
          font: 'var(--type-eyebrow)',
          color: 'var(--color-fg-muted)',
          background: 'var(--color-bg-surface)',
        }}
      >
        <span style=${{ padding: 'var(--sp-2) var(--sp-3)' }}>BEFORE</span>
        <span style=${{ padding: 'var(--sp-2) var(--sp-3)', borderLeft: '1px solid var(--color-border-divider)' }}>AFTER</span>
      </div>
      <div style=${{ overflow: 'auto' }}>
        ${splitRows.map(row => html`
          <div
            style=${{
              display: 'grid',
              gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)',
            }}
          >
            <${SplitDiffCellView} cell=${row.before} />
            <${SplitDiffCellView} cell=${row.after} framed=${true} />
          </div>
        `)}
      </div>
    </div>
  `
}

function SplitDiffCellView({
  cell,
  framed = false,
}: {
  readonly cell: SplitDiffCell | null
  readonly framed?: boolean
}) {
  const kind = cell?.kind ?? 'context'
  return html`
    <div
      style=${{
        display: 'grid',
        gridTemplateColumns: '40px 24px minmax(0, 1fr)',
        gap: 'var(--sp-2)',
        alignItems: 'center',
        minHeight: '24px',
        padding: '0 var(--sp-3)',
        borderLeft: framed ? '1px solid var(--color-border-divider)' : undefined,
        background: cell ? diffBackground(kind) : 'var(--color-bg-muted)',
        color: kind === 'delete' ? 'var(--color-status-danger, var(--color-fg-secondary))' : 'var(--color-fg-secondary)',
      }}
    >
      <span style=${{ color: 'var(--color-fg-disabled)', fontSize: 'var(--fs-11)', textAlign: 'right' }}>${cell?.line ?? ''}</span>
      <span style=${{ color: diffMarkerColor(kind), textAlign: 'center' }}>${cell ? diffMarker(kind) : ''}</span>
      <span style=${{ whiteSpace: 'pre', minWidth: 0 }}>${cell?.text ?? ''}</span>
    </div>
  `
}

// ── Diff helpers ──────────────────────────────────────────────────

function diffMarker(kind: string): string {
  if (kind === 'add') return '+'
  if (kind === 'delete') return '-'
  return ' '
}

function diffBackground(kind: string): string {
  if (kind === 'add') return 'var(--color-status-ok-bg, var(--color-bg-surface))'
  if (kind === 'delete') return 'var(--color-status-danger-bg, var(--color-bg-surface))'
  return 'transparent'
}

function diffMarkerColor(kind: string): string {
  if (kind === 'add') return 'var(--color-status-ok, var(--ok))'
  if (kind === 'delete') return 'var(--color-status-danger, var(--danger))'
  return 'var(--color-fg-disabled)'
}

// ── Split diff builder ────────────────────────────────────────────

export function buildSplitDiff(rows: ReadonlyArray<UnifiedDiffRow>): SplitDiffRow[] {
  const result: SplitDiffRow[] = []
  const adds: UnifiedDiffRow[] = []
  const deletes: UnifiedDiffRow[] = []
  for (const row of rows) {
    if (row.kind === 'context') {
      flushPending()
      result.push({
        before: { kind: 'context', line: row.oldLine, text: row.text },
        after: { kind: 'context', line: row.newLine, text: row.text },
      })
    } else if (row.kind === 'delete') {
      deletes.push(row)
    } else if (row.kind === 'add') {
      adds.push(row)
    }
  }
  flushPending()
  return result

  function flushPending(): void {
    const max = Math.max(deletes.length, adds.length)
    for (let i = 0; i < max; i++) {
      const del = deletes[i]
      const add = adds[i]
      result.push({
        before: del ? { kind: 'delete', line: del.oldLine, text: del.text } : null,
        after: add ? { kind: 'add', line: add.newLine, text: add.text } : null,
      })
    }
    deletes.length = 0
    adds.length = 0
  }
}
