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

class LspConnection {
  private ws: WebSocket | null = null
  private nextId = 1
  private pending = new Map<number, PendingRequest>()
  private disposed = false
  private initialized = false

  constructor(
    private readonly onDiagnostics: (diags: ReadonlyMap<number, LspDiagnostic[]>) => void,
    private readonly onError: (err: unknown) => void,
  ) {}

  connect(): void {
    if (this.disposed) return
    const origin = typeof window !== 'undefined' ? window.location.origin : 'http://localhost:8935'
    const wsUrl = origin.replace(/^http/, 'ws') + '/api/v1/ide/lsp'
    const ws = new WebSocket(wsUrl)
    this.ws = ws

    ws.onopen = () => {
      if (this.disposed) { ws.close(); return }
      console.log('[LSP] WebSocket connected')
      this.initialize()
    }

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data)
        this.handleMessage(msg)
      } catch (err) {
        console.error('[LSP] message parse error:', err)
      }
    }

    ws.onclose = () => {
      console.log('[LSP] WebSocket closed')
      this.initialized = false
      if (!this.disposed) {
        setTimeout(() => { if (!this.disposed) this.connect() }, 5000)
      }
    }

    ws.onerror = (err) => {
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
      this.onDiagnostics(diagByLine)
    }
  }

  private sendRequest(method: string, params: unknown): Promise<unknown> {
    return new Promise((resolve, reject) => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
        reject(new Error('WebSocket not connected'))
        return
      }
      const id = this.nextId++
      this.pending.set(id, { resolve, reject })
      this.ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }))
    })
  }

  private sendNotification(method: string, params: unknown): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return
    this.ws.send(JSON.stringify({ jsonrpc: '2.0', method, params }))
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
      this.sendNotification('initialized', {})
      this.initialized = true
      console.log('[LSP] initialized')
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
    for (const [, { reject }] of this.pending) {
      reject(new Error('Connection disposed'))
    }
    this.pending.clear()
    if (this.ws) {
      this.ws.close()
      this.ws = null
    }
  }
}

// ── Helpers ───────────────────────────────────────────────────────

function toFileUri(filePath: string): string {
  return `file://${filePath}`
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

    constructor(private readonly view: EditorView) {
      const filePath = view.state.field(lspConfigField).filePath
      this.filePath = filePath
      this.conn = new LspConnection(
        (diags) => this.dispatch(setDiagnostics.of(diags)),
        (err) => console.error('[LSP] connection error:', err),
      )
      this.conn.connect()
      this.onAnnotationSelect = (e: Event) => {
        const detail = (e as CustomEvent).detail as SelectedAnnotation
        this.dispatch(setSelectedAnnotation.of(detail))
      }
      this.view.dom.addEventListener('masc-annotation-select', this.onAnnotationSelect)
      this.scheduleRefresh()
    }

    update(update: ViewUpdate) {
      const newFilePath = update.state.field(lspConfigField).filePath
      if (newFilePath !== this.filePath) {
        this.conn.notifyDidClose(this.filePath)
        this.filePath = newFilePath
        this.conn.notifyDidOpen(newFilePath, languageIdFromPath(newFilePath) ?? 'text')
        this.scheduleRefresh()
      }
    }

    private scheduleRefresh(): void {
      if (this.refreshTimer) clearTimeout(this.refreshTimer)
      this.refreshTimer = setTimeout(() => this.refresh(), 300)
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
      const effects: StateEffect<unknown>[] = []
      if (lenses.status === 'fulfilled') effects.push(setCodeLenses.of(lenses.value))
      if (hints.status === 'fulfilled') effects.push(setInlayHints.of(hints.value))
      if (diags.status === 'fulfilled') effects.push(setDiagnostics.of(diags.value))
      if (effects.length > 0) view.dispatch({ effects })
    }

    destroy() {
      if (this.refreshTimer) clearTimeout(this.refreshTimer)
      if (this.onAnnotationSelect) {
        this.view.dom.removeEventListener('masc-annotation-select', this.onAnnotationSelect)
      }
      this.conn.notifyDidClose(this.filePath)
      this.conn.dispose()
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
