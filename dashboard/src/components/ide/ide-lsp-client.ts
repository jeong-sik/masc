/**
 * IDE LSP Client — CodeMirror 6 extension for Language Server Protocol.
 *
 * Implements JSON-RPC 2.0 request-response over WebSocket.
 * The server (server_ide_lsp_proxy.ml) expects client-initiated requests
 * for codeLens, inlayHint, diagnostic, and hover — it does NOT push them.
 * Only `textDocument/publishDiagnostics` is a server-push notification.
 */

import {
  EditorView, ViewPlugin, GutterMarker, gutter,
  Decoration, type DecorationSet, WidgetType,
  type ViewUpdate,
} from '@codemirror/view'
import { StateField, StateEffect, RangeSetBuilder, type Extension } from '@codemirror/state'
import { signal } from '@preact/signals'
import { normalizeIdeContextFilePath } from './ide-state'
import {
  DEFAULT_MASC_ORIGIN,
  TRANSPORT_RETRY_BASE_MS,
  TRANSPORT_RETRY_JITTER_MS,
  TRANSPORT_RETRY_MAX_MS,
} from '../../config/constants'
import { DEFAULT_LANGUAGE_ID } from './ide-language'
import { ownLspDocument, ownsLspDocument, publishLspDocument, type LspDocumentConnection, type LspDocumentDiagnostics } from './ide-lsp-document-status'

// ── Types ─────────────────────────────────────────────────────────

/**
 * Which workspace this editor's LSP connection is looking at.
 *
 * `codebase` declares the IDE scope, which fixes the tree the connection's
 * document paths are relative to. `repoId`/`keeper` select that tree
 * independently. Without a codebase the server takes the tree from the
 * client's `rootUri` instead.
 */
export interface LspScope {
  readonly repoId: string | null
  readonly codebase: string | null
  readonly keeper: string | null
}

const EMPTY_LSP_SCOPE: LspScope = { repoId: null, codebase: null, keeper: null }

/**
 * Deliberately a plain cell, not a signal. The publisher writes it from
 * inside the workspace store's `effect`, and a signal write there forces an
 * intermediate flush that re-runs that effect — it re-fetched the active
 * file twice. Nothing needs to react to this value: the connection reads it
 * when it opens a socket and when it checks whether its socket went stale.
 */
let currentLspScope: LspScope = EMPTY_LSP_SCOPE
const scopeConnections = new Set<LspConnection>()

export function lspScopeKey(scope: LspScope): string {
  return JSON.stringify([scope.repoId, scope.codebase, scope.keeper])
}

export function publishLspScope(scope: LspScope): void {
  if (lspScopeKey(currentLspScope) === lspScopeKey(scope)) return
  currentLspScope = scope
  // The workspace publisher runs in a signal effect. Notify after its snapshot
  // commits, without reading LSP signals into that effect's dependency graph.
  queueMicrotask(() => {
    if (currentLspScope !== scope) return
    for (const connection of scopeConnections) connection.refreshScopeIfStale()
  })
}

export function lspScopeSnapshot(): LspScope {
  return currentLspScope
}

function lspScopeQuery(scope: LspScope): string {
  const params = new URLSearchParams()
  if (scope.repoId) {
    params.set('repo_id', scope.repoId)
  } else if (scope.keeper) {
    params.set('keeper', scope.keeper)
  }
  if (scope.codebase) params.set('codebase', scope.codebase)
  const query = params.toString()
  return query === '' ? '' : `?${query}`
}

export interface LspCodeLens {
  range: {
    start: { line: number; character: number }
    end: { line: number; character: number }
  }
  command?: {
    title: string
    command: string
    arguments?: unknown[]
  }
}

export interface LspInlayHint {
  position: { line: number; character: number }
  label: string | { value: string }
  kind?: number
  tooltip?: string
}

export interface LspDiagnostic {
  range: {
    start: { line: number; character: number }
    end: { line: number; character: number }
  }
  severity?: number
  code?: number | string
  source?: string
  message: string
}

export interface LspDiagnosticAnchor {
  readonly file_path: string
  readonly line: number
  readonly severity?: number
  readonly code?: number | string
  readonly source?: string
  readonly message: string
}

export const lspDiagnosticSnapshot = signal<ReadonlyMap<string, ReadonlyArray<LspDiagnosticAnchor>>>(new Map())

export interface LspLanguageStatus {
  readonly lang: string
  readonly connected: boolean
  readonly command: string | null
  /** Why the language has no server, when it is not connected. */
  readonly last_error: string | null
}

export interface LspStatusSnapshot {
  readonly langs: ReadonlyArray<LspLanguageStatus>
}

export const EMPTY_LSP_STATUS_SNAPSHOT: LspStatusSnapshot = { langs: [] }
export const lspStatusSnapshot = signal<LspStatusSnapshot>(EMPTY_LSP_STATUS_SNAPSHOT)

/**
 * Whether the last `masc/lspStatus` payload was rejected.
 *
 * A payload is taken whole or not at all, so one unreadable language entry
 * drops the snapshot and `lspStatusSnapshot` keeps what it had. That value is
 * then a past reading presented as the present one: the chip can say
 * `LSP unavailable 1` about a server that has since come back, or say nothing
 * about one that has since died, and neither corrects itself before a reload.
 *
 * This is the separate fact the statusbar needs to say so. It is not folded
 * into the snapshot because the snapshot answers which languages have a
 * server, and this answers whether that answer is current.
 */
export const lspStatusRejected = signal(false)

const LSP_TERMINAL_CLOSE_CODES = new Set([1008, 4401, 4403])

// ── State Effects ────────────────────────────────────────────────

/** Debounce window for LSP refresh + hover triggers (milliseconds).
 *  Short enough to feel responsive, long enough to coalesce typing /
 *  mouse-move bursts. */
const LSP_DEBOUNCE_MS = 300

const setCodeLenses = StateEffect.define<ReadonlyMap<number, LspCodeLens[]>>()
const setInlayHints = StateEffect.define<ReadonlyMap<number, LspInlayHint[]>>()
const setDiagnostics = StateEffect.define<ReadonlyMap<number, LspDiagnostic[]>>()

// ── State Fields ─────────────────────────────────────────────────

const codeLensField = StateField.define<ReadonlyMap<number, LspCodeLens[]>>({
  create() { return new Map() },
  update(state, tr) {
    if (tr.docChanged) return new Map()
    for (const eff of tr.effects) {
      if (eff.is(setCodeLenses)) return eff.value
    }
    return state
  },
})

const inlayHintField = StateField.define<ReadonlyMap<number, LspInlayHint[]>>({
  create() { return new Map() },
  update(state, tr) {
    if (tr.docChanged) return new Map()
    for (const eff of tr.effects) {
      if (eff.is(setInlayHints)) return eff.value
    }
    return state
  },
})

const diagnosticField = StateField.define<ReadonlyMap<number, LspDiagnostic[]>>({
  create() { return new Map() },
  update(state, tr) {
    if (tr.docChanged) return new Map()
    for (const eff of tr.effects) {
      if (eff.is(setDiagnostics)) return eff.value
    }
    return state
  },
})

// ── CodeLens Gutter ──────────────────────────────────────────────

class CodeLensMarker extends GutterMarker {
  constructor(
    private readonly lenses: ReadonlyArray<LspCodeLens>,
  ) { super() }

  toDOM() {
    const container = document.createElement('div')
    container.style.cssText = 'display:flex;flex-direction:column;gap:2px'
    for (const lens of this.lenses) {
      const el = document.createElement('span')
      el.className = 'cm-codelens-marker'
      el.textContent = lens.command?.title ?? ''
      el.style.cssText =
        'display:inline-flex;align-items:center;gap:4px;padding:2px 6px;' +
        'margin:2px 0;font-size:11px;color:var(--color-fg-muted);' +
        'background:var(--color-bg-muted);border-radius:4px;cursor:pointer;user-select:none'
      container.appendChild(el)
    }
    return container
  }

  eq(other: CodeLensMarker): boolean {
    if (this.lenses.length !== other.lenses.length) return false
    return this.lenses.every(
      (l, i) => l.command?.title === other.lenses[i]?.command?.title
    )
  }
}

const CODELENS_EMPTY = new CodeLensMarker([])

const codeLensGutter = gutter({
  class: 'cm-codelens-gutter',
  lineMarker(view, block) {
    const line = view.state.doc.lineAt(block.from)
    const lenses = view.state.field(codeLensField).get(line.number)
    return lenses && lenses.length > 0 ? new CodeLensMarker(lenses) : null
  },
  lineMarkerChange(update: ViewUpdate) {
    return update.startState.field(codeLensField) !== update.state.field(codeLensField)
  },
  initialSpacer: () => CODELENS_EMPTY,
})

// ── Inlay Hint Theme ─────────────────────────────────────────────

const inlayHintTheme = EditorView.theme({
  '.cm-inlayHint': {
    fontSize: '11px',
    color: 'var(--color-fg-muted)',
    background: 'var(--color-bg-muted)',
    padding: '1px 4px',
    borderRadius: '3px',
    marginLeft: '4px',
  },
})

// ── Hover Tooltip Theme ────────────────────────────────────────────

const hoverTooltipTheme = EditorView.theme({
  '.cm-hover-tooltip': {
    position: 'fixed',
    zIndex: '100',
    maxWidth: '480px',
    padding: '8px 12px',
    background: 'var(--color-bg-surface)',
    border: '1px solid var(--color-border-default)',
    borderRadius: '6px',
    boxShadow: 'var(--tooltip-shadow)',
    fontFamily: 'var(--font-mono)',
    fontSize: '12px',
    lineHeight: '1.5',
    color: 'var(--color-fg-secondary)',
    overflow: 'auto',
    whiteSpace: 'pre-wrap',
    wordBreak: 'break-word',
    pointerEvents: 'none',
  },
  '.cm-hover-tooltip hr': {
    border: 'none',
    borderTop: '1px solid var(--color-border-default)',
    margin: '6px 0',
  },
  '.cm-hover-tooltip strong': {
    color: 'var(--color-fg-primary)',
  },
  '.cm-hover-tooltip code': {
    background: 'var(--color-bg-muted)',
    padding: '1px 4px',
    borderRadius: '3px',
    fontSize: '11px',
  },
})

// ── Inlay Hint Widget ────────────────────────────────────────────

class InlayHintWidget extends WidgetType {
  constructor(
    private readonly label: string,
    private readonly tooltip: string | undefined,
  ) { super() }

  toDOM() {
    const span = document.createElement('span')
    span.className = 'cm-inlayHint'
    span.textContent = this.label
    if (this.tooltip) span.title = this.tooltip
    return span
  }

  eq(other: InlayHintWidget): boolean {
    return this.label === other.label && this.tooltip === other.tooltip
  }

  ignoreEvent(): boolean { return false }
}

const inlayHintDecorator = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet

    constructor(view: EditorView) {
      this.decorations = this.build(view)
    }

    update(update: ViewUpdate) {
      if (update.startState.field(inlayHintField) !== update.state.field(inlayHintField)
        || update.docChanged || update.viewportChanged) {
        this.decorations = this.build(update.view)
      }
    }

    private build(view: EditorView): DecorationSet {
      const hints = view.state.field(inlayHintField)
      const builder = new RangeSetBuilder<Decoration>()
      for (const { from, to } of view.visibleRanges) {
        let pos = from
        while (pos <= to) {
          const line = view.state.doc.lineAt(pos)
          const lineHints = hints.get(line.number)
          if (lineHints && lineHints.length > 0) {
            const charOffset = lineHints[0]?.position?.character ?? 0
            const insertPos = Math.min(line.from + charOffset, line.to)
            for (const hint of lineHints) {
              const labelText = typeof hint.label === 'string' ? hint.label : hint.label.value
              builder.add(
                insertPos, insertPos,
                Decoration.widget({
                  widget: new InlayHintWidget(labelText, hint.tooltip),
                  side: 1,
                }),
              )
            }
          }
          pos = line.to + 1
        }
      }
      return builder.finish()
    }
  },
  { decorations: (v) => v.decorations },
)

// ── Diagnostic Gutter ────────────────────────────────────────────

class DiagnosticMark extends GutterMarker {
  constructor(private readonly message: string, private readonly severity: number) {
    super()
  }

  toDOM() {
    const el = document.createElement('div')
    el.className = 'cm-diagnostic-marker'
    el.title = this.message
    const color =
      this.severity === 1 ? 'var(--color-fg-error)' :
      this.severity === 2 ? 'var(--color-fg-warning)' :
      'var(--color-fg-info)'
    el.style.cssText =
      `width:12px;height:12px;border-radius:50%;background:${color};cursor:help`
    return el
  }

  eq(other: DiagnosticMark): boolean {
    return this.message === other.message && this.severity === other.severity
  }
}

const DIAG_EMPTY = new DiagnosticMark('', 0)

const diagnosticGutter = gutter({
  class: 'cm-diagnostic-gutter',
  lineMarker(view, block) {
    const line = view.state.doc.lineAt(block.from)
    const diags = view.state.field(diagnosticField).get(line.number)
    if (!diags || diags.length === 0) return null
    const mostSevere = diags.reduce((worst, d) =>
      (d.severity ?? 3) < (worst.severity ?? 3) ? d : worst
    )
    return new DiagnosticMark(mostSevere.message, mostSevere.severity ?? 3)
  },
  lineMarkerChange(update: ViewUpdate) {
    return update.startState.field(diagnosticField) !== update.state.field(diagnosticField)
  },
  initialSpacer: () => DIAG_EMPTY,
})

// ── JSON-RPC Client ──────────────────────────────────────────────

interface PendingRequest {
  resolve: (value: unknown) => void
  reject: (reason: unknown) => void
}

export class LspConnection {
  private ws: WebSocket | null = null
  private nextId = 1
  private pending = new Map<number, PendingRequest>()
  private disposed = false
  private initialized = false
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null
  private reconnectDelayMs = TRANSPORT_RETRY_BASE_MS
  /**
   * Absolute host path of the workspace tree, from the initialize result.
   * Until it arrives we cannot name a document: we know the repo-relative
   * path we browsed, not the tree it hangs off, and `textDocument.uri` has
   * to be an absolute `file:` URI. Requests are skipped rather than sent
   * with a path the server would have to guess at.
   */
  private workspaceRoot: string | null = null
  private connectedScope: LspScope = EMPTY_LSP_SCOPE
  private generation = 0
  private document: { filePath: string; language: string; text: string; version: number; openedVersion: number | null } | null = null
  private connectionState: LspDocumentConnection = { kind: 'connecting' }
  private diagnosticState: LspDocumentDiagnostics = { kind: 'pending' }
  private languageStatus: LspLanguageStatus | null = null

  private publishDocument(): void {
    const doc = this.document
    if (!doc) return
    publishLspDocument(this, {
      filePath: doc.filePath, scope: lspScopeKey(this.connectedScope), language: doc.language,
      version: doc.version, command: this.languageStatus?.command ?? null,
      connection: this.connectionState, diagnostics: this.diagnosticState,
    })
  }

  private clearAnalysis(connection: LspDocumentConnection): void {
    this.generation += 1
    this.connectionState = connection
    this.diagnosticState = { kind: 'pending' }
    this.languageStatus = null
    if (this.document) {
      this.document.openedVersion = null
      if (ownsLspDocument(this)) clearLspDiagnosticSnapshot(this.document.filePath)
      this.onDiagnostics(this.document.filePath, new Map())
    }
    if (publishLspDocument(this, null)) {
      lspStatusSnapshot.value = EMPTY_LSP_STATUS_SNAPSHOT
      lspStatusRejected.value = false
    }
    this.publishDocument()
  }

  documentGeneration(): number { return this.generation }
  ownsDocumentObservation(): boolean { return ownsLspDocument(this) }
  hasDocument(filePath: string): boolean { return this.document?.filePath === filePath }

  syncDocument(filePath: string, text: string, scope: LspScope = lspScopeSnapshot()): void {
    if (this.disposed) return
    if (lspScopeKey(scope) !== lspScopeKey(lspScopeSnapshot())) return
    const previous = this.document
    if (previous?.filePath === filePath && previous.text === text) return
    if (previous && previous.filePath !== filePath) this.notifyDidClose(previous.filePath)
    const language = languageIdFromPath(filePath)
    this.document = { filePath, language: language ?? DEFAULT_LANGUAGE_ID, text,
      version: previous?.filePath === filePath ? previous.version + 1 : 1,
      openedVersion: previous?.filePath === filePath ? previous.openedVersion : null }
    ownLspDocument(this)
    this.generation += 1
    this.diagnosticState = { kind: 'pending' }
    clearLspDiagnosticSnapshot(filePath)
    if (language === null) this.connectionState = { kind: 'unsupported' }
    this.publishDocument()
    if (!this.initialized || language === null) return
    const uri = this.documentUri(filePath)
    if (uri === null) return
    if (this.document.openedVersion === null) this.openDocument()
    else this.sendNotification('textDocument/didChange', {
      textDocument: { uri, version: this.document.version },
      contentChanges: [{ text }],
    })
  }

  private openDocument(): void {
    const doc = this.document
    if (!doc || !this.initialized || languageIdFromPath(doc.filePath) === null) return
    const uri = this.documentUri(doc.filePath)
    if (uri === null) return
    if (this.sendNotification('textDocument/didOpen', {
      textDocument: { uri, languageId: doc.language, version: doc.version, text: doc.text },
    })) doc.openedVersion = doc.version
  }

  constructor(
    private readonly onDiagnostics: (uri: string | undefined, diags: ReadonlyMap<number, LspDiagnostic[]>) => void,
    private readonly onError: (err: unknown) => void,
    private readonly onReady: () => void = () => {},
  ) {}

  connect(): void {
    if (this.disposed) return
    this.clearReconnectTimer()
    const previous = this.ws
    this.ws = null
    previous?.close()
    this.rejectPending(new Error('LSP connection replaced'))
    this.initialized = false
    scopeConnections.add(this)
    const origin = typeof window !== 'undefined' ? window.location.origin : DEFAULT_MASC_ORIGIN
    const scope = lspScopeSnapshot()
    this.connectedScope = scope
    this.workspaceRoot = null
    this.clearAnalysis(this.document && languageIdFromPath(this.document.filePath) === null ? { kind: 'unsupported' } : { kind: 'connecting' })
    const wsUrl =
      origin.replace(/^http/, 'ws') + '/api/v1/ide/lsp' + lspScopeQuery(scope)
    const ws = new WebSocket(wsUrl)
    this.ws = ws

    ws.onopen = () => {
      if (this.disposed || this.ws !== ws) { ws.close(); return }
      void this.initialize(ws)
    }

    ws.onmessage = (event) => {
      if (this.disposed || this.ws !== ws) return
      try {
        const msg = JSON.parse(event.data)
        this.handleMessage(msg)
      } catch (err) {
        console.error('[LSP] message parse error:', err)
      }
    }

    ws.onclose = (event) => {
      if (this.disposed || this.ws !== ws) return
      this.ws = null
      this.initialized = false
      const reason = new Error(lspCloseReason(event))
      this.workspaceRoot = null
      this.clearAnalysis({ kind: 'disconnected', reason: reason.message })
      this.rejectPending(reason)
      if (shouldReconnectLspClose(event)) {
        this.scheduleReconnect()
      } else {
        this.onError(reason)
      }
    }

    ws.onerror = () => {
      if (this.disposed || this.ws !== ws) return
      this.handleSocketSendFailure(ws, new Error('Language server WebSocket error'))
    }
  }

  private handleMessage(msg: {
    id?: number
    method?: string
    params?: unknown
    result?: unknown
    error?: unknown
  }): void {
    if (msg.id != null && this.pending.has(msg.id)) {
      const { resolve, reject } = this.pending.get(msg.id)!
      this.pending.delete(msg.id)
      if (msg.error) reject(msg.error)
      else resolve(msg.result)
      return
    }

    if (msg.method === 'textDocument/publishDiagnostics' && msg.params) {
      const params = msg.params as { uri?: string; version?: number; diagnostics?: unknown }
      const doc = this.document
      if (!doc || params.uri !== this.documentUri(doc.filePath)) return
      if (params.version !== undefined && params.version !== doc.version) return
      const diagnostics = parseDiagnostics(params.diagnostics)
      if (diagnostics === null) {
        this.diagnosticState = { kind: 'failed', reason: 'Malformed published diagnostics' }
        this.publishDocument()
        return
      }
      // Some servers (including ocamllsp) omit the optional version even when
      // versionSupport is advertised. Keep their reports usable, but never
      // label a post-change unversioned report as verified for this revision.
      this.diagnosticState = params.version === undefined && doc.openedVersion !== doc.version
        ? { kind: 'unversioned', count: diagnostics.length }
        : { kind: 'complete', count: diagnostics.length }
      this.publishDocument()
      this.onDiagnostics(params.uri, indexByLine(diagnostics, diag => diag.range.start.line + 1))
    } else if (msg.method === 'masc/lspStatus') {
      publishLspStatusSnapshot(msg.params)
      const snapshot = parseLspStatusSnapshot(msg.params)
      if (this.document) {
        this.languageStatus = snapshot?.langs.find(lang => lang.lang === serverLanguageId(this.document!.language)) ?? null
        if (this.languageStatus) {
          this.connectionState = this.languageStatus.connected ? { kind: 'connected' }
            : { kind: 'unavailable', reason: this.languageStatus.last_error ?? 'Language server unavailable' }
          if (!this.languageStatus.connected) {
            this.diagnosticState = { kind: 'pending' }
            if (ownsLspDocument(this)) clearLspDiagnosticSnapshot(this.document.filePath)
            this.onDiagnostics(this.document.filePath, new Map())
          }
        } else if (snapshot === null) {
          this.connectionState = { kind: 'failed', reason: 'Unreadable language server status' }
        }
        this.publishDocument()
      }
    }
  }

  private sendRequest(method: string, params: unknown): Promise<unknown> {
    return new Promise((resolve, reject) => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
        reject(new Error('WebSocket not connected'))
        return
      }
      const id = this.nextId++
      const currentSocket = this.ws
      this.pending.set(id, { resolve, reject })
      try {
        currentSocket.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }))
      } catch (err) {
        this.pending.delete(id)
        const reason = err instanceof Error ? err : new Error(String(err))
        this.handleSocketSendFailure(currentSocket, reason)
        reject(reason)
      }
    })
  }

  private sendNotification(method: string, params: unknown): boolean {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false
    const currentSocket = this.ws
    try {
      currentSocket.send(JSON.stringify({ jsonrpc: '2.0', method, params }))
      return true
    } catch (err) {
      const reason = err instanceof Error ? err : new Error(String(err))
      this.handleSocketSendFailure(currentSocket, reason)
      return false
    }
  }

  private handleSocketSendFailure(ws: WebSocket, reason: Error): void {
    if (this.disposed || this.ws !== ws) return
    this.onError(reason)
    this.ws = null
    this.initialized = false
    this.workspaceRoot = null
    this.clearAnalysis({ kind: 'disconnected', reason: reason.message })
    this.rejectPending(reason)
    try {
      ws.close()
    } catch {
      // Ignore close failures; the reconnect timer below owns recovery.
    }
    this.scheduleReconnect()
  }

  /**
   * The socket carries its scope in its URL, so a scope change makes the
   * live connection address the wrong partition and the wrong tree.
   * Reconnecting is the only way to re-declare it. The old socket's handlers
   * no-op once `this.ws` moves on.
   */
  refreshScopeIfStale(): void {
    if (this.disposed) return
    const scope = lspScopeSnapshot()
    if (
      scope.repoId === this.connectedScope.repoId
      && scope.codebase === this.connectedScope.codebase
      && scope.keeper === this.connectedScope.keeper
    ) return
    const previous = this.ws
    this.ws = null
    this.initialized = false
    this.workspaceRoot = null
    this.rejectPending(new Error('LSP scope changed'))
    previous?.close()
    this.clearAnalysis({ kind: 'disconnected', reason: 'Workspace changed' })
    // The old document belongs to the old tree, even if the next tree has the
    // same relative path. Only a fresh store snapshot may open the next one.
    this.document = null
    publishLspDocument(this, null)
    this.resetReconnectBackoff()
    this.connect()
  }

  private scheduleReconnect(): void {
    if (this.disposed) return
    if (this.reconnectTimer !== null) return
    const delayMs =
      Math.min(this.reconnectDelayMs, TRANSPORT_RETRY_MAX_MS)
      + Math.random() * TRANSPORT_RETRY_JITTER_MS // real-randomness-needed: transport retry jitter
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null
      if (!this.disposed) this.connect()
    }, delayMs)
    this.reconnectDelayMs = Math.min(this.reconnectDelayMs * 2, TRANSPORT_RETRY_MAX_MS)
  }

  private async initialize(socket: WebSocket): Promise<void> {
    try {
      const result = await this.sendRequest('initialize', {
        processId: null,
        clientInfo: { name: 'masc-ide', version: '1.0.0' },
        locale: 'ko',
        // The server resolves the tree from the scope on the connection URL
        // and reports it back; a browser client has no host path to offer.
        rootUri: '',
        capabilities: {
          textDocument: {
            codeLens: {},
            inlayHint: {},
            diagnostic: {},
            publishDiagnostics: { versionSupport: true },
          },
        },
      })
      if (this.disposed || this.ws !== socket) return
      this.workspaceRoot = workspaceRootOfInitializeResult(result)
      if (this.workspaceRoot === null) throw new Error('Language server did not resolve the workspace root')
      this.initialized = this.sendNotification('initialized', {})
      if (this.initialized) {
        this.resetReconnectBackoff()
        this.openDocument()
        this.onReady()
      }
    } catch (err) {
      if (!this.disposed && this.ws === socket) {
        this.clearAnalysis({ kind: 'failed', reason: err instanceof Error ? err.message : String(err) })
        this.onError(err)
        console.error('[LSP] initialize failed:', err)
      }
    }
  }

  /**
   * Absolute URI for a repo-relative document path, or `null` while the
   * workspace tree is still unknown (before the initialize result lands, or
   * on a connection the server declined to anchor).
   */
  private documentUri(filePath: string): string | null {
    const root = this.workspaceRoot
    return root === null ? null : toFileUri(root, filePath)
  }

  async requestCodeLenses(filePath: string): Promise<ReadonlyMap<number, LspCodeLens[]>> {
    const uri = this.documentUri(filePath)
    if (uri === null) return new Map()
    try {
      const result = await this.sendRequest('textDocument/codeLens', {
        textDocument: { uri },
      }) as LspCodeLens[] | null
      return indexByLine(result ?? [], (l) => (l.range?.start?.line ?? 0) + 1)
    } catch {
      return new Map()
    }
  }

  async requestInlayHints(filePath: string, lineCount: number): Promise<ReadonlyMap<number, LspInlayHint[]>> {
    const uri = this.documentUri(filePath)
    if (uri === null) return new Map()
    const range = {
      start: { line: 0, character: 0 },
      end: { line: lineCount, character: 0 },
    }
    try {
      const result = await this.sendRequest('textDocument/inlayHint', {
        textDocument: { uri },
        range,
      }) as LspInlayHint[] | null
      return indexByLine(result ?? [], (h) => (h.position?.line ?? 0) + 1)
    } catch {
      return new Map()
    }
  }

  async requestDiagnostics(filePath: string): Promise<ReadonlyMap<number, LspDiagnostic[]>> {
    const uri = this.documentUri(filePath)
    const generation = this.generation
    if (uri === null || !this.initialized) throw new Error('Language server is not ready')
    try {
      const result = await this.sendRequest('textDocument/diagnostic', { textDocument: { uri } })
      if (generation !== this.generation || this.disposed) throw new Error('Superseded document diagnostics')
      const report = typeof result === 'object' && result !== null
        ? result as { kind?: unknown; items?: unknown } : null
      const diagnostics = parseDiagnostics(report?.kind === 'full' ? report.items : undefined)
      if (diagnostics === null) throw new Error('Malformed document diagnostics')
      if (this.document && this.languageStatus?.connected !== true) {
        throw new Error('Language server has not confirmed availability')
      }
      this.diagnosticState = { kind: 'complete', count: diagnostics.length }
      this.publishDocument()
      return indexByLine(diagnostics, diagnostic => diagnostic.range.start.line + 1)
    } catch (error) {
      if (generation === this.generation && !this.disposed) {
        // A server using push diagnostics may reject the optional pull method.
        // Preserve a confirmed current push result, never synthesize an empty one.
        if (this.diagnosticState.kind !== 'complete' && this.diagnosticState.kind !== 'unversioned') {
          this.diagnosticState = { kind: 'failed', reason: error instanceof Error ? error.message : JSON.stringify(error) }
          this.publishDocument()
        }
      }
      throw error
    }
  }

  async requestHover(filePath: string, line: number, character: number): Promise<unknown> {
    const uri = this.documentUri(filePath)
    if (uri === null) return null
    try {
      const generation = this.generation
      const result = await this.sendRequest('textDocument/hover', {
        textDocument: { uri },
        position: { line, character },
      })
      return generation === this.generation && !this.disposed ? result : null
    } catch {
      return null
    }
  }

  notifyDidClose(filePath: string): void {
    if (!this.initialized) return
    const uri = this.documentUri(filePath)
    if (uri === null) return
    this.sendNotification('textDocument/didClose', {
      textDocument: { uri },
    })
  }

  notifyDidSave(filePath: string): void {
    if (!this.initialized) return
    const uri = this.documentUri(filePath)
    if (uri === null) return
    this.sendNotification('textDocument/didSave', {
      textDocument: { uri },
    })
  }

  dispose(): void {
    this.disposed = true
    scopeConnections.delete(this)
    this.clearAnalysis({ kind: 'disconnected', reason: 'Editor document closed' })
    publishLspDocument(this, null)
    this.clearReconnectTimer()
    this.rejectPending(new Error('Connection disposed'))
    if (this.ws) {
      this.ws.close()
      this.ws = null
    }
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer === null) return
    clearTimeout(this.reconnectTimer)
    this.reconnectTimer = null
  }

  private resetReconnectBackoff(): void {
    this.reconnectDelayMs = TRANSPORT_RETRY_BASE_MS
  }

  private rejectPending(reason: Error): void {
    for (const [, { reject }] of this.pending) {
      reject(reason)
    }
    this.pending.clear()
  }
}

// ── Helpers ───────────────────────────────────────────────────────

/**
 * `textDocument.uri` must be an absolute `file:` URI. Prefixing a
 * repo-relative path with `file://` does not produce one — the first path
 * segment lands in the authority slot — so the server rejected every such
 * document as outside its workspace and answered with an empty result.
 */
function toFileUri(workspaceRoot: string, filePath: string): string {
  const root = workspaceRoot.endsWith('/') ? workspaceRoot.slice(0, -1) : workspaceRoot
  return filePath.startsWith('/') ? `file://${filePath}` : `file://${root}/${filePath}`
}

function workspaceRootOfInitializeResult(result: unknown): string | null {
  if (typeof result !== 'object' || result === null) return null
  const masc = (result as { masc?: unknown }).masc
  if (typeof masc !== 'object' || masc === null) return null
  const root = (masc as { workspaceRoot?: unknown }).workspaceRoot
  return typeof root === 'string' && root !== '' ? root : null
}

function lspCloseReason(event: CloseEvent): string {
  const code = event.code ? ` ${event.code}` : ''
  const reason = event.reason ? `: ${event.reason}` : ''
  return `WebSocket closed${code}${reason}`
}

function shouldReconnectLspClose(event: CloseEvent): boolean {
  return !LSP_TERMINAL_CLOSE_CODES.has(event.code)
}

export function resolveLspDiagnosticFilePath(
  uri: string | undefined,
  currentFilePath: string,
): string | null {
  if (!uri) return null
  const rawPath = uri.startsWith('file://') ? uri.slice('file://'.length) : uri
  const decodedPath = decodeUriPath(rawPath)
  const normalized = normalizeIdeContextFilePath(decodedPath)
  if (normalized !== null) return normalized

  const normalizedCurrent = normalizeIdeContextFilePath(currentFilePath)
  if (normalizedCurrent === null) return null
  return decodedPath.endsWith(`/${normalizedCurrent}`) || decodedPath === normalizedCurrent
    ? normalizedCurrent
    : null
}

function decodeUriPath(rawPath: string): string {
  try {
    return decodeURIComponent(rawPath)
  } catch {
    return rawPath
  }
}

function parseDiagnostics(value: unknown): LspDiagnostic[] | null {
  if (!Array.isArray(value)) return null
  const validPosition = (position: unknown): boolean => {
    if (typeof position !== 'object' || position === null) return false
    const { line, character } = position as { line?: unknown; character?: unknown }
    return Number.isSafeInteger(line) && Number(line) >= 0
      && Number.isSafeInteger(character) && Number(character) >= 0
  }
  for (const item of value) {
    if (typeof item !== 'object' || item === null || typeof item.message !== 'string'
      || typeof item.range !== 'object' || item.range === null
      || !validPosition(item.range.start) || !validPosition(item.range.end)) return null
  }
  return value as LspDiagnostic[]
}

function indexByLine<T>(items: ReadonlyArray<T>, getLine: (item: T) => number): Map<number, T[]> {
  const map = new Map<number, T[]>()
  for (const item of items) {
    const line = getLine(item)
    const existing = map.get(line) ?? []
    existing.push(item)
    map.set(line, existing)
  }
  return map
}

export function parseLspStatusSnapshot(value: unknown): LspStatusSnapshot | null {
  if (!isRecord(value)) return null
  const langs = value.langs
  if (!Array.isArray(langs)) return null

  const parsed: LspLanguageStatus[] = []
  for (const lang of langs) {
    const status = parseLspLanguageStatus(lang)
    if (status === null) return null
    parsed.push(status)
  }
  return { langs: parsed }
}

function parseLspLanguageStatus(value: unknown): LspLanguageStatus | null {
  if (!isRecord(value)) return null
  const { lang, connected, command, last_error } = value
  if (typeof lang !== 'string') return null
  if (typeof connected !== 'boolean') return null
  if (!isStringOrNull(command)) return null
  if (!isStringOrNull(last_error)) return null
  return {
    lang,
    connected,
    command,
    last_error,
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isStringOrNull(value: unknown): value is string | null {
  return typeof value === 'string' || value === null
}

function publishLspStatusSnapshot(value: unknown): void {
  const parsed = parseLspStatusSnapshot(value)
  if (parsed === null) {
    console.warn('[LSP] invalid masc/lspStatus payload')
    lspStatusRejected.value = true
    return
  }
  lspStatusSnapshot.value = parsed
  lspStatusRejected.value = false
}

function publishLspDiagnosticSnapshot(
  filePath: string,
  diagnostics: ReadonlyMap<number, ReadonlyArray<LspDiagnostic>>,
): void {
  const normalizedFilePath = normalizeIdeContextFilePath(filePath)
  if (normalizedFilePath === null) return

  const anchors: LspDiagnosticAnchor[] = []
  for (const [line, items] of diagnostics) {
    for (const diagnostic of items) {
      anchors.push({
        file_path: normalizedFilePath,
        line,
        severity: diagnostic.severity,
        code: diagnostic.code,
        source: diagnostic.source,
        message: diagnostic.message,
      })
    }
  }
  anchors.sort((left, right) =>
    lineSeverityOrder(left) - lineSeverityOrder(right)
    || left.line - right.line
    || left.message.localeCompare(right.message),
  )

  const next = new Map(lspDiagnosticSnapshot.value)
  if (anchors.length === 0) {
    next.delete(normalizedFilePath)
  } else {
    next.set(normalizedFilePath, anchors)
  }
  lspDiagnosticSnapshot.value = next
}

export function clearLspDiagnosticSnapshot(filePath: string): void {
  const normalizedFilePath = normalizeIdeContextFilePath(filePath)
  if (normalizedFilePath === null) return
  const next = new Map(lspDiagnosticSnapshot.value)
  if (!next.delete(normalizedFilePath)) return
  lspDiagnosticSnapshot.value = next
}

function lineSeverityOrder(diagnostic: LspDiagnosticAnchor): number {
  return diagnostic.severity ?? 99
}

function serverLanguageId(language: string): string {
  return language === 'typescriptreact' ? 'typescript' : language === 'javascriptreact' ? 'javascript' : language
}

function languageIdFromPath(filePath: string): string | null {
  const ext = filePath.slice(filePath.lastIndexOf('.')).toLowerCase()
  const MAP: Record<string, string> = {
    '.ts': 'typescript', '.tsx': 'typescriptreact',
    '.js': 'javascript', '.jsx': 'javascriptreact',
    '.py': 'python', '.pyi': 'python', '.ml': 'ocaml', '.mli': 'ocaml',
    '.mjs': 'javascript', '.cjs': 'javascript',
    '.c': 'c', '.h': 'c', '.cc': 'cpp', '.cpp': 'cpp', '.cxx': 'cpp', '.hpp': 'cpp', '.hh': 'cpp', '.hxx': 'cpp',
    '.swift': 'swift', '.java': 'java', '.kt': 'kotlin', '.kts': 'kotlin',
    '.rb': 'ruby', '.php': 'php', '.lua': 'lua', '.sh': 'shellscript', '.bash': 'shellscript', '.zsh': 'shellscript',
    '.zig': 'zig', '.hs': 'haskell', '.ex': 'elixir', '.exs': 'elixir', '.dart': 'dart',
    '.scala': 'scala', '.sc': 'scala', '.cs': 'csharp',
    '.rs': 'rust', '.go': 'go', '.json': 'json',
    '.md': 'markdown', '.markdown': 'markdown', '.yaml': 'yaml', '.yml': 'yaml',
  }
  return MAP[ext] ?? null
}

// ── Config field (passes filePath into CM6 state) ────────────────

interface LspConfig { readonly filePath: string }

// Init-only. ide-editor rebuilds the whole EditorState when
// document.file_path changes -- the mount effect lists it as a dependency and
// its cleanup destroys the view -- so nothing ever swaps this field's value
// under a live view, and there is no effect to dispatch.
const lspConfigField = StateField.define<LspConfig>({
  create() { return { filePath: '' } },
  update(state) { return state },
})

// ── View Plugin ──────────────────────────────────────────────────

const lspViewPlugin = ViewPlugin.fromClass(
  class {
    private conn: LspConnection
    private filePath: string
    private readonly documentScope = lspScopeSnapshot()
    private refreshTimer: ReturnType<typeof setTimeout> | null = null
    private hoverTimer: ReturnType<typeof setTimeout> | null = null
    private tooltip: HTMLDivElement | null = null
    private hoverClientX = 0
    private hoverClientY = 0
    private boundHoverMove: ((e: MouseEvent) => void) | null = null
    private boundHoverLeave: (() => void) | null = null

    constructor(private readonly view: EditorView) {
      const filePath = view.state.field(lspConfigField).filePath
      this.filePath = filePath
      this.conn = new LspConnection(
        (diagnosticUri, diags) => {
          const filePath = resolveLspDiagnosticFilePath(diagnosticUri, this.filePath)
          if (filePath === null) return
          const generation = this.conn.documentGeneration()
          queueMicrotask(() => {
            if (!this.view.dom.isConnected || !this.conn.ownsDocumentObservation()
              || generation !== this.conn.documentGeneration()) return
            publishLspDiagnosticSnapshot(filePath, diags)
            const normalizedFilePath = normalizeIdeContextFilePath(filePath)
            const normalizedCurrentFilePath = normalizeIdeContextFilePath(this.filePath)
            if (normalizedFilePath !== null && normalizedFilePath === normalizedCurrentFilePath) {
              this.dispatch(setDiagnostics.of(diags))
            }
          })
        },
        (err) => console.error('[LSP] connection error:', err),
        () => {
          this.scheduleRefresh()
        },
      )
      this.conn.syncDocument(filePath, view.state.doc.toString(), this.documentScope)
      this.conn.connect()
      this.boundHoverMove = (e) => this.onHoverMove(e)
      this.boundHoverLeave = () => this.onHoverLeave()
      this.view.dom.addEventListener('mousemove', this.boundHoverMove)
      this.view.dom.addEventListener('mouseleave', this.boundHoverLeave)
      this.scheduleRefresh()
    }

    update(update: ViewUpdate) {
      this.conn.refreshScopeIfStale()
      if (update.docChanged) {
        this.hideTooltip()
        this.conn.syncDocument(this.filePath, update.state.doc.toString(), this.documentScope)
        this.scheduleRefresh()
      }
    }

    private scheduleRefresh(): void {
      if (this.refreshTimer) clearTimeout(this.refreshTimer)
      this.refreshTimer = setTimeout(() => this.refresh(), LSP_DEBOUNCE_MS)
    }

    private async refresh(): Promise<void> {
      const fp = this.filePath
      const view = this.view
      const generation = this.conn.documentGeneration()
      if (!view.dom.isConnected || !this.conn.hasDocument(fp)) return

      const [lenses, hints, diags] = await Promise.allSettled([
        this.conn.requestCodeLenses(fp),
        this.conn.requestInlayHints(fp, view.state.doc.lines),
        this.conn.requestDiagnostics(fp),
      ])

      if (!view.dom.isConnected) return
      if (fp !== this.filePath || generation !== this.conn.documentGeneration()) return
      const effects: StateEffect<unknown>[] = []
      if (lenses.status === 'fulfilled') effects.push(setCodeLenses.of(lenses.value))
      if (hints.status === 'fulfilled') effects.push(setInlayHints.of(hints.value))
      if (diags.status === 'fulfilled') {
        publishLspDiagnosticSnapshot(fp, diags.value)
        effects.push(setDiagnostics.of(diags.value))
      }
      if (effects.length > 0) view.dispatch({ effects })
    }

    private onHoverMove(e: MouseEvent): void {
      this.hoverClientX = e.clientX
      this.hoverClientY = e.clientY
      if (this.hoverTimer) clearTimeout(this.hoverTimer)
      this.hoverTimer = setTimeout(() => void this.triggerHover(), LSP_DEBOUNCE_MS)
    }

    private onHoverLeave(): void {
      if (this.hoverTimer) {
        clearTimeout(this.hoverTimer)
        this.hoverTimer = null
      }
      this.hideTooltip()
    }

    private async triggerHover(): Promise<void> {
      const view = this.view
      if (!view.dom.isConnected) return

      const pos = view.posAtCoords({ x: this.hoverClientX, y: this.hoverClientY })
      if (pos === null || pos < 0) { this.hideTooltip(); return }

      const line = view.state.doc.lineAt(pos)
      const character = pos - line.from
      const filePath = view.state.field(lspConfigField).filePath
      if (!filePath) return

      const result = await this.conn.requestHover(filePath, line.number - 1, character)
      if (!view.dom.isConnected) return

      const hover = result as { contents?: { kind?: string; value?: string } } | null
      if (!hover?.contents?.value) return

      this.showTooltip(hover.contents.value, this.hoverClientX, this.hoverClientY)
    }

    private showTooltip(markdown: string, clientX: number, clientY: number): void {
      this.hideTooltip()
      const div = document.createElement('div')
      div.className = 'cm-hover-tooltip'
      div.style.visibility = 'hidden'
      const html = markdown
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
        .replace(/`([^`]+)`/g, '<code>$1</code>')
        .replace(/^---$/gm, '<hr>')
        .replace(/^- (.+)$/gm, '• $1')
        .replace(/\n/g, '<br>')
      div.innerHTML = html
      document.body.appendChild(div)

      const PAD = 10
      requestAnimationFrame(() => {
        const rect = div.getBoundingClientRect()
        let left = clientX + PAD
        let top = clientY + PAD
        if (left + rect.width > window.innerWidth - PAD) left = clientX - rect.width - PAD
        if (top + rect.height > window.innerHeight - PAD) top = clientY - rect.height - PAD
        div.style.left = `${Math.max(PAD, left)}px`
        div.style.top = `${Math.max(PAD, top)}px`
        div.style.visibility = 'visible'
      })
      this.tooltip = div
    }

    private hideTooltip(): void {
      if (this.tooltip) {
        this.tooltip.remove()
        this.tooltip = null
      }
    }

    destroy() {
      if (this.refreshTimer) clearTimeout(this.refreshTimer)
      if (this.hoverTimer) clearTimeout(this.hoverTimer)
      this.hideTooltip()
      if (this.boundHoverMove) this.view.dom.removeEventListener('mousemove', this.boundHoverMove)
      if (this.boundHoverLeave) this.view.dom.removeEventListener('mouseleave', this.boundHoverLeave)
      this.conn.notifyDidClose(this.filePath)
      this.conn.dispose()
      clearLspDiagnosticSnapshot(this.filePath)
    }

    private dispatch(...effects: StateEffect<unknown>[]): void {
      if (this.view.dom.isConnected) {
        this.view.dispatch({ effects })
      }
    }
  },
)

// ── Public API ───────────────────────────────────────────────────

export interface LspExtensionOpts {
  readonly filePath: string
}

export function lspExtension(opts: LspExtensionOpts): Extension {
  return [
    lspConfigField.init(() => ({ filePath: opts.filePath })),
    codeLensField,
    inlayHintField,
    diagnosticField,
    codeLensGutter,
    diagnosticGutter,
    inlayHintTheme,
    inlayHintDecorator,
    hoverTooltipTheme,
    lspViewPlugin,
  ]
}
