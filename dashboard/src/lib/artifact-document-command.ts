import { Schema } from 'effect'
import { Buffer } from 'node:buffer'
import { mergeSharedUpdates, replaceSharedSelection, resolveSharedSelection, restoreSharedDocument,
  seedSharedDocument, selectSharedSource, sharedSource, sharedState, SharedDocumentError } from './artifact-shared-document'

const Base64 = Schema.String.pipe(Schema.pattern(/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/))
const Byte = Schema.Int.pipe(Schema.between(0, 255))
const Selection = Schema.Struct({ anchor: Schema.Array(Byte), head: Schema.Array(Byte) })
const Index = Schema.Int.pipe(Schema.between(0, Number.MAX_SAFE_INTEGER))
const Request = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('seed'), content: Schema.String }),
  Schema.Struct({ kind: Schema.Literal('merge'), state: Base64, updates: Schema.Array(Base64) }),
  Schema.Struct({ kind: Schema.Literal('select'), state: Base64, anchor: Index, head: Index }),
  Schema.Struct({ kind: Schema.Literal('resolve'), state: Base64, selection: Selection }),
  Schema.Struct({ kind: Schema.Literal('edit'), state: Base64, selection: Selection, expected: Schema.String, replacement: Schema.String }),
)
const bytes = (text: string) => {
  const value = Buffer.from(text, 'base64')
  if (value.toString('base64') !== text) throw new Error('noncanonical base64')
  return value
}
const encoded = (value: Uint8Array) => Buffer.from(value).toString('base64')
const mutableSelection = (value: typeof Selection.Type) => ({ anchor: [...value.anchor], head: [...value.head] })

// The command protocol accepts no document paths, network addresses, credentials
// or actor claims. The OCaml caller owns authentication, workspace isolation,
// locking and durable commit. A failed transform returns no replacement state.
export function runArtifactDocumentCommand(input: unknown) {
  let request: typeof Request.Type
  try { request = Schema.decodeUnknownSync(Request, { onExcessProperty: 'error' })(input) }
  catch { return { ok: false as const, code: 'invalid_request', message: 'invalid artifact document command' } }
  try {
    if (request.kind === 'merge') {
      const merged = mergeSharedUpdates(bytes(request.state), request.updates.map(bytes))
      return { ok: true as const, state: encoded(merged.state), content: merged.content }
    }
    const doc = request.kind === 'seed' ? seedSharedDocument(request.content) : restoreSharedDocument(bytes(request.state))
    try {
      const selection = request.kind === 'select'
        ? selectSharedSource(doc, request)
        : request.kind === 'edit'
          ? replaceSharedSelection(doc, mutableSelection(request.selection), request.expected, request.replacement)
          : request.kind === 'resolve' ? mutableSelection(request.selection) : null
      const range = selection === null ? null : resolveSharedSelection(doc, selection)
      if (selection !== null && range === null) {
        throw new SharedDocumentError('invalid_selection', '선택 영역을 현재 원고에서 찾지 못했습니다.')
      }
      return { ok: true as const, state: encoded(sharedState(doc)), content: sharedSource(doc), selection, range }
    } finally { doc.destroy() }
  } catch (error) {
    return { ok: false as const, code: error instanceof SharedDocumentError ? error.code : 'invalid_document',
      message: error instanceof SharedDocumentError ? error.message : 'invalid shared document state or update' }
  }
}
