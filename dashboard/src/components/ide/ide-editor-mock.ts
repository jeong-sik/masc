import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useMemo, useState, useEffect } from 'preact/hooks'
import { activeKeeperName } from '../../keeper-state'
import { activeIdeFile } from './ide-shell'
import {
  createCodeDocumentStore,
  type CodeDocumentLine,
} from './code-document-store'
import { CodeLineText, useHighlightedCodeLines } from './ide-code-renderer'
import {
  createKeeperLineOwnershipStore,
  type LineOwnership,
} from './keeper-line-ownership-store'
import type { KeeperEditKind } from '../../../design-system/headless-core/keeper-line-ownership'
import { languageFromPath } from './language-detection'

const IDE_LAYER_ORDER = ['time', 'parallel', 'tools', 'approve', 'notes', 'explode'] as const
type IdeLayerKind = (typeof IDE_LAYER_ORDER)[number]

// PR-5 precursor: the editor remains a read-only fixture, but source document,
// blame-by-keeper ownership, view state, and layer affordances now flow through
// typed contracts. The syntax renderer is deliberately read-only and keeps the
// same CodeDocumentLine + LineOwnership contracts for a future CodeMirror swap.

export type IdeEditorView = 'source' | 'split-diff' | 'unified' | 'blame'

interface IdeEditorMockProps {
  readonly activeView?: IdeEditorView
  readonly activeLayers?: ReadonlySet<string>
  readonly children?: ComponentChildren
}

type DiffTone = 'context' | 'add' | 'delete'

interface UnifiedDiffRow {
  readonly kind: DiffTone
  readonly oldLine: number | null
  readonly newLine: number | null
  readonly text: string
}

interface SplitDiffCell {
  readonly line: number | null
  readonly text: string
  readonly kind: DiffTone
}

interface SplitDiffRow {
  readonly before: SplitDiffCell | null
  readonly after: SplitDiffCell | null
}

const EMPTY_ACTIVE_LAYERS: ReadonlySet<string> = new Set()

interface BlameBlock {
  readonly file_path: string
  readonly line_start: number
  readonly line_end: number
  readonly keeper_id: string
  readonly timestamp_ms: number
  readonly kind: string
}

async function fetchBlame(path: string): Promise<BlameBlock[]> {
  try {
    const res = await fetch('/api/v1/git/blame?path=' + encodeURIComponent(path))
    if (!res.ok) return []
    const data = await res.json()
    return Array.isArray(data) ? data : []
  } catch { return [] }
}

async function fetchDiff(path: string, baseRef = 'HEAD'): Promise<UnifiedDiffRow[]> {
  try {
    const res = await fetch('/api/v1/git/diff?path=' + encodeURIComponent(path) + '&base_ref=' + encodeURIComponent(baseRef))
    if (!res.ok) return []
    const data = await res.json()
    return Array.isArray(data.unified) ? data.unified : []
  } catch { return [] }
}

const VIEW_LABEL: Record<IdeEditorView, string> = {
  source: 'SOURCE',
  'split-diff': 'SPLIT DIFF',
  unified: 'UNIFIED',
  blame: 'BLAME',
}

const LAYER_LABEL: Record<IdeLayerKind, string> = {
  time: 'Time',
  parallel: 'Parallel',
  tools: 'Tools',
  approve: 'Approve',
  notes: 'Notes',
  explode: 'EXPLODE',
}

export function IdeEditorMock({
  activeView = 'source',
  activeLayers = EMPTY_ACTIVE_LAYERS,
}: IdeEditorMockProps) {
  const [sourceCode, setSourceCode] = useState<string[]>([])
  const [keeperName, setKeeperName] = useState(activeKeeperName.value)
  useEffect(() => activeKeeperName.subscribe(name => setKeeperName(name)), [])

  useEffect(() => {
    let canceled = false;
    const params = new URLSearchParams({ path: activeIdeFile.value })
    if (keeperName) params.set('keeper', keeperName)
    fetch('/api/v1/workspace/file?' + params.toString())
      .then(r => r.json())
      .then(d => {
        if (!canceled && d.ok && d.content) {
          setSourceCode(d.content.split('\n'));
        }
      })
      .catch(console.error);
    return () => { canceled = true };
  }, [activeIdeFile.value, keeperName]);

  const documentStore = useMemo(
    () => createCodeDocumentStore({
      file_path: activeIdeFile.value,
      language: languageFromPath(activeIdeFile.value),
      content: sourceCode,
    }),
    [sourceCode, activeIdeFile.value],
  )
  const ownershipStore = useMemo(() => {
    const store = createKeeperLineOwnershipStore(activeIdeFile.value)
    return store
  }, [activeIdeFile.value])

  useEffect(() => {
    let cancelled = false
    fetchBlame(activeIdeFile.value).then(blocks => {
      if (cancelled) return
      ownershipStore.reset(activeIdeFile.value)
      for (const block of blocks) {
        ownershipStore.ingest({
          file_path: block.file_path,
          line_start: block.line_start,
          line_end: block.line_end,
          keeper_id: block.keeper_id,
          timestamp_ms: block.timestamp_ms,
          kind: block.kind as KeeperEditKind,
        })
      }
    })
    return () => { cancelled = true }
  }, [activeIdeFile.value, ownershipStore])

  const [diffRows, setDiffRows] = useState<UnifiedDiffRow[]>([])
  useEffect(() => {
    let cancelled = false
    fetchDiff(activeIdeFile.value).then(rows => {
      if (!cancelled) setDiffRows(rows)
    })
    return () => { cancelled = true }
  }, [activeIdeFile.value])

  const document = documentStore.document()
  const lines = documentStore.lines()
  const ownership = ownershipStore.ownership()
  const keepers = ownershipStore.knownKeepers()
  const highlightedLines = useHighlightedCodeLines(document)
  const activeLayerKinds = activeLayersInDisplayOrder(activeLayers)

  return html`
    <div
      role="region"
      aria-label="에디터 (code document store + RFC 0019 ownership mock)"
      style=${{
        display: 'grid',
        gridTemplateRows: activeLayerKinds.length > 0 ? 'auto auto 1fr' : 'auto 1fr',
        background: 'var(--color-bg-page)',
        minHeight: 0,
      }}
    >
      <div
        style=${{
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--sp-3)',
          padding: 'var(--sp-2) var(--sp-3)',
          borderBottom: '1px solid var(--color-border-divider)',
          color: 'var(--color-fg-muted)',
          font: 'var(--type-eyebrow)',
        }}
      >
        <span>${document.file_path}</span>
        <span style=${{ color: 'var(--color-fg-disabled)' }}>${document.language}</span>
        <span style=${{ color: 'var(--color-accent-fg)' }}>${VIEW_LABEL[activeView]}</span>
        <span style=${{ marginLeft: 'auto' }}>
          ${lines.length} lines · ownership · ${keepers.length} keepers · ${activeLayerKinds.length} layers
        </span>
      </div>
      ${activeLayerKinds.length > 0
        ? LayerOverlaySummary(activeLayerKinds, ownership, keepers)
        : null}
      ${EditorViewport(activeView, lines, ownership, highlightedLines, activeLayerKinds, keepers, diffRows)}
    </div>
  `
}

function EditorViewport(
  activeView: IdeEditorView,
  lines: ReadonlyArray<CodeDocumentLine>,
  ownership: ReadonlyMap<number, LineOwnership>,
  highlightedLines: ReadonlyArray<string>,
  activeLayerKinds: ReadonlyArray<IdeLayerKind>,
  keepers: ReadonlyArray<string>,
  diffRows: ReadonlyArray<UnifiedDiffRow>,
) {
  if (activeView === 'split-diff') return SplitDiffView(diffRows)
  if (activeView === 'unified') return UnifiedDiffView(diffRows)
  if (activeView === 'blame') {
    return html`
      <div style=${{ display: 'grid', gridTemplateRows: 'auto 1fr', minHeight: 0 }}>
        <${BlameTimeline} ownership=${ownership} keepers=${keepers} />
        ${SourceRows(lines, ownership, highlightedLines, activeLayerKinds, 'Blame editor view')}
      </div>
    `
  }
  return SourceRows(lines, ownership, highlightedLines, activeLayerKinds, 'Source editor view')
}

function SourceRows(
  lines: ReadonlyArray<CodeDocumentLine>,
  ownership: ReadonlyMap<number, LineOwnership>,
  highlightedLines: ReadonlyArray<string>,
  activeLayerKinds: ReadonlyArray<IdeLayerKind>,
  ariaLabel: string,
) {
  return html`
    <ol
      aria-label=${ariaLabel}
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
      ${lines.map(line => MockEditorRow(
        line,
        ownership.get(line.num),
        highlightedLines[line.num - 1],
        activeLayerKinds,
      ))}
    </ol>
  `
}

function BlameTimeline({
  ownership,
  keepers,
}: {
  readonly ownership: ReadonlyMap<number, LineOwnership>
  readonly keepers: ReadonlyArray<string>
}) {
  const latestEdit = latestEditMs(ownership)
  return html`
    <div
      role="status"
      aria-label="Blame timeline"
      style=${{
        display: 'flex',
        alignItems: 'center',
        gap: 'var(--sp-2)',
        padding: 'var(--sp-2) var(--sp-3)',
        borderBottom: '1px solid var(--color-border-divider)',
        color: 'var(--color-fg-muted)',
        background: 'var(--color-bg-surface)',
        fontSize: 'var(--fs-11)',
      }}
    >
      <span style=${{ font: 'var(--type-eyebrow)', color: 'var(--color-fg-primary)' }}>Blame timeline</span>
      <span>${keepers.join(' / ')}</span>
      <span style=${{ marginLeft: 'auto', color: 'var(--color-fg-secondary)' }}>
        latest ${latestEdit === null ? 'no edits' : formatTime(latestEdit)}
      </span>
    </div>
  `
}

function UnifiedDiffView(rows: ReadonlyArray<UnifiedDiffRow>) {
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

function SplitDiffView(rows: ReadonlyArray<UnifiedDiffRow>) {
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

function keeperColor(owner: LineOwnership | undefined): string {
  return owner
    ? `var(--color-keeper-${owner.hue_index}-glow, var(--k-${owner.hue_index}))`
    : 'var(--color-fg-disabled)'
}

function MockEditorRow(
  line: CodeDocumentLine,
  owner: LineOwnership | undefined,
  highlightedHtml: string | undefined,
  activeLayerKinds: ReadonlyArray<IdeLayerKind>,
) {
  const color = keeperColor(owner)
  const dot = owner
    ? color
    : 'transparent'
  const chips = rowLayerChips(line, owner, activeLayerKinds)
  return html`
    <li
      style=${{
        display: 'grid',
        gridTemplateColumns: '88px 16px 32px minmax(0, 1fr) max-content',
        gap: 'var(--sp-2)',
        alignItems: 'center',
        padding: '0 var(--sp-3)',
      }}
    >
      <span
        title=${owner ? `${owner.keeper_id} · ${owner.last_edit_kind}` : undefined}
        style=${{
          color,
          fontSize: 'var(--fs-11)',
          textAlign: 'right',
        }}
      >${owner?.keeper_id ?? '—'}</span>
      <span aria-hidden="true" style=${{ width: '6px', height: '6px', borderRadius: '50%', background: dot, justifySelf: 'center' }} />
      <span style=${{ color: 'var(--color-fg-disabled)', fontSize: 'var(--fs-11)', minWidth: '24px', textAlign: 'right' }}>${line.num}</span>
      <${CodeLineText} line=${line} highlightedHtml=${highlightedHtml} />
      <span
        aria-label=${chips.length > 0 ? `line ${line.num} active overlays: ${chips.join(', ')}` : undefined}
        style=${{
          display: 'inline-flex',
          gap: 'var(--sp-1)',
          minWidth: '72px',
          justifyContent: 'flex-end',
        }}
      >
        ${chips.map(chip => html`
          <span
            style=${{
              padding: '0 var(--sp-1)',
              border: '1px solid var(--color-border-muted)',
              borderRadius: 'var(--r-1)',
              color: 'var(--color-fg-muted)',
              background: 'var(--color-bg-surface)',
              fontSize: 'var(--fs-10)',
              lineHeight: 1.4,
            }}
          >${chip}</span>
        `)}
      </span>
    </li>
  `
}

function diffMarker(kind: DiffTone): string {
  if (kind === 'add') return '+'
  if (kind === 'delete') return '-'
  return ' '
}

function diffBackground(kind: DiffTone): string {
  if (kind === 'add') return 'var(--color-status-ok-bg, var(--color-bg-surface))'
  if (kind === 'delete') return 'var(--color-status-danger-bg, var(--color-bg-surface))'
  return 'transparent'
}

function diffMarkerColor(kind: DiffTone): string {
  if (kind === 'add') return 'var(--color-status-ok, var(--ok))'
  if (kind === 'delete') return 'var(--color-status-danger, var(--danger))'
  return 'var(--color-fg-disabled)'
}

function activeLayersInDisplayOrder(activeLayers: ReadonlySet<string>): ReadonlyArray<IdeLayerKind> {
  return IDE_LAYER_ORDER.filter(kind => activeLayers.has(kind))
}

function LayerOverlaySummary(
  activeLayerKinds: ReadonlyArray<IdeLayerKind>,
  ownership: ReadonlyMap<number, LineOwnership>,
  keepers: ReadonlyArray<string>,
) {
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
          <span style=${{ color: 'var(--color-fg-muted)' }}>${layerSummary(kind, latestEdit, keepers)}</span>
        </span>
      `)}
    </div>
  `
}

function rowLayerChips(
  _line: CodeDocumentLine,
  owner: LineOwnership | undefined,
  activeLayerKinds: ReadonlyArray<IdeLayerKind>,
): ReadonlyArray<string> {
  const chips: string[] = []
  for (const kind of activeLayerKinds) {
    if (kind === 'time' && owner) pushUnique(chips, formatTime(owner.last_edit_ms))
    else if (kind === 'parallel' && owner) pushUnique(chips, owner.last_edit_kind)
    else if (kind === 'explode' && owner) pushUnique(chips, 'ghost')
    else {
      // annotation layers (tools, approve, notes) require a backend API — not yet available
    }
  }
  return chips
}

function pushUnique(items: string[], item: string): void {
  if (!items.includes(item)) items.push(item)
}

function latestEditMs(ownership: ReadonlyMap<number, LineOwnership>): number | null {
  let latest: number | null = null
  for (const owner of ownership.values()) {
    if (latest === null || owner.last_edit_ms > latest) latest = owner.last_edit_ms
  }
  return latest
}

function layerLabel(kind: IdeLayerKind): string {
  return LAYER_LABEL[kind]
}

function layerSummary(kind: IdeLayerKind, latestEdit: number | null, keepers: ReadonlyArray<string>): string {
  if (kind === 'time') return latestEdit === null ? 'no edits' : `latest ${formatTime(latestEdit)}`
  if (kind === 'parallel') return `${keepers.length} keepers`
  if (kind === 'tools') return '0 anchored'
  if (kind === 'approve') return '0 approval'
  if (kind === 'notes') return '0 note'
  if (kind === 'explode') return 'exclusive ghost view'
  return ''
}

function formatTime(ms: number): string {
  return new Date(ms).toISOString().slice(11, 16)
}

function buildSplitDiff(rows: ReadonlyArray<UnifiedDiffRow>): SplitDiffRow[] {
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
