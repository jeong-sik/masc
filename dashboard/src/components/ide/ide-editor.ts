import { html } from 'htm/preact'
import { useRef, useEffect, useState } from 'preact/hooks'
import { EditorState } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import type {
  CodeDocumentStore,
} from './code-document-store'
import {
  type KeeperLineOwnershipStore,
  type LineOwnership,
} from './keeper-line-ownership-store'
import type { UnifiedDiffRow } from '../../api/workspace'
import {
  readOnlyExt,
  themeExt,
  languageExt,
  lineNumberExt,
  blameExtensions,
  keeperLineSelectExt,
  pushOwnership,
  internalDocumentSync,
  syntaxHighlightExt,
} from './ide-editor-extensions'
import { SplitDiffView, UnifiedDiffView } from './ide-diff-view'
import { KeeperBadge } from '../keeper-badge'

// ── Types ─────────────────────────────────────────────────────────

const IDE_LAYER_ORDER = ['time', 'parallel', 'tools', 'approve', 'notes', 'cascade', 'explode'] as const
type IdeLayerKind = (typeof IDE_LAYER_ORDER)[number]

export type IdeEditorView = 'source' | 'split-diff' | 'unified' | 'blame'

interface IdeEditorProps {
  readonly activeView?: IdeEditorView
  readonly activeLayers?: ReadonlySet<string>
  readonly documentStore: CodeDocumentStore
  readonly ownershipStore: KeeperLineOwnershipStore
  readonly diffRows: () => ReadonlyArray<UnifiedDiffRow>
  readonly onKeeperLineSelect?: (keeperId: string, line: number) => void
}

const EMPTY_ACTIVE_LAYERS: ReadonlySet<string> = new Set()

const VIEW_LABEL: Record<IdeEditorView, string> = {
  source: 'SOURCE',
  'split-diff': 'SPLIT DIFF',
  unified: 'UNIFIED',
  blame: 'BLAME',
}

// ── Component ─────────────────────────────────────────────────────

export function IdeEditor({
  activeView = 'source',
  activeLayers = EMPTY_ACTIVE_LAYERS,
  documentStore,
  ownershipStore,
  diffRows,
  onKeeperLineSelect,
}: IdeEditorProps) {
  const [, forceRender] = useState(0)

  useEffect(() => documentStore.subscribe(() => forceRender(tick => tick + 1)), [documentStore])
  useEffect(() => ownershipStore.subscribe(() => forceRender(tick => tick + 1)), [ownershipStore])

  const document = documentStore.document()
  const lines = documentStore.lines()
  const ownership = ownershipStore.ownership()
  const keepers = ownershipStore.knownKeepers()
  const activeLayerKinds = activeLayersInDisplayOrder(activeLayers)
  const currentDiffRows = diffRows()

  return html`
    <div
      role="region"
      aria-label="에디터 (code document store + RFC 0019 ownership)"
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
      ${activeView === 'split-diff'
        ? SplitDiffView(currentDiffRows)
        : activeView === 'unified'
          ? UnifiedDiffView(currentDiffRows)
          : html`<${CodeMirrorEditor}
              documentStore=${documentStore}
              ownershipStore=${ownershipStore}
              showBlame=${activeView === 'blame'}
              keepers=${keepers}
              onKeeperLineSelect=${onKeeperLineSelect}
            />`
      }
    </div>
  `
}

// ── CM6 read-only editor ──────────────────────────────────────────
// Preact ref-based mount — no vDOM conflict with CM6's DOM management.

function CodeMirrorEditor({
  documentStore,
  ownershipStore,
  showBlame,
  keepers,
  onKeeperLineSelect,
}: {
  readonly documentStore: CodeDocumentStore
  readonly ownershipStore: KeeperLineOwnershipStore
  readonly showBlame: boolean
  readonly keepers: ReadonlyArray<string>
  readonly onKeeperLineSelect?: (keeperId: string, line: number) => void
}) {
  const containerRef = useRef<HTMLElement>(null)
  const editorRef = useRef<EditorView | null>(null)
  const [ready, setReady] = useState(false)

  const document = documentStore.document()
  const ownership = ownershipStore.ownership()

  // Mount CM6 instance
  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    let destroyed = false

    async function mount() {
      const mountDocument = documentStore.document()
      const lang = await languageExt(mountDocument.file_path)
      if (destroyed) return

      const blameExts = showBlame ? blameExtensions() : []
      const state = EditorState.create({
        doc: documentStore.document().content,
        extensions: [
          readOnlyExt(),
          themeExt(),
          lineNumberExt(),
          syntaxHighlightExt(),
          lang,
          ...(onKeeperLineSelect
            ? [keeperLineSelectExt(() => ownershipStore.ownership(), onKeeperLineSelect)]
            : []),
          ...blameExts,
        ],
      })

      const view = new EditorView({
        state,
        parent: container!,
      })

      editorRef.current = view
      if (showBlame && ownership.size > 0) {
        pushOwnership(view, ownership)
      }
      setReady(true)
    }

    mount()

    return () => {
      destroyed = true
      editorRef.current?.destroy()
      editorRef.current = null
      setReady(false)
    }
  }, [document.file_path, documentStore, ownershipStore, onKeeperLineSelect, showBlame])

  // Push document updates. The first file response can arrive before
  // the CM6 instance is ready or before this component subscribes, so
  // always sync the current store snapshot when the effect starts.
  useEffect(() => {
    const sync = () => {
      const view = editorRef.current
      if (!view || !ready) return
      syncEditorDocument(view, documentStore.document().content)
    }

    sync()
    return documentStore.subscribe(sync)
  }, [documentStore, ready])

  // Push ownership updates
  useEffect(() => {
    const view = editorRef.current
    if (!view || !ready || !showBlame) return
    pushOwnership(view, ownership)
  }, [ownership, ready, showBlame])

  // Subscribe to store changes for re-render
  const [, forceRender] = useState(0)
  useEffect(() => documentStore.subscribe(() => forceRender(n => n + 1)), [documentStore])
  useEffect(() => ownershipStore.subscribe(() => forceRender(n => n + 1)), [ownershipStore])

  return html`
    <div class="ide-codemirror-shell" data-view=${showBlame ? 'blame' : 'source'}>
      ${showBlame ? BlameTimeline(ownership, keepers) : null}
      <div ref=${containerRef} class="ide-codemirror-host" />
    </div>
  `
}

function syncEditorDocument(view: EditorView, content: string): void {
  const currentDoc = view.state.doc.toString()
  if (currentDoc === content) return

  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: content },
    annotations: internalDocumentSync.of(true),
  })
}

// ── Blame timeline header ─────────────────────────────────────────

function BlameTimeline(
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

// ── Layer overlay summary ─────────────────────────────────────────

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

// ── Helpers ───────────────────────────────────────────────────────

function activeLayersInDisplayOrder(activeLayers: ReadonlySet<string>): ReadonlyArray<IdeLayerKind> {
  return IDE_LAYER_ORDER.filter(kind => activeLayers.has(kind))
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

const LAYER_LABEL: Record<IdeLayerKind, string> = {
  time: 'Time',
  parallel: 'Parallel',
  tools: 'Tools',
  approve: 'Approve',
  notes: 'Notes',
  cascade: 'Cascade',
  explode: 'EXPLODE',
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
  if (kind === 'cascade') return '0 hits'
  if (kind === 'explode') return 'exclusive ghost view'
  return ''
}
