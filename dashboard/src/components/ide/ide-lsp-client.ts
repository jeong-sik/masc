/**
 * IDE LSP Client — CodeMirror extension for Language Server Protocol
 * with MASC observational overlay integration
 */

import { EditorView, ViewPlugin, gutter, GutterMarker } from '@codemirror/view'
import { StateField, StateEffect } from '@codemirror/state'
import type { Extension } from '@codemirror/state'

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

export interface LspState {
  connected: boolean
  codeLenses: Map<number, LspCodeLens[]>
  inlayHints: Map<number, LspInlayHint[]>
  diagnostics: Map<number, LspDiagnostic[]>
  ws: WebSocket | null
}

const initialState: LspState = {
  connected: false,
  codeLenses: new Map(),
  inlayHints: new Map(),
  diagnostics: new Map(),
  ws: null,
}

// ── State Effects ────────────────────────────────────────────────

const setConnected = StateEffect.define<boolean>()
const setCodeLenses = StateEffect.define<Map<number, LspCodeLens[]>>()
const setInlayHints = StateEffect.define<Map<number, LspInlayHint[]>>()
const setDiagnostics = StateEffect.define<Map<number, LspDiagnostic[]>>()

// ── State Field ──────────────────────────────────────────────────

const lspStateField = StateField.define<LspState>({
  create() {
    return initialState
  },
  update(state, transaction) {
    for (const effect of transaction.effects) {
      if (effect.is(setConnected)) {
        state = { ...state, connected: effect.value }
      } else if (effect.is(setCodeLenses)) {
        state = { ...state, codeLenses: effect.value }
      } else if (effect.is(setInlayHints)) {
        state = { ...state, inlayHints: effect.value }
      } else if (effect.is(setDiagnostics)) {
        state = { ...state, diagnostics: effect.value }
      }
    }
    return state
  },
})

// ── CodeLens Gutter ──────────────────────────────────────────────

class CodeLensMarker extends GutterMarker {
  constructor(
    private lens: LspCodeLens,
    private onClick: (lens: LspCodeLens) => void,
  ) {
    super()
  }

  toDOM(view: EditorView) {
    const el = document.createElement('div')
    el.className = 'cm-codelens-marker'
    el.textContent = this.lens.command?.title ?? ''
    el.style.cssText = `
      display: inline-flex;
      align-items: center;
      gap: 4px;
      padding: 2px 6px;
      margin: 2px 0;
      font-size: 11px;
      color: var(--color-fg-muted);
      background: var(--color-bg-muted);
      border-radius: 4px;
      cursor: pointer;
      user-select: none;
    `
    el.addEventListener('click', (e) => {
      e.preventDefault()
      e.stopPropagation()
      this.onClick(this.lens)
    })
    return el
  }
}

const codeLensGutter = gutter({
  class: 'cm-codelens-gutter',
  lineMarker: (view: EditorView, line) => {
    const state = view.state.field(lspStateField)
    const lenses = state.codeLenses.get(line.from) || []
    if (lenses.length === 0) return null
    
    const container = document.createElement('div')
    container.style.cssText = 'display: flex; flex-direction: column; gap: 2px;'
    
    for (const lens of lenses) {
      const marker = new CodeLensMarker(lens, (l) => {
        if (l.command?.command === 'masc-ide.showAnnotation') {
          console.log('Show annotation:', l.command.arguments)
        }
      })
      container.appendChild(marker.toDOM(view))
    }
    
    return container
  },
  initialSpacer: () => new GutterMarker(),
})

// ── Inlay Hints ──────────────────────────────────────────────────

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

// ── Diagnostic Marks ─────────────────────────────────────────────

class DiagnosticMark extends GutterMarker {
  constructor(private diagnostic: LspDiagnostic) {
    super()
  }

  toDOM(view: EditorView) {
    const el = document.createElement('div')
    el.className = 'cm-diagnostic-marker'
    el.title = this.diagnostic.message
    
    const severity = this.diagnostic.severity ?? 1
    const color = severity === 1 ? '#f00' : severity === 2 ? '#fa0' : '#00f'
    
    el.style.cssText = `
      width: 12px;
      height: 12px;
      border-radius: 50%;
      background: ${color};
      cursor: help;
    `
    
    return el
  }
}

const diagnosticGutter = gutter({
  class: 'cm-diagnostic-gutter',
  lineMarker: (view: EditorView, line) => {
    const state = view.state.field(lspStateField)
    const diagnostics = state.diagnostics.get(line.from) || []
    if (diagnostics.length === 0) return null
    
    const mostSevere = diagnostics.reduce((worst, d) => {
      const s = d.severity ?? 3
      const w = worst.severity ?? 3
      return s < w ? d : worst
    })
    
    return new DiagnosticMark(mostSevere)
  },
  initialSpacer: () => new GutterMarker(),
})

// ── WebSocket Connection ─────────────────────────────────────────

function connectLsp(
  baseUrl: string,
  dispatch: (effects: unknown | unknown[]) => void,
): WebSocket {
  const wsUrl = baseUrl.replace(/^http/, 'ws') + '/api/v1/ide/lsp'
  const ws = new WebSocket(wsUrl)
  
  ws.onopen = () => {
    console.log('LSP WebSocket connected')
    dispatch(setConnected.of(true))
    
    const initRequest = {
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        processId: null,
        clientInfo: { name: 'masc-ide', version: '1.0.0' },
        locale: 'ko',
        rootUri: window.location.origin,
        capabilities: {
          textDocument: {
            codeLens: {},
            inlayHint: {},
            diagnostic: {},
          },
        },
      },
    }
    ws.send(JSON.stringify(initRequest))
  }
  
  ws.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data)
      
      if (msg.method === 'textDocument/codeLens') {
        const lensesByLine = new Map<number, LspCodeLens[]>()
        const result = msg.result || msg.params?.result || []
        
        for (const lens of result) {
          const line = lens.range?.start?.line ?? 0
          const existing = lensesByLine.get(line) || []
          existing.push(lens)
          lensesByLine.set(line, existing)
        }
        
        dispatch(setCodeLenses.of(lensesByLine))
      }
      
      if (msg.method === 'textDocument/inlayHint') {
        const hintsByLine = new Map<number, LspInlayHint[]>()
        const result = msg.result || msg.params?.result || []
        
        for (const hint of result) {
          const line = hint.position?.line ?? 0
          const existing = hintsByLine.get(line) || []
          existing.push(hint)
          hintsByLine.set(line, existing)
        }
        
        dispatch(setInlayHints.of(hintsByLine))
      }
      
      if (msg.method === 'textDocument/publishDiagnostics') {
        const diagByLine = new Map<number, LspDiagnostic[]>()
        const diagnostics = msg.params?.diagnostics || []
        
        for (const diag of diagnostics) {
          const line = diag.range?.start?.line ?? 0
          const existing = diagByLine.get(line) || []
          existing.push(diag)
          diagByLine.set(line, existing)
        }
        
        dispatch(setDiagnostics.of(diagByLine))
      }
    } catch (err) {
      console.error('LSP message parse error:', err)
    }
  }
  
  ws.onclose = () => {
    console.log('LSP WebSocket disconnected')
    dispatch(setConnected.of(false))
    
    setTimeout(() => {
      if (ws.readyState === WebSocket.CLOSED) {
        connectLsp(baseUrl, dispatch)
      }
    }, 3000)
  }
  
  ws.onerror = (err) => {
    console.error('LSP WebSocket error:', err)
  }
  
  return ws
}

// ── View Plugin ──────────────────────────────────────────────────

const lspViewPlugin = ViewPlugin.fromClass(
  class {
    ws: WebSocket | null = null
    
    constructor(view: EditorView) {
      const baseUrl = getBaseUrl()
      this.ws = connectLsp(baseUrl, (effects) => {
        view.dispatch({ effects })
      })
    }
    
    destroy() {
      if (this.ws) {
        this.ws.close()
        this.ws = null
      }
    }
  },
)

function getBaseUrl(): string {
  if (typeof window !== 'undefined') {
    return window.location.origin
  }
  return 'http://localhost:8930'
}

// ── Public API ───────────────────────────────────────────────────

export function lspExtension(): Extension {
  return [
    lspStateField,
    codeLensGutter,
    diagnosticGutter,
    inlayHintTheme,
    lspViewPlugin,
  ]
}

export function getLspState(view: EditorView): LspState {
  return view.state.field(lspStateField)
}
