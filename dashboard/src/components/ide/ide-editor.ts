import { html } from 'htm/preact'
import { useRef, useEffect, useMemo, useState } from 'preact/hooks'
import { useSignalValue, useStoreSubscription } from './use-signal-value'
import { EditorState } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import type { CodeDocumentStore } from './code-document-store'
import type { KeeperLineOwnershipStore } from './keeper-line-ownership-store'
import { ideEditorSelection } from './ide-editor-selection'
import type { UnifiedDiffRow } from '../../api/workspace'
import {
  readOnlyExt,
  themeExt,
  languageExt,
  lineNumberExt,
  blameExtensions,
  keeperLineSelectExt,
  keeperTraceLineGutterExt,
  keeperTraceLineChipExt,
  contextFocusLineExt,
  focusEditorContextLine,
  pushOwnership,
  pushKeeperTraceLines,
  keeperTraceLinesForFile,
  internalDocumentSync,
  syntaxHighlightExt,
  type EditorKeeperTraceLine,
} from './ide-editor-extensions'
import { lspDiagnosticSnapshot, lspExtension } from './ide-lsp-client'
import { SplitDiffView, UnifiedDiffView } from './ide-diff-view'
import { filterTraceEventsByReplay, keeperTraceState, type KeeperTraceEvent } from './keeper-trace-store'
import { globalPresenceSnapshot } from './keeper-presence-store'
import { ideContextFocus, type IdeContextFocus } from './ide-state'
import { ideConversationThreadSnapshot } from './ide-context-bridge'
import { ideReplayUntilMs } from './ide-replay-state'
import { IdeFindPanel } from './ide-editor-find'
import {
  BlameTimeline,
  LayerOverlaySummary,
  editorGridRows,
  activeLayersInDisplayOrder,
} from './ide-editor-blame'
import { buildCurrentFileSignals, EditorCurrentFileSignals, focusTraceLineContext } from './ide-editor-signals'
import { EditorContextRouteLink, EditorContextRouteCount } from './ide-editor-route-ui'

// ── Types ─────────────────────────────────────────────────────────

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
}

const EMPTY_ACTIVE_LAYERS: ReadonlySet<string> = new Set()
const EMPTY_TRACE_EVENTS: ReadonlyArray<KeeperTraceEvent> = []

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
}: IdeEditorProps) {
  useStoreSubscription(documentStore.subscribe)
  useStoreSubscription(ownershipStore.subscribe)
  useSignalValue(globalPresenceSnapshot)
  useSignalValue(ideContextFocus)
  useSignalValue(ideConversationThreadSnapshot)
  useSignalValue(lspDiagnosticSnapshot)
  useSignalValue(keeperTraceState)
  useSignalValue(ideReplayUntilMs)

  const document = documentStore.document()
  if (document.file_path === null) {
    return html`
      <div
        class="ide-editor-empty v2-ide-panel"
        role="region"
        aria-label="ide editor"
        data-testid="ide-editor-empty"
        style=${{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          height: '100%',
          color: 'var(--color-fg-disabled)',
          fontStyle: 'italic',
        }}
      >no active file</div>
    `
  }
  const documentFilePath: string = document.file_path
  const lines = documentStore.lines()
  const ownership = ownershipStore.ownership()
  const keepers = ownershipStore.knownKeepers()
  const contextFocus = ideContextFocus.value
  const currentFileFocus = contextFocus?.file_path === documentFilePath ? contextFocus : null
  const activeLayerKinds = activeLayersInDisplayOrder(activeLayers)
  const currentDiffRows = diffRows()
  const replayTraceEvents = filterTraceEventsByReplay(keeperTraceState.value.events, ideReplayUntilMs.value)
  const currentFileSignals = buildCurrentFileSignals({
    filePath: documentFilePath,
    diffRows: currentDiffRows,
    traceEvents: replayTraceEvents,
  })
  const gridTemplateRows = editorGridRows(activeLayerKinds.length > 0, findOpen)
  const observationSummary = `${ownership.size} owned · ${keepers.length} keepers`
  const observationTitle = `${ownership.size} owned line(s), ${keepers.length} keeper(s)`

  return html`
    <div
      class="ide-editor v2-ide-panel"
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
        class="ide-editor-header v2-ide-toolbar"
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
        <span
          style=${{ marginLeft: 'auto', flexShrink: 0, whiteSpace: 'nowrap' }}
          data-testid="ide-observation-summary"
          title=${observationTitle}
        >
          ${lines.length} lines · ${observationSummary} · ${activeLayerKinds.length} layers
        </span>
        <${EditorCurrentFileSignals} signals=${currentFileSignals} />
        ${currentFileFocus ? html`
          <div
            role="status"
            class="ide-editor-context-focus v2-ide-detail"
            data-testid="ide-context-focus-status"
            title=${currentFileFocus.file_path}
          >
            <span class="ide-editor-context-focus-label">
              Focused ${currentFileFocus.line !== undefined ? `L${currentFileFocus.line}` : currentFileFocus.surface}
              · ${currentFileFocus.label}
            </span>
            <span class="ide-editor-context-focus-meta" aria-label="Focused context metadata">
              ${contextFocusMetaParts(currentFileFocus).map(part => html`<span>${part}</span>`)}
            </span>
            ${currentFileFocus.route_links && currentFileFocus.route_links.length > 0 ? html`
              <span class="ide-editor-context-route-links" aria-label="Focused context operational links">
                <${EditorContextRouteCount} count=${currentFileFocus.route_links.length} label="focused context" />
                ${currentFileFocus.route_links.map(link => EditorContextRouteLink(link))}
              </span>
            ` : null}
          </div>
        ` : null}
        ${onFindOpen || onFindClose ? html`
          <button
            type="button"
            class="v2-ide-action"
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
        ? LayerOverlaySummary(activeLayerKinds, ownership, keepers)
        : null}
      ${findOpen
        ? html`<${IdeFindPanel}
            lines=${lines}
            filePath=${document.file_path}
            onClose=${onFindClose}
          />`
        : null}
      ${activeView === 'split-diff'
        ? SplitDiffView(currentDiffRows, currentFileFocus)
        : activeView === 'unified'
          ? UnifiedDiffView(currentDiffRows, currentFileFocus)
          : html`<${CodeMirrorEditor}
              documentStore=${documentStore}
              ownershipStore=${ownershipStore}
              showBlame=${activeView === 'blame'}
              showOwnership=${ownership.size > 0}
              keepers=${keepers}
              onKeeperLineSelect=${onKeeperLineSelect}
              contextFocus=${currentFileFocus}
              traceActive=${activeLayers.has('keeper-trace')}
              traceEvents=${replayTraceEvents}
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
  showOwnership,
  keepers,
  onKeeperLineSelect,
  contextFocus,
  traceActive = false,
  traceEvents = EMPTY_TRACE_EVENTS,
}: {
  readonly documentStore: CodeDocumentStore
  readonly ownershipStore: KeeperLineOwnershipStore
  readonly showBlame: boolean
  readonly showOwnership: boolean
  readonly keepers: ReadonlyArray<string>
  readonly onKeeperLineSelect?: (keeperId: string, line: number) => void
  readonly contextFocus?: IdeContextFocus | null
  readonly traceActive?: boolean
  readonly traceEvents?: ReadonlyArray<KeeperTraceEvent>
}) {
  const containerRef = useRef<HTMLElement>(null)
  const editorRef = useRef<EditorView | null>(null)
  const [ready, setReady] = useState(false)

  const document = documentStore.document()
  const documentFilePath = document.file_path
  const ownership = ownershipStore.ownership()
  const traceLines = useMemo(
    () => traceActive && documentFilePath !== null
      ? keeperTraceLinesForFile(documentFilePath, traceEvents)
      : [],
    [documentFilePath, traceActive, traceEvents],
  )
  const traceLinesRef = useRef<ReadonlyArray<EditorKeeperTraceLine>>(traceLines)

  useEffect(() => {
    traceLinesRef.current = traceLines
  }, [traceLines])

  // Mount CM6 instance
  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    let destroyed = false

    async function mount() {
      const mountDocument = documentStore.document()
      const mountFilePath = mountDocument.file_path
      if (mountFilePath === null) return
      const lang = await languageExt(mountFilePath)
      if (destroyed) return

      const blameExts = showOwnership ? blameExtensions() : []
      const state = EditorState.create({
        doc: documentStore.document().content,
        extensions: [
          readOnlyExt(),
          themeExt(),
          lineNumberExt(),
          syntaxHighlightExt(),
          lang,
          lspExtension({ filePath: mountFilePath }),
          contextFocusLineExt(),
          EditorView.updateListener.of((update) => {
            // Publish the human selection as 1-based line numbers for the
            // surfaces that talk about "these lines" (interject).
            if (update.selectionSet || update.docChanged) {
              const main = update.state.selection.main
              ideEditorSelection.value = {
                filePath: mountFilePath,
                lineStart: update.state.doc.lineAt(main.from).number,
                lineEnd: update.state.doc.lineAt(main.to).number,
              }
            }
          }),
          ...(onKeeperLineSelect
            ? [keeperLineSelectExt(() => ownershipStore.ownership(), onKeeperLineSelect)]
            : []),
          ...(traceActive
            ? [
                keeperTraceLineGutterExt({
                  getTraceLines: () => traceLinesRef.current,
                  onTraceLineSelect: (event, line) => {
                    const current = documentStore.document().file_path
                    if (current === null) return
                    focusTraceLineContext(current, event, line)
                  },
                }),
                keeperTraceLineChipExt(),
              ]
            : []),
          ...blameExts,
        ],
      })

      const view = new EditorView({
        state,
        parent: container!,
      })

      editorRef.current = view
      if (showOwnership && ownership.size > 0) {
        pushOwnership(view, ownership)
      }
      if (traceActive && traceLines.length > 0) {
        pushKeeperTraceLines(view, traceLines)
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
  }, [document.file_path, documentStore, ownershipStore, onKeeperLineSelect, showOwnership, traceActive])

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
    if (!view || !ready || !showOwnership) return
    pushOwnership(view, ownership)
  }, [ownership, ready, showOwnership])

  useEffect(() => {
    const view = editorRef.current
    if (!view || !ready || !traceActive) return
    pushKeeperTraceLines(view, traceLines)
  }, [ready, traceActive, traceLines])

  useEffect(() => {
    const view = editorRef.current
    if (!view || !ready) return
    if (!contextFocus || contextFocus.file_path !== documentStore.document().file_path) {
      focusEditorContextLine(view, undefined)
      return
    }
    focusEditorContextLine(view, contextFocus.line === undefined ? undefined : {
      line: contextFocus.line,
      surface: contextFocus.surface,
      label: contextFocus.label,
      keeperId: contextFocus.keeper_id,
      linkCount: contextFocus.route_links?.length,
    })
  }, [
    contextFocus?.activated_at_ms,
    contextFocus?.file_path,
    contextFocus?.line,
    contextFocus?.surface,
    contextFocus?.label,
    contextFocus?.keeper_id,
    contextFocus?.route_links,
    document.file_path,
    documentStore,
    ready,
  ])

  useStoreSubscription(documentStore.subscribe)
  useStoreSubscription(ownershipStore.subscribe)
  useSignalValue(keeperTraceState)

  return html`
    <div
      class="ide-codemirror-shell v2-ide-panel"
      data-view=${showBlame ? 'blame' : showOwnership ? 'source-ownership' : 'source'}
    >
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

function contextFocusMetaParts(focus: IdeContextFocus): ReadonlyArray<string> {
  const routeCount = focus.route_links?.length ?? 0
  return [
    focus.surface,
    focus.keeper_id ? `keeper ${focus.keeper_id}` : null,
    `source ${focus.source_id}`,
    routeCount > 0 ? `${routeCount} links` : null,
  ].filter((part): part is string => part !== null)
}

// Re-exports for backward compatibility
export { currentFileFindMatches } from './ide-editor-find'
