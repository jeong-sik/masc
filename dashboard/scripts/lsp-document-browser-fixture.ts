// Browser-only acceptance entry. Vite serves this module for the standalone
// protocol probe; it is not part of the product entry graph.
import { EditorState } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import { lspExtension } from '../src/components/ide/ide-lsp-client'
import { lspDocumentStatus, lspDocumentStatusLabel, lspDocumentStatusDetail } from '../src/components/ide/ide-lsp-document-status'

const parent = document.querySelector<HTMLElement>('#editor')!
const status = document.querySelector<HTMLElement>('#status')!
const view = new EditorView({ parent, state: EditorState.create({
  doc: 'let value =\n',
  extensions: [EditorState.readOnly.of(true), lspExtension({ filePath: 'sample.ml' })],
}) })
lspDocumentStatus.subscribe(value => {
  status.textContent = value ? lspDocumentStatusLabel(value) : 'LSP not attempted'
  status.title = value ? lspDocumentStatusDetail(value) : ''
})
Object.assign(window, { lspProbe: {
  snapshot: () => lspDocumentStatus.peek(),
  // This is how the read-only product editor receives a Keeper/store update.
  update: (content: string) => view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: content } }),
  dispose: () => view.destroy(),
} })
