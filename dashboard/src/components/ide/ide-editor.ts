import { html } from 'htm/preact'
import { useRef, useEffect, useMemo, useState } from 'preact/hooks'
import { EditorState } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import type {
  CodeDocumentStore,
  CodeDocumentLine,
} from './code-document-store'
import {
  type KeeperLineOwnershipStore,
  type LineOwnership,
} from './keeper-line-ownership-store'
import type { UnifiedDiffRow } from '../../api/workspace'
import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import {
  readOnlyExt,
  themeExt,
  languageExt,
  lineNumberExt,
  blameExtensions,
  keeperLineSelectExt,
  contextFocusLineExt,
  focusEditorContextLine,
  pushOwnership,
  internalDocumentSync,
  syntaxHighlightExt,
} from './ide-editor-extensions'
import { lspExtension, getSelectedAnnotation, clearSelectedAnnotation, type SelectedAnnotation } from './ide-lsp-client'
import { SplitDiffView, UnifiedDiffView } from './ide-diff-view'
import { KeeperBadge } from '../keeper-badge'
import { keeperCursorExtension } from './keeper-cursor-cm-extension'
import { cursorOverlaySignal, getKeeperColor } from './keeper-cursor-overlay'
import {
  globalPresenceSnapshot,
  type KeeperPresenceSnapshot,
  type KeeperPresenceStatus,
} from './keeper-presence-store'
import { ideContextFocus, type IdeContextFocus } from './ide-state'

// ── Types ─────────────────────────────────────────────────────────

const IDE_LAYER_ORDER = ['time', 'parallel', 'tools', 'approve', 'notes', 'cascade', 'keeper-trace', 'explode'] as const
type IdeLayerKind = (typeof IDE_LAYER_ORDER)[number]

export type IdeEditorView = 'source' | 'split-diff' | 'unified' | 'blame'

interface IdeEditorProps {
  readonly activeView?: IdeEditorView
  readonly activeLayers?: ReadonlySet<string>
  readonly documentStore: CodeDocumentStore
  readonly ownershipStore: KeeperLineOwnershipStore
  readonly diffRows: () => ReadonlyArray<UnifiedDiffRow>
  readonly findOpen?: boolean
  readonly onFindOpen?: () => void
  readonly onFindClose?: () => void
  readonly onKeeperLineSelect?: (keeperId: string, line: number) => void
  readonly annotations?: ReadonlyArray<IdeAnnotation>
}

export interface FindOptions {
  readonly caseSensitive: boolean
  readonly wholeWord: boolean
}

export interface FindMatch {
  readonly line: number
  readonly text: string
  readonly before: string
  readonly match: string
  readonly after: string
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
  findOpen = false,
  onFindOpen,
  onFindClose,
  onKeeperLineSelect,
  annotations = [],
}: IdeEditorProps) {
  const [, forceRender] = useState(0)

  useEffect(() => documentStore.subscribe(() => forceRender(tick => tick + 1)), [documentStore])
  useEffect(() => ownershipStore.subscribe(() => forceRender(tick => tick + 1)), [ownershipStore])
  useEffect(() => cursorOverlaySignal.subscribe(() => forceRender(tick => tick + 1)), [])
  useEffect(() => globalPresenceSnapshot.subscribe(() => forceRender(tick => tick + 1)), [])
  useEffect(() => ideContextFocus.subscribe(() => forceRender(tick => tick + 1)), [])

  const document = documentStore.document()
  const lines = documentStore.lines()
  const ownership = ownershipStore.ownership()
  const keepers = ownershipStore.knownKeepers()
  const overlay = cursorOverlaySignal.value
  const presence = globalPresenceSnapshot.value
  const contextFocus = ideContextFocus.value
  const currentFileFocus = contextFocus?.file_path === document.file_path ? contextFocus : null
  const activeCursors = keepersWithCursorInFile(overlay.cursors, document.file_path)
  const activeLayerKinds = activeLayersInDisplayOrder(activeLayers)
  const currentDiffRows = diffRows()
  const gridTemplateRows = editorGridRows(activeLayerKinds.length > 0, findOpen)

  return html`
    <div
      role="region"
      aria-label="에디터 (code document store + RFC 0019 ownership)"
      style=${{
        display: 'grid',
        gridTemplateRows,
        background: 'var(--color-bg-page)',
        minHeight: 0,
      }}
    >
      <div
        style=${{
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--sp-3)',
          flexWrap: 'wrap',
          minWidth: 0,
          padding: 'var(--sp-2) var(--sp-3)',
          borderBottom: '1px solid var(--color-border-divider)',
          color: 'var(--color-fg-muted)',
          font: 'var(--type-eyebrow)',
        }}
      >
        <span style=${{
          minWidth: 0,
          flex: '1 1 12rem',
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          whiteSpace: 'nowrap',
        }}>${document.file_path}</span>
        <span style=${{ color: 'var(--color-fg-disabled)', flexShrink: 0 }}>${document.language}</span>
        <span style=${{ color: 'var(--color-accent-fg)', flexShrink: 0 }}>${VIEW_LABEL[activeView]}</span>
        <span style=${{ marginLeft: 'auto', flexShrink: 0, whiteSpace: 'nowrap' }}>
          ${lines.length} lines · ownership · ${keepers.length} keepers · ${activeLayerKinds.length} layers
        </span>
        ${currentFileFocus ? html`
          <span
            role="status"
            data-testid="ide-context-focus-status"
            title=${currentFileFocus.file_path}
            style=${{
              minWidth: 0,
              maxWidth: '220px',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              whiteSpace: 'nowrap',
              color: 'var(--color-accent-fg)',
              flexShrink: 1,
            }}
          >
            Focused ${currentFileFocus.line !== undefined ? `L${currentFileFocus.line}` : currentFileFocus.surface}
            · ${currentFileFocus.label}
          </span>
        ` : null}
        ${activeCursors.length > 0 ? html`
          <ul
            role="status"
            aria-label="Keepers active in this file"
            style=${{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 'var(--sp-1)',
              listStyle: 'none',
              margin: 0,
              padding: 0,
              flexShrink: 0,
            }}
          >
            ${activeCursors.map(ac => EditorKeeperCursorChip(ac, presence, ac.keeper_id))}
          </ul>
        ` : null}
        ${onFindOpen || onFindClose ? html`
          <button
            type="button"
            aria-label=${findOpen ? 'Close find panel' : 'Open find panel'}
            aria-pressed=${findOpen ? 'true' : 'false'}
            onClick=${() => findOpen ? onFindClose?.() : onFindOpen?.()}
            style=${{
              height: '24px',
              padding: '0 var(--sp-2)',
              color: findOpen ? 'var(--color-accent-fg)' : 'var(--color-fg-muted)',
              background: findOpen ? 'var(--color-bg-elevated)' : 'transparent',
              border: '1px solid var(--color-border-default)',
              borderRadius: 'var(--r-1)',
              font: 'var(--type-eyebrow)',
              cursor: 'pointer',
            }}
          >Find</button>
        ` : null}
      </div>
      ${activeLayerKinds.length > 0
        ? LayerOverlaySummary(activeLayerKinds, ownership, keepers, annotations)
        : null}
      ${findOpen
        ? html`<${IdeFindPanel}
            lines=${lines}
            filePath=${document.file_path}
            onClose=${onFindClose}
          />`
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
              contextFocus=${currentFileFocus}
            />`
      }
    </div>
  `
}

// ── Find overlay ─────────────────────────────────────────────────

function IdeFindPanel({
  lines,
  filePath,
  onClose,
}: {
  readonly lines: ReadonlyArray<CodeDocumentLine>
  readonly filePath: string
  readonly onClose?: () => void
}) {
  const [query, setQuery] = useState('')
  const [caseSensitive, setCaseSensitive] = useState(false)
  const [wholeWord, setWholeWord] = useState(false)
  const [activeIndex, setActiveIndex] = useState(0)

  const matches = useMemo(
    () => currentFileFindMatches(lines, query, { caseSensitive, wholeWord }),
    [caseSensitive, lines, query, wholeWord],
  )

  useEffect(() => {
    setActiveIndex(0)
  }, [caseSensitive, filePath, query, wholeWord])

  useEffect(() => {
    if (activeIndex < matches.length || matches.length === 0) return
    setActiveIndex(matches.length - 1)
  }, [activeIndex, matches.length])

  const activeOrdinal = matches.length > 0 ? activeIndex + 1 : 0
  const canMove = matches.length > 1
  const move = (delta: number): void => {
    if (matches.length === 0) return
    setActiveIndex(index => (index + delta + matches.length) % matches.length)
  }

  return html`
    <div
      role="search"
      aria-label="Find in current file"
      data-testid="ide-find-panel"
      style=${{
        display: 'grid',
        gridTemplateColumns: 'minmax(0, 1fr)',
        alignItems: 'center',
        gap: 'var(--sp-2)',
        boxSizing: 'border-box',
        width: '100%',
        maxWidth: 'calc(100vw - 20px)',
        padding: 'var(--sp-2) var(--sp-3)',
        borderBottom: '1px solid var(--color-border-divider)',
        background: 'var(--color-bg-surface)',
        color: 'var(--color-fg-muted)',
        font: 'var(--type-body)',
        fontSize: 'var(--fs-11)',
      }}
    >
      <div
        style=${{
          gridColumn: '1 / -1',
          display: 'flex',
          alignItems: 'center',
          flexWrap: 'wrap',
          gap: 'var(--sp-1)',
          minWidth: 0,
        }}
      >
        <input
          type="search"
          aria-label="Find query"
          placeholder="Find in current file"
          value=${query}
          onInput=${(event: Event) => setQuery((event.target as HTMLInputElement).value)}
          style=${{
            flex: '1 1 100px',
            minWidth: 0,
            maxWidth: '280px',
            height: '28px',
            font: 'var(--type-body)',
            fontSize: 'var(--fs-11)',
            color: 'var(--color-fg-primary)',
            background: 'var(--color-bg-elevated)',
            border: '1px solid var(--color-border-default)',
            borderRadius: 'var(--r-1)',
            padding: '0 var(--sp-2)',
            outline: 'none',
          }}
        />
        <${ToggleButton}
          label="Aa"
          pressed=${caseSensitive}
          onClick=${() => setCaseSensitive(value => !value)}
        />
        <${ToggleButton}
          label="Word"
          pressed=${wholeWord}
          onClick=${() => setWholeWord(value => !value)}
        />
        <button
          type="button"
          aria-label="Previous match"
          disabled=${!canMove}
          onClick=${() => move(-1)}
          style=${findButtonStyle(!canMove)}
        >Prev</button>
        <button
          type="button"
          aria-label="Next match"
          disabled=${!canMove}
          onClick=${() => move(1)}
          style=${findButtonStyle(!canMove)}
        >Next</button>
        ${onClose ? html`
          <button
            type="button"
            aria-label="Close find panel"
            onClick=${onClose}
            style=${findButtonStyle(false)}
          >Close</button>
        ` : null}
      </div>
      <div
        role="status"
        data-testid="ide-find-status"
        style=${{
          gridColumn: '1 / -1',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          flexWrap: 'wrap',
          gap: 'var(--sp-2)',
          color: 'var(--color-fg-muted)',
          minWidth: 0,
        }}
      >
        <span>${activeOrdinal} of ${matches.length} matches</span>
        <span
          style=${{
            minWidth: 0,
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}
        >${filePath}</span>
      </div>
      ${query.trim() !== '' && matches.length > 0
        ? html`
            <ol
              role="list"
              aria-label="Find matches"
              data-testid="ide-find-results"
              style=${{
                gridColumn: '1 / -1',
                display: 'grid',
                gap: '2px',
                maxHeight: '112px',
                overflow: 'auto',
                margin: 0,
                padding: 0,
                listStyle: 'none',
              }}
            >
              ${matches.map((item, index) => html`
                <li
                  role="listitem"
                  aria-current=${index === activeIndex ? 'true' : undefined}
                  style=${{
                    display: 'grid',
                    gridTemplateColumns: '48px minmax(0, 1fr)',
                    gap: 'var(--sp-2)',
                    alignItems: 'baseline',
                    padding: '2px var(--sp-2)',
                    color: index === activeIndex ? 'var(--color-fg-primary)' : 'var(--color-fg-secondary)',
                    background: index === activeIndex ? 'var(--color-bg-elevated)' : 'transparent',
                    borderRadius: 'var(--r-1)',
                    fontFamily: 'var(--font-mono)',
                  }}
                >
                  <span style=${{ color: 'var(--color-fg-muted)' }}>${item.line}</span>
                  <code style=${{ minWidth: 0, overflowWrap: 'anywhere', whiteSpace: 'pre-wrap' }}>
                    ${item.before}<mark>${item.match}</mark>${item.after}
                  </code>
                </li>
              `)}
            </ol>
          `
        : null}
    </div>
  `
}

function ToggleButton({
  label,
  pressed,
  onClick,
}: {
  readonly label: string
  readonly pressed: boolean
  readonly onClick: () => void
}) {
  return html`
    <button
      type="button"
      aria-pressed=${pressed ? 'true' : 'false'}
      onClick=${onClick}
      style=${{
        height: '28px',
        padding: '0 var(--sp-2)',
        color: pressed ? 'var(--color-accent-fg)' : 'var(--color-fg-muted)',
        background: pressed ? 'var(--color-bg-elevated)' : 'transparent',
        border: '1px solid var(--color-border-default)',
        borderRadius: 'var(--r-1)',
        font: 'var(--type-eyebrow)',
        cursor: 'pointer',
      }}
    >${label}</button>
  `
}

function findButtonStyle(disabled: boolean): Record<string, string | number> {
  return {
    height: '28px',
    padding: '0 var(--sp-2)',
    color: disabled ? 'var(--color-fg-disabled)' : 'var(--color-fg-muted)',
    background: 'transparent',
    border: '1px solid var(--color-border-default)',
    borderRadius: 'var(--r-1)',
    font: 'var(--type-eyebrow)',
    cursor: disabled ? 'not-allowed' : 'pointer',
  }
}

export function currentFileFindMatches(
  lines: ReadonlyArray<CodeDocumentLine>,
  query: string,
  options: FindOptions,
): ReadonlyArray<FindMatch> {
  const needle = query.trim()
  if (needle === '') return []

  const flags = options.caseSensitive ? '' : 'i'
  const pattern = options.wholeWord
    ? `\\b${escapeRegExp(needle)}\\b`
    : escapeRegExp(needle)
  const regex = new RegExp(pattern, flags)
  const matches: FindMatch[] = []

  for (const line of lines) {
    const match = regex.exec(line.text)
    if (!match) continue
    matches.push({
      line: line.num,
      text: line.text,
      before: line.text.slice(0, match.index),
      match: match[0],
      after: line.text.slice(match.index + match[0].length),
    })
    if (matches.length >= 50) break
  }

  return matches
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

// ── CM6 read-only editor ──────────────────────────────────────────
// Preact ref-based mount — no vDOM conflict with CM6's DOM management.

function CodeMirrorEditor({
  documentStore,
  ownershipStore,
  showBlame,
  keepers,
  onKeeperLineSelect,
  contextFocus,
}: {
  readonly documentStore: CodeDocumentStore
  readonly ownershipStore: KeeperLineOwnershipStore
  readonly showBlame: boolean
  readonly keepers: ReadonlyArray<string>
  readonly onKeeperLineSelect?: (keeperId: string, line: number) => void
  readonly annotations?: ReadonlyArray<IdeAnnotation>
  readonly contextFocus?: IdeContextFocus | null
}) {
  const containerRef = useRef<HTMLElement>(null)
  const editorRef = useRef<EditorView | null>(null)
  const [ready, setReady] = useState(false)
  const [selectedAnn, setSelectedAnn] = useState<SelectedAnnotation | null>(null)
  const prevAnnRef = useRef<SelectedAnnotation | null>(null)

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
          lspExtension({ filePath: mountDocument.file_path }),
          keeperCursorExtension(),
          contextFocusLineExt(),
          EditorView.updateListener.of((update) => {
            const sel = getSelectedAnnotation(update.view)
            if (sel !== prevAnnRef.current) {
              prevAnnRef.current = sel
              setSelectedAnn(sel)
            }
          }),
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

  useEffect(() => {
    const view = editorRef.current
    if (!view || !ready) return
    if (!contextFocus || contextFocus.file_path !== documentStore.document().file_path) {
      focusEditorContextLine(view, undefined)
      return
    }
    focusEditorContextLine(view, contextFocus.line)
  }, [
    contextFocus?.activated_at_ms,
    contextFocus?.file_path,
    contextFocus?.line,
    document.file_path,
    documentStore,
    ready,
  ])

  // Subscribe to store changes for re-render
  const [, forceRender] = useState(0)
  useEffect(() => documentStore.subscribe(() => forceRender(n => n + 1)), [documentStore])
  useEffect(() => ownershipStore.subscribe(() => forceRender(n => n + 1)), [ownershipStore])

  return html`
    <div class="ide-codemirror-shell" data-view=${showBlame ? 'blame' : 'source'}>
      ${showBlame ? BlameTimeline(ownership, keepers) : null}
      <div ref=${containerRef} class="ide-codemirror-host" />
      ${selectedAnn && editorRef.current ? AnnotationPopover({
        annotation: selectedAnn,
        view: editorRef.current,
        onClose: () => {
          if (editorRef.current) {
            clearSelectedAnnotation(editorRef.current)
            prevAnnRef.current = null
            setSelectedAnn(null)
          }
        },
      }) : null}
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

// ── Helpers ───────────────────────────────────────────────────────

function editorGridRows(hasLayerSummary: boolean, findOpen: boolean): string {
  const rows = ['auto']
  if (hasLayerSummary) rows.push('auto')
  if (findOpen) rows.push('auto')
  rows.push('1fr')
  return rows.join(' ')
}

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
  'keeper-trace': 'Trace',
  explode: 'EXPLODE',
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
  if (kind === 'cascade') return '0 hits'
  if (kind === 'keeper-trace') return 'stitched trace'
  if (kind === 'explode') return 'exclusive ghost view'
  return ''
}

// ── Active file cursor helpers ────────────────────────────────────

interface ActiveCursorInfo {
  keeper_id: string
  line: number
  tool_name?: string
  focus_mode: string
}

function keepersWithCursorInFile(
  cursors: ReadonlyMap<
    string,
    { keeper_id: string; file_path: string; line: number; focus_mode: string; tool_name?: string }
  >,
  filePath: string,
): ReadonlyArray<ActiveCursorInfo> {
  const matches: ActiveCursorInfo[] = []
  for (const cursor of cursors.values()) {
    // Cursor stream defaults missing line numbers to 0; filter them so
    // the header chip never renders 'file:0' (BDI inspector applies the
    // same 1-based guard).
    if (cursor.file_path === filePath && cursor.line >= 1) {
      matches.push({
        keeper_id: cursor.keeper_id,
        line: cursor.line,
        tool_name: cursor.tool_name,
        focus_mode: cursor.focus_mode,
      })
    }
  }
  return matches.sort((a, b) => a.keeper_id.localeCompare(b.keeper_id))
}

function EditorKeeperCursorChip(
  ac: ActiveCursorInfo,
  presence: KeeperPresenceSnapshot | null,
  key: string,
) {
  const color = getKeeperColor(ac.keeper_id)
  const status: KeeperPresenceStatus | undefined = presence?.entries.find(
    e => e.keeper_id === ac.keeper_id,
  )?.status
  const isActive = status === 'active'
  return html`
    <li
      key=${key}
      title=${`${ac.keeper_id} L${ac.line}${ac.tool_name ? ` · ${ac.tool_name}` : ''} · ${ac.focus_mode}`}
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: '2px',
        fontSize: 'var(--fs-10)',
        fontFamily: 'var(--font-mono)',
        color: 'var(--color-fg-secondary)',
        padding: '0 4px',
        borderRadius: 'var(--r-1)',
        background: `${color.cursor}18`,
        whiteSpace: 'nowrap',
      }}
    >
      <span
        aria-hidden="true"
        style=${{
          width: '5px',
          height: '5px',
          borderRadius: '50%',
          background: color.cursor,
          display: 'inline-block',
          boxShadow: isActive ? `0 0 4px ${color.cursor}` : 'none',
        }}
      />
      <span>${ac.keeper_id}</span>
      <span style=${{ color: 'var(--color-fg-disabled)' }}>L${ac.line}</span>
    </li>
  `
}

// ── Annotation Popover ────────────────────────────────────────────

const KIND_LABEL: Record<string, string> = {
  Comment: 'comment',
  Decision: 'decision',
  Question: 'question',
  Bookmark: 'bookmark',
}

const KIND_COLOR: Record<string, string> = {
  Comment: 'var(--color-accent-fg)',
  Decision: 'var(--color-success-fg)',
  Question: 'var(--color-fg-warning)',
  Bookmark: 'var(--color-fg-muted)',
}

function AnnotationPopover({
  annotation,
  view,
  onClose,
}: {
  readonly annotation: SelectedAnnotation
  readonly view: EditorView
  readonly onClose: () => void
}) {
  const line = annotation.line_start
  const lineInfo = line >= 1 && line <= view.state.doc.lines
    ? view.state.doc.line(line)
    : null
  const coords = lineInfo
    ? view.coordsAtPos(lineInfo.from)
    : null

  if (!coords) return null

  const shellRect = view.dom.closest('.ide-codemirror-shell')?.getBoundingClientRect()
  if (!shellRect) return null

  const top = coords.bottom - shellRect.top + 4
  const left = Math.max(8, coords.left - shellRect.left)

  return html`
    <div
      class="ide-annotation-popover"
      role="dialog"
      aria-label="Annotation detail"
      style=${{
        position: 'absolute',
        top: top + 'px',
        left: left + 'px',
        zIndex: 40,
        minWidth: '240px',
        maxWidth: '380px',
        background: 'var(--color-bg-elevated)',
        border: '1px solid var(--color-border-default)',
        borderRadius: 'var(--r-2)',
        boxShadow: '0 4px 16px rgba(0,0,0,0.12)',
        padding: 'var(--sp-3)',
        fontFamily: 'var(--font-sans)',
        fontSize: '13px',
        lineHeight: 1.5,
      }}
    >
      <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', marginBottom: 'var(--sp-2)' }}>
        <span style=${{
          padding: '1px 6px',
          borderRadius: 'var(--r-1)',
          fontSize: '11px',
          fontWeight: 600,
          textTransform: 'uppercase',
          color: KIND_COLOR[annotation.kind] ?? 'var(--color-fg-muted)',
          background: 'var(--color-bg-muted)',
        }}>${KIND_LABEL[annotation.kind] ?? annotation.kind}</span>
        <span style=${{ color: 'var(--color-fg-muted)', fontSize: '11px', flex: 1 }}>
          L${annotation.line_start}${annotation.line_start !== annotation.line_end ? `-${annotation.line_end}` : ''}
        </span>
        <button
          type="button"
          aria-label="Close annotation"
          onClick=${onClose}
          style=${{
            background: 'none',
            border: 'none',
            color: 'var(--color-fg-muted)',
            cursor: 'pointer',
            fontSize: '14px',
            lineHeight: 1,
            padding: '2px 4px',
          }}
        >&times;</button>
      </div>
      <div style=${{ color: 'var(--color-fg-primary)', whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
        ${annotation.content}
      </div>
      <div style=${{ display: 'flex', gap: 'var(--sp-2)', marginTop: 'var(--sp-2)', flexWrap: 'wrap' }}>
        ${annotation.keeper_id ? html`
          <span style=${{ color: 'var(--color-fg-muted)', fontSize: '11px' }}>
            keeper: <strong>${annotation.keeper_id}</strong>
          </span>
        ` : null}
        ${annotation.goal_id ? html`
          <span style=${{ color: 'var(--color-fg-muted)', fontSize: '11px' }}>
            goal: ${annotation.goal_id}
          </span>
        ` : null}
        ${annotation.task_id ? html`
          <span style=${{ color: 'var(--color-fg-muted)', fontSize: '11px' }}>
            task: ${annotation.task_id}
          </span>
        ` : null}
      </div>
    </div>
  `
}
