/**
 * IDE LSP Client — CodeMirror 6 extension for Language Server Protocol
 * with MASC observational overlay integration.
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
  TRANSPORT_RETRY_MAX_ATTEMPTS,
  TRANSPORT_RETRY_MAX_MS,
} from '../../config/constants'
import { DEFAULT_LANGUAGE_ID } from './ide-language'
import {
  subscribeStoredTokenChanges,
  websocketProtocolsWithDashboardBearer,
} from '../../api/core'

// ── Types ─────────────────────────────────────────────────────────

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
  data?: {
    keeper_id?: string
    annotation_id?: string
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
  readonly overlay_only: boolean
  readonly command: string | null
  readonly last_error: string | null
}

export interface LspStatusSnapshot {
  readonly langs: ReadonlyArray<LspLanguageStatus>
}

export const EMPTY_LSP_STATUS_SNAPSHOT: LspStatusSnapshot = { langs: [] }
export const lspStatusSnapshot = signal<LspStatusSnapshot>(EMPTY_LSP_STATUS_SNAPSHOT)

const LSP_TERMINAL_CLOSE_CODES = new Set([1008, 4401, 4403])

export interface SelectedAnnotation {
  readonly id: string
  readonly keeper_id: string
  readonly kind: string
  readonly content: string
  readonly goal_id: string | null
  readonly task_id: string | null
  readonly file_path: string
  readonly line_start: number
  readonly line_end: number
}

// ── State Effects ────────────────────────────────────────────────

/** Debounce window for LSP refresh + hover triggers (milliseconds).
 *  Short enough to feel responsive, long enough to coalesce typing /
 *  mouse-move bursts. */
const LSP_DEBOUNCE_MS = 300

const setCodeLenses = StateEffect.define<ReadonlyMap<number, LspCodeLens[]>>()
const setInlayHints = StateEffect.define<ReadonlyMap<number, LspInlayHint[]>>()
const setDiagnostics = StateEffect.define<ReadonlyMap<number, LspDiagnostic[]>>()
const setSelectedAnnotation = StateEffect.define<SelectedAnnotation | null>()

// ── State Fields ─────────────────────────────────────────────────

const codeLensField = StateField.define<ReadonlyMap<number, LspCodeLens[]>>({
  create() { return new Map() },
  update(state, tr) {
    for (const eff of tr.effects) {
      if (eff.is(setCodeLenses)) return eff.value
    }
    return state
  },
})

const inlayHintField = StateField.define<ReadonlyMap<number, LspInlayHint[]>>({
  create() { return new Map() },
  update(state, tr) {
    for (const eff of tr.effects) {
      if (eff.is(setInlayHints)) return eff.value
    }
    return state
  },
})

const diagnosticField = StateField.define<ReadonlyMap<number, LspDiagnostic[]>>({
  create() { return new Map() },
  update(state, tr) {
    for (const eff of tr.effects) {
      if (eff.is(setDiagnostics)) return eff.value
    }
    return state
  },
})

const selectedAnnotationField = StateField.define<SelectedAnnotation | null>({
  create() { return null },
  update(state, tr) {
    for (const eff of tr.effects) {
      if (eff.is(setSelectedAnnotation)) return eff.value
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
      if (lens.command?.command === 'masc.showAnnotation' && lens.command.arguments) {
        el.addEventListener('click', (e) => {
          e.preventDefault()
          e.stopPropagation()
          const detail = lens.command!.arguments![0] as SelectedAnnotation
          el.dispatchEvent(new CustomEvent('masc-annotation-select', {
            bubbles: true,
            detail,
          }))
        })
      }
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
  private reconnectAttempts = 0
  private reconnectDelayMs = TRANSPORT_RETRY_BASE_MS
  private started = false
  private unsubscribeTokenChanges: (() => void) | null = null

  constructor(
    private readonly onDiagnostics: (uri: string | undefined, diags: ReadonlyMap<number, LspDiagnostic[]>) => void,
    private readonly onError: (err: unknown) => void,
    private readonly onReady: () => void = () => {},
  ) {
    this.unsubscribeTokenChanges = subscribeStoredTokenChanges(() => {
      this.reconnectForCredentialChange()
    })
  }

  connect(): void {
    if (this.disposed) return
    this.started = true
    this.clearReconnectTimer()
    const origin = typeof window !== 'undefined' ? window.location.origin : DEFAULT_MASC_ORIGIN
    const wsUrl = origin.replace(/^http/, 'ws') + '/api/v1/ide/lsp'
    const ws = new WebSocket(
      wsUrl,
      websocketProtocolsWithDashboardBearer(wsUrl, 'masc.ide.v1'),
    )
    this.ws = ws

    ws.onopen = () => {
      if (this.disposed || this.ws !== ws) { ws.close(); return }
      this.initialize()
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
      this.rejectPending(reason)
      if (shouldReconnectLspClose(event)) {
        this.scheduleReconnect()
      } else {
        this.onError(reason)
      }
    }

    ws.onerror = (err) => {
      if (this.disposed || this.ws !== ws) return
      console.error('[LSP] WebSocket error:', err)
      this.onError(err)
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
      const params = msg.params as { uri?: string; diagnostics?: LspDiagnostic[] }
      const diagByLine = new Map<number, LspDiagnostic[]>()
      for (const diag of params.diagnostics ?? []) {
        const line = (diag.range?.start?.line ?? 0) + 1
        const existing = diagByLine.get(line) ?? []
        existing.push(diag)
        diagByLine.set(line, existing)
      }
      this.onDiagnostics(params.uri, diagByLine)
    } else if (msg.method === 'masc/lspStatus') {
      publishLspStatusSnapshot(msg.params)
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
    this.rejectPending(reason)
    try {
      ws.close()
    } catch {
      // Ignore close failures; the reconnect timer below owns recovery.
    }
    this.scheduleReconnect()
  }

  private scheduleReconnect(): void {
    if (this.disposed) return
    if (this.reconnectTimer !== null) return
    if (this.reconnectAttempts >= TRANSPORT_RETRY_MAX_ATTEMPTS) {
      this.onError(new Error('LSP reconnect attempts exhausted'))
      return
    }
    const delayMs =
      Math.min(this.reconnectDelayMs, TRANSPORT_RETRY_MAX_MS)
      + Math.random() * TRANSPORT_RETRY_JITTER_MS
    this.reconnectAttempts += 1
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null
      if (!this.disposed) this.connect()
    }, delayMs)
    this.reconnectDelayMs = Math.min(this.reconnectDelayMs * 2, TRANSPORT_RETRY_MAX_MS)
  }

  private async initialize(): Promise<void> {
    try {
      await this.sendRequest('initialize', {
        processId: null,
        clientInfo: { name: 'masc-ide', version: '1.0.0' },
        locale: 'ko',
        rootUri: '',
        capabilities: {
          textDocument: {
            codeLens: {},
            inlayHint: {},
            diagnostic: {},
          },
        },
      })
      this.initialized = this.sendNotification('initialized', {})
      if (this.initialized) {
        this.resetReconnectBackoff()
        this.onReady()
      }
    } catch (err) {
      if (!this.disposed) {
        console.error('[LSP] initialize failed:', err)
      }
    }
  }

  async requestCodeLenses(filePath: string): Promise<ReadonlyMap<number, LspCodeLens[]>> {
    const uri = toFileUri(filePath)
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
    const uri = toFileUri(filePath)
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
    const uri = toFileUri(filePath)
    try {
      const result = await this.sendRequest('textDocument/diagnostic', {
        textDocument: { uri },
      }) as { items?: LspDiagnostic[] } | null
      const items = result?.items ?? []
      return indexByLine(items, (d) => (d.range?.start?.line ?? 0) + 1)
    } catch {
      return new Map()
    }
  }

  async requestHover(filePath: string, line: number, character: number): Promise<unknown> {
    const uri = toFileUri(filePath)
    try {
      return await this.sendRequest('textDocument/hover', {
        textDocument: { uri },
        position: { line, character },
      })
    } catch {
      return null
    }
  }

  notifyDidOpen(filePath: string, languageId: string): void {
    if (!this.initialized) return
    const uri = toFileUri(filePath)
    this.sendNotification('textDocument/didOpen', {
      textDocument: { uri, languageId, version: 1, text: '' },
    })
  }

  notifyDidClose(filePath: string): void {
    if (!this.initialized) return
    const uri = toFileUri(filePath)
    this.sendNotification('textDocument/didClose', {
      textDocument: { uri },
    })
  }

  notifyDidSave(filePath: string): void {
    if (!this.initialized) return
    const uri = toFileUri(filePath)
    this.sendNotification('textDocument/didSave', {
      textDocument: { uri },
    })
  }

  dispose(): void {
    this.disposed = true
    this.started = false
    this.unsubscribeTokenChanges?.()
    this.unsubscribeTokenChanges = null
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

  private reconnectForCredentialChange(): void {
    if (this.disposed || !this.started) return
    this.clearReconnectTimer()
    this.resetReconnectBackoff()
    this.initialized = false
    this.rejectPending(new Error('LSP bearer credential changed'))
    const current = this.ws
    this.ws = null
    if (current) {
      current.onopen = null
      current.onmessage = null
      current.onerror = null
      current.onclose = null
      try {
        current.close()
      } catch (err) {
        this.onError(err)
      }
    }
    this.connect()
  }

  private resetReconnectBackoff(): void {
    this.reconnectAttempts = 0
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

function toFileUri(filePath: string): string {
  return `file://${filePath}`
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
  const { lang, connected, overlay_only, command, last_error } = value
  if (typeof lang !== 'string') return null
  if (typeof connected !== 'boolean') return null
  if (typeof overlay_only !== 'boolean') return null
  if (!isStringOrNull(command)) return null
  if (!isStringOrNull(last_error)) return null
  return {
    lang,
    connected,
    overlay_only,
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
    return
  }
  lspStatusSnapshot.value = parsed
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

function languageIdFromPath(filePath: string): string | null {
  const ext = filePath.slice(filePath.lastIndexOf('.'))
  const MAP: Record<string, string> = {
    '.ts': 'typescript', '.tsx': 'typescriptreact',
    '.js': 'javascript', '.jsx': 'javascriptreact',
    '.py': 'python', '.ml': 'ocaml', '.mli': 'ocaml',
    '.rs': 'rust', '.go': 'go', '.json': 'json',
    '.md': 'markdown', '.html': 'html', '.css': 'css',
    '.toml': 'toml', '.yaml': 'yaml', '.yml': 'yaml',
  }
  return MAP[ext] ?? null
}

// ── Config field (passes filePath into CM6 state) ────────────────

interface LspConfig { readonly filePath: string }

const setLspConfig = StateEffect.define<LspConfig>()

const lspConfigField = StateField.define<LspConfig>({
  create() { return { filePath: '' } },
  update(state, tr) {
    for (const eff of tr.effects) {
      if (eff.is(setLspConfig)) return eff.value
    }
    return state
  },
})

// ── View Plugin ──────────────────────────────────────────────────

const lspViewPlugin = ViewPlugin.fromClass(
  class {
    private conn: LspConnection
    private filePath: string
    private refreshTimer: ReturnType<typeof setTimeout> | null = null
    private onAnnotationSelect: ((e: Event) => void) | null = null
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
          publishLspDiagnosticSnapshot(filePath, diags)
          const normalizedFilePath = normalizeIdeContextFilePath(filePath)
          const normalizedCurrentFilePath = normalizeIdeContextFilePath(this.filePath)
          if (normalizedFilePath !== null && normalizedFilePath === normalizedCurrentFilePath) {
            this.dispatch(setDiagnostics.of(diags))
          }
        },
        (err) => console.error('[LSP] connection error:', err),
        () => {
          const currentFilePath = this.filePath
          if (currentFilePath !== '') {
            this.conn.notifyDidOpen(
              currentFilePath,
              languageIdFromPath(currentFilePath) ?? DEFAULT_LANGUAGE_ID,
            )
          }
          this.scheduleRefresh()
        },
      )
      this.conn.connect()
      this.onAnnotationSelect = (e: Event) => {
        const detail = (e as CustomEvent).detail as SelectedAnnotation
        this.dispatch(setSelectedAnnotation.of(detail))
      }
      this.view.dom.addEventListener('masc-annotation-select', this.onAnnotationSelect)
      this.boundHoverMove = (e) => this.onHoverMove(e)
      this.boundHoverLeave = () => this.onHoverLeave()
      this.view.dom.addEventListener('mousemove', this.boundHoverMove)
      this.view.dom.addEventListener('mouseleave', this.boundHoverLeave)
      this.scheduleRefresh()
    }

    update(update: ViewUpdate) {
      if (update.docChanged) this.hideTooltip()
      const newFilePath = update.state.field(lspConfigField).filePath
      if (newFilePath !== this.filePath) {
        const oldFilePath = this.filePath
        this.conn.notifyDidClose(oldFilePath)
        clearLspDiagnosticSnapshot(oldFilePath)
        this.filePath = newFilePath
        this.conn.notifyDidOpen(newFilePath, languageIdFromPath(newFilePath) ?? DEFAULT_LANGUAGE_ID)
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
      if (!view.dom.isConnected) return

      const [lenses, hints, diags] = await Promise.allSettled([
        this.conn.requestCodeLenses(fp),
        this.conn.requestInlayHints(fp, view.state.doc.lines),
        this.conn.requestDiagnostics(fp),
      ])

      if (!view.dom.isConnected) return
      if (fp !== this.filePath) return
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
      if (this.onAnnotationSelect) {
        this.view.dom.removeEventListener('masc-annotation-select', this.onAnnotationSelect)
      }
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
    selectedAnnotationField,
    codeLensGutter,
    diagnosticGutter,
    inlayHintTheme,
    inlayHintDecorator,
    hoverTooltipTheme,
    lspViewPlugin,
  ]
}

export function updateLspFilePath(view: EditorView, filePath: string): void {
  view.dispatch({ effects: [setLspConfig.of({ filePath })] })
}

export function getSelectedAnnotation(view: EditorView): SelectedAnnotation | null {
  return view.state.field(selectedAnnotationField)
}

export function clearSelectedAnnotation(view: EditorView): void {
  view.dispatch({ effects: [setSelectedAnnotation.of(null)] })
}
