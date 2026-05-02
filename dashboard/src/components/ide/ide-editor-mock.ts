import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useMemo } from 'preact/hooks'
import {
  createCodeDocumentStore,
  type CodeDocumentLine,
} from './code-document-store'
import { CodeLineText, useHighlightedCodeLines } from './ide-code-renderer'
import {
  createKeeperLineOwnershipStore,
  type KeeperEdit,
  type LineOwnership,
} from './keeper-line-ownership-store'

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

const EDITOR_FILE = 'runtime/cascade/router.ts'
const EMPTY_ACTIVE_LAYERS: ReadonlySet<string> = new Set()
const LAYER_ORDER = ['time', 'parallel', 'tools', 'approve', 'notes', 'explode'] as const

const VIEW_LABEL: Record<IdeEditorView, string> = {
  source: 'SOURCE',
  'split-diff': 'SPLIT DIFF',
  unified: 'UNIFIED',
  blame: 'BLAME',
}

const LAYER_LABEL: Record<(typeof LAYER_ORDER)[number], string> = {
  time: 'Time',
  parallel: 'Parallel',
  tools: 'Tools',
  approve: 'Approve',
  notes: 'Notes',
  explode: 'EXPLODE',
}

const MOCK_SOURCE = [
  "import { Provider, ProviderKind } from './provider'",
  "import { Turn, TurnId } from './turn'",
  "import { FsmEvent } from '../fsm/state'",
  "import { log } from '../log'",
  "import type { ToolSpec } from './tools'",
  "import { TokenRegistry } from '../tokens/registry'",
  '',
  'export type CascadeReq = {',
  '  model: string',
  '  messages: Array<{ role: string; content: string }>',
  '  tools?: ToolSpec[]',
  "  tool_choice?: 'auto' | 'none'",
  '  max_tokens?: number',
  '}',
  '',
  'export function normalizeTools(req: CascadeReq): CascadeReq {',
  '  // strip empty tools array',
  '  if (req.tools && req.tools.length === 0) {',
  '    const { tools, tool_choice, ...rest } = req',
  '    return rest as CascadeReq',
  '  }',
  '  return req',
  '}',
].join('\n')

const MOCK_OWNERSHIP_EVENTS: ReadonlyArray<KeeperEdit> = [
  {
    file_path: EDITOR_FILE,
    line_start: 1,
    line_end: 6,
    keeper_id: 'nick0cave',
    timestamp_ms: 1_774_960_000_000,
    kind: 'create',
  },
  {
    file_path: EDITOR_FILE,
    line_start: 8,
    line_end: 14,
    keeper_id: 'sangsu',
    timestamp_ms: 1_774_960_180_000,
    kind: 'edit',
  },
  {
    file_path: EDITOR_FILE,
    line_start: 16,
    line_end: 23,
    keeper_id: 'masc-improver',
    timestamp_ms: 1_774_960_420_000,
    kind: 'refactor',
  },
]

export function IdeEditorMock({
  activeView = 'source',
  activeLayers = EMPTY_ACTIVE_LAYERS,
}: IdeEditorMockProps) {
  const documentStore = useMemo(() =>
    createCodeDocumentStore({
      file_path: EDITOR_FILE,
      language: 'typescript',
      content: MOCK_SOURCE,
    }), [])
  const ownershipStore = useMemo(() => {
    const store = createKeeperLineOwnershipStore(EDITOR_FILE)
    for (const event of MOCK_OWNERSHIP_EVENTS) store.ingest(event)
    return store
  }, [])
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
      <ol
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
  activeLayerKinds: ReadonlyArray<string>,
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

function activeLayersInDisplayOrder(activeLayers: ReadonlySet<string>): ReadonlyArray<string> {
  return LAYER_ORDER.filter(kind => activeLayers.has(kind))
}

function LayerOverlaySummary(
  activeLayerKinds: ReadonlyArray<string>,
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
  line: CodeDocumentLine,
  owner: LineOwnership | undefined,
  activeLayerKinds: ReadonlyArray<string>,
): ReadonlyArray<string> {
  const chips: string[] = []
  for (const kind of activeLayerKinds) {
    if (kind === 'time' && owner) chips.push(formatTime(owner.last_edit_ms))
    if (kind === 'parallel' && owner) chips.push(owner.last_edit_kind)
    if (kind === 'tools' && /\btools?\b|tool_choice/.test(line.text)) chips.push('tool')
    if (kind === 'approve' && owner?.last_edit_kind === 'refactor') chips.push('approve')
    if (kind === 'notes' && line.text.trim().startsWith('//')) chips.push('note')
    if (kind === 'explode' && owner) chips.push('ghost')
  }
  return chips
}

function latestEditMs(ownership: ReadonlyMap<number, LineOwnership>): number | null {
  let latest: number | null = null
  for (const owner of ownership.values()) {
    if (latest === null || owner.last_edit_ms > latest) latest = owner.last_edit_ms
  }
  return latest
}

function layerLabel(kind: string): string {
  return kind in LAYER_LABEL
    ? LAYER_LABEL[kind as keyof typeof LAYER_LABEL]
    : kind
}

function layerSummary(kind: string, latestEdit: number | null, keepers: ReadonlyArray<string>): string {
  if (kind === 'time') return latestEdit === null ? 'no edits' : `latest ${formatTime(latestEdit)}`
  if (kind === 'parallel') return `${keepers.length} keepers`
  if (kind === 'tools') return 'tool-call lines'
  if (kind === 'approve') return 'refactor approvals'
  if (kind === 'notes') return 'comment notes'
  if (kind === 'explode') return 'exclusive ghost view'
  return ''
}

function formatTime(ms: number): string {
  return new Date(ms).toISOString().slice(11, 16)
}
