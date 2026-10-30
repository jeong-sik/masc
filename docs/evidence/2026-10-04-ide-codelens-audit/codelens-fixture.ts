import { EditorState } from '@codemirror/state'
import { EditorView, lineNumbers } from '@codemirror/view'
import { lspExtension } from '../src/components/ide/ide-lsp-client'
import { readOnlyExt } from '../src/components/ide/ide-editor-extensions'

const lenses = [
  { range: { start: { line: 0, character: 0 }, end: { line: 0, character: 13 } },
    command: { title: 'Run tests', command: 'fixture.runTests', arguments: ['example.ml'] } },
  { range: { start: { line: 1, character: 0 }, end: { line: 1, character: 22 } },
    command: { title: '2 references', command: 'fixture.references' } },
]
const messages: string[] = []
class FixtureSocket {
  static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3
  readyState = 0
  onopen: (() => void) | null = null
  onmessage: ((event: { data: string }) => void) | null = null
  onclose: (() => void) | null = null
  constructor(_url: string) { queueMicrotask(() => { this.readyState = 1; this.onopen?.() }) }
  receive(value: unknown) { queueMicrotask(() => this.onmessage?.({ data: JSON.stringify(value) })) }
  close() { this.readyState = 3 }
  send(raw: string) {
    const message = JSON.parse(raw); messages.push(message.method)
    if (message.method === 'initialize') this.receive({ id: message.id, result: { masc: { workspaceRoot: '/workspace/masc' } } })
    else if (message.method === 'initialized') this.receive({ method: 'masc/lspStatus', params: {
      langs: [{ lang: 'ocaml', connected: true, command: 'synthetic-fixture', last_error: null }],
    } })
    else if (message.id) this.receive({ id: message.id, result: message.method === 'textDocument/codeLens' ? lenses
      : message.method === 'textDocument/diagnostic' ? { kind: 'full', items: [] } : [] })
  }
}
Object.assign(window, { WebSocket: FixtureSocket })
const view = new EditorView({ parent: document.querySelector('#editor')!, state: EditorState.create({
  doc: 'let value = 1\nlet answer = value + 1',
  extensions: [lineNumbers(), readOnlyExt(), lspExtension({ filePath: 'example.ml' }), EditorView.theme({
    '&': { backgroundColor: '#172130', color: '#e3eaf5' }, '.cm-content': { padding: '24px 0' },
    '.cm-gutters': { backgroundColor: '#172130', color: '#8294ae' },
  })],
}) })
Object.assign(window, { codeLensSnapshot: () => ({
  messages, document: view.state.doc.toString(), labels: [...view.dom.querySelectorAll<HTMLElement>('.cm-codelens-marker')].map(label => ({
    text: label.textContent, tooltip: label.title, cursor: getComputedStyle(label).cursor,
    tabIndex: label.tabIndex, interactive: label.matches('a, button, [role="button"], [role="link"]'),
  })),
}) })
