import { html } from 'htm/preact'
import type { UnifiedDiffRow } from '../../api/workspace'
import { StatusChip } from '../common/status-chip'

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

export interface DiffLineRange {
  readonly start: number | null
  readonly end: number | null
}

export interface DiffSummary {
  readonly total: number
  readonly additions: number
  readonly deletions: number
  readonly context: number
  readonly changed: number
  readonly oldRange: DiffLineRange
  readonly newRange: DiffLineRange
}

// ── Unified diff view ─────────────────────────────────────────────

export function UnifiedDiffView(rows: ReadonlyArray<UnifiedDiffRow>) {
  const summary = summarizeDiffRows(rows)
  return html`
    <div
      role="region"
      aria-label="Unified diff preview"
      style=${{
        display: 'grid',
        gridTemplateRows: 'auto minmax(0, 1fr)',
        minHeight: 0,
        overflow: 'hidden',
        fontFamily: 'var(--font-mono)',
        fontSize: 'var(--fs-13)',
        lineHeight: 1.6,
      }}
    >
      <${DiffSummaryStrip} summary=${summary} mode="Unified" />
      ${summary.total === 0
        ? DiffEmptyState('No diff rows for the selected file.')
        : html`
          <ol
            aria-label="Unified diff rows"
            style=${{
              listStyle: 'none',
              padding: 'var(--sp-2) 0',
              margin: 0,
              overflow: 'auto',
            }}
          >
            ${rows.map(row => html`
              <li
                style=${{
                  display: 'grid',
                  gridTemplateColumns: '32px 40px 40px minmax(0, 1fr)',
                  gap: 'var(--sp-2)',
                  alignItems: 'start',
                  padding: '0 var(--sp-3)',
                  background: diffBackground(row.kind),
                  color: row.kind === 'delete' ? 'var(--color-status-danger, var(--color-fg-secondary))' : 'var(--color-fg-secondary)',
                }}
              >
                <span style=${{ color: diffMarkerColor(row.kind), textAlign: 'center' }}>${diffMarker(row.kind)}</span>
                <span style=${{ color: 'var(--color-fg-disabled)', fontSize: 'var(--fs-11)', textAlign: 'right' }}>${row.oldLine ?? ''}</span>
                <span style=${{ color: 'var(--color-fg-disabled)', fontSize: 'var(--fs-11)', textAlign: 'right' }}>${row.newLine ?? ''}</span>
                <span style=${{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere', minWidth: 0 }}>${row.text}</span>
              </li>
            `)}
          </ol>
        `}
    </div>
  `
}

// ── Diff summary strip ────────────────────────────────────────────

function DiffSummaryStrip({
  summary,
  mode,
}: {
  readonly summary: DiffSummary
  readonly mode: 'Unified' | 'Split'
}) {
  // In Split mode buildSplitDiff visually pairs each delete with its add on
  // the same row, so additions+deletions over-counts the visible "changed
  // rows". Use max(additions,deletions) — that matches one logical row per
  // pair plus any unpaired add/delete. Unified mode keeps the linear count.
  const changedRows = mode === 'Split'
    ? Math.max(summary.additions, summary.deletions)
    : summary.changed
  return html`
    <div
      role="status"
      aria-label=${formatDiffSummaryAria(summary, mode)}
      style=${{
        display: 'flex',
        alignItems: 'center',
        flexWrap: 'wrap',
        gap: 'var(--sp-2)',
        minWidth: 0,
        padding: 'var(--sp-2) var(--sp-3)',
        borderBottom: '1px solid var(--color-border-divider)',
        background: 'var(--color-bg-surface)',
        color: 'var(--color-fg-muted)',
        font: 'var(--type-eyebrow)',
      }}
    >
      <span style=${{ color: 'var(--color-fg-secondary)' }}>${mode} diff</span>
      <span style=${{ color: 'var(--color-fg-disabled)' }}>${changedRows} changed rows</span>
      <span
        style=${{
          display: 'inline-flex',
          alignItems: 'center',
          flexWrap: 'wrap',
          gap: 'var(--sp-1)',
          minWidth: 0,
        }}
      >
        <${StatusChip} tone="ok" uppercase=${false}>+${summary.additions}</${StatusChip}>
        <${StatusChip} tone="bad" uppercase=${false}>-${summary.deletions}</${StatusChip}>
        <${StatusChip} tone="neutral" uppercase=${false}>${summary.context} context</${StatusChip}>
        <${StatusChip} tone="info" uppercase=${false}>old ${formatDiffLineRange(summary.oldRange)} -> new ${formatDiffLineRange(summary.newRange)}</${StatusChip}>
      </span>
    </div>
  `
}

function DiffEmptyState(label: string) {
  return html`
    <div
      role="note"
      style=${{
        display: 'grid',
        placeItems: 'center',
        minHeight: '120px',
        padding: 'var(--sp-4)',
        color: 'var(--color-fg-muted)',
        background: 'var(--color-bg-page)',
        font: 'var(--type-body)',
        fontSize: 'var(--fs-12)',
        textAlign: 'center',
      }}
    >
      ${label}
    </div>
  `
}

// ── Split diff view ───────────────────────────────────────────────

export function SplitDiffView(rows: ReadonlyArray<UnifiedDiffRow>) {
  const summary = summarizeDiffRows(rows)
  const splitRows: SplitDiffRow[] = buildSplitDiff(rows)
  return html`
    <div
      role="region"
      aria-label="Split diff preview"
      style=${{
        display: 'grid',
        gridTemplateRows: 'auto auto minmax(0, 1fr)',
        minHeight: 0,
        overflow: 'hidden',
        fontFamily: 'var(--font-mono)',
        fontSize: 'var(--fs-13)',
        lineHeight: 1.6,
      }}
    >
      <${DiffSummaryStrip} summary=${summary} mode="Split" />
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
        ${splitRows.length === 0
          ? DiffEmptyState('No split diff rows for the selected file.')
          : splitRows.map(row => html`
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
        alignItems: 'start',
        minHeight: '24px',
        padding: '0 var(--sp-3)',
        borderLeft: framed ? '1px solid var(--color-border-divider)' : undefined,
        background: cell ? diffBackground(kind) : 'var(--color-bg-muted)',
        color: kind === 'delete' ? 'var(--color-status-danger, var(--color-fg-secondary))' : 'var(--color-fg-secondary)',
      }}
    >
      <span style=${{ color: 'var(--color-fg-disabled)', fontSize: 'var(--fs-11)', textAlign: 'right' }}>${cell?.line ?? ''}</span>
      <span style=${{ color: diffMarkerColor(kind), textAlign: 'center' }}>${cell ? diffMarker(kind) : ''}</span>
      <span style=${{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere', minWidth: 0 }}>${cell?.text ?? ''}</span>
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

// ── Summary helpers ───────────────────────────────────────────────

export function summarizeDiffRows(rows: ReadonlyArray<UnifiedDiffRow>): DiffSummary {
  let additions = 0
  let deletions = 0
  let context = 0
  let oldStart: number | null = null
  let oldEnd: number | null = null
  let newStart: number | null = null
  let newEnd: number | null = null

  for (const row of rows) {
    if (row.kind === 'add') {
      additions += 1
    } else if (row.kind === 'delete') {
      deletions += 1
    } else {
      context += 1
    }
    if (row.oldLine != null) {
      oldStart = oldStart == null ? row.oldLine : Math.min(oldStart, row.oldLine)
      oldEnd = oldEnd == null ? row.oldLine : Math.max(oldEnd, row.oldLine)
    }
    if (row.newLine != null) {
      newStart = newStart == null ? row.newLine : Math.min(newStart, row.newLine)
      newEnd = newEnd == null ? row.newLine : Math.max(newEnd, row.newLine)
    }
  }

  return {
    total: rows.length,
    additions,
    deletions,
    context,
    changed: additions + deletions,
    oldRange: { start: oldStart, end: oldEnd },
    newRange: { start: newStart, end: newEnd },
  }
}

export function formatDiffLineRange(range: DiffLineRange): string {
  if (range.start == null || range.end == null) return 'n/a'
  if (range.start === range.end) return `${range.start}`
  return `${range.start}-${range.end}`
}

export function formatDiffSummaryAria(summary: DiffSummary, mode: 'Unified' | 'Split'): string {
  return `${mode} diff summary: ${summary.additions} ${pluralize('addition', summary.additions)}, ${summary.deletions} ${pluralize('deletion', summary.deletions)}, ${summary.context} context ${pluralize('row', summary.context)}, old lines ${formatDiffLineRange(summary.oldRange)}, new lines ${formatDiffLineRange(summary.newRange)}`
}

function pluralize(noun: string, count: number): string {
  return count === 1 ? noun : `${noun}s`
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
