import * as Y from 'yjs'

// The published revision remains immutable. A shared source draft has exactly
// one text type; authenticated actors, comments and live presence belong to the
// server envelope, never to client-controlled CRDT fields.
const contentKey = 'content'
export type SharedSelection = { anchor: number[]; head: number[] }
export type SourceSelection = { anchor: number; head: number }
// One synchronous operation owns its document. Validated observations never
// escape it; callers that retain a mutable Y.Doc use the independent exports.
export type SharedDocumentOperation =
  | { readonly kind: 'seed'; readonly content: string }
  | { readonly kind: 'merge'; readonly state: Uint8Array; readonly updates: readonly Uint8Array[] }
  | { readonly kind: 'select'; readonly state: Uint8Array; readonly anchor: number; readonly head: number }
  | { readonly kind: 'resolve'; readonly state: Uint8Array; readonly selection: SharedSelection }
  | { readonly kind: 'edit'; readonly state: Uint8Array; readonly selection: SharedSelection; readonly expected: string; readonly replacement: string }
export type SharedDocumentResult = {
  state: Uint8Array; content: string; selection: SharedSelection | null; range: SourceSelection | null;
}
export class SharedDocumentError extends Error {
  constructor(readonly code: 'invalid_document' | 'invalid_selection' | 'changed_selection', message: string) {
    super(message)
  }
}

function requireUnicode(content: string): void {
  if (new TextDecoder('utf-8', { ignoreBOM: true }).decode(new TextEncoder().encode(content)) !== content) {
    throw new SharedDocumentError('invalid_document', '원고에 올바르지 않은 유니코드 문자가 있습니다.')
  }
}

type ValidatedDocument = Readonly<{ doc: Y.Doc; text: Y.Text; content: string; state: Uint8Array }>

function inspectDocument(doc: Y.Doc): ValidatedDocument {
  const text = doc.getText(contentKey)
  // A Y.Map view can write attributes onto the same root without adding a
  // shared type or changing its text delta. Use its public map size: the plain
  // object returned by getAttributes() loses keys such as a string __proto__.
  const state = Y.encodeStateAsUpdate(doc)
  const mapView = new Y.Doc()
  let hasMetadata: boolean
  try {
    Y.applyUpdate(mapView, state)
    hasMetadata = mapView.getMap(contentKey).size !== 0
  } finally { mapView.destroy() }
  if (doc.share.size !== 1 || hasMetadata
    || text.toDelta().some((part: { insert?: unknown; attributes?: unknown }) => typeof part.insert !== 'string' || part.attributes !== undefined)) {
    throw new SharedDocumentError('invalid_document', '공동 편집 원고에는 본문 텍스트만 저장할 수 있습니다.')
  }
  const content = text.toString()
  requireUnicode(content)
  return { doc, text, content, state }
}

export function seedSharedDocument(content: string): Y.Doc {
  requireUnicode(content)
  const doc = new Y.Doc()
  doc.getText(contentKey).insert(0, content)
  return doc
}

function restoreValidatedDocument(state: Uint8Array): ValidatedDocument {
  const doc = new Y.Doc()
  try {
    Y.applyUpdate(doc, state)
    return inspectDocument(doc)
  } catch (error) {
    doc.destroy()
    throw error
  }
}

export function restoreSharedDocument(state: Uint8Array): Y.Doc { return restoreValidatedDocument(state).doc }
export function sharedSource(doc: Y.Doc): string { return inspectDocument(doc).content }
export function sharedState(doc: Y.Doc): Uint8Array { inspectDocument(doc); return Y.encodeStateAsUpdate(doc) }

function validIndex(content: string, index: number): boolean {
  if (!Number.isSafeInteger(index) || index < 0 || index > content.length) return false
  const before = content.charCodeAt(index - 1), after = content.charCodeAt(index)
  return !(before >= 0xD800 && before <= 0xDBFF && after >= 0xDC00 && after <= 0xDFFF)
}

function selectValidated({ text, content }: ValidatedDocument, { anchor, head }: SourceSelection): SharedSelection {
  if (!validIndex(content, anchor) || !validIndex(content, head)) {
    throw new SharedDocumentError('invalid_selection', '선택 영역이 원고 범위를 벗어나거나 문자를 나눕니다.')
  }
  const end = Math.max(anchor, head)
  const position = (index: number) => Array.from(Y.encodeRelativePosition(
    Y.createRelativePositionFromTypeIndex(text, index, anchor !== head && index === end ? -1 : 0),
  ))
  return { anchor: position(anchor), head: position(head) }
}

export function selectSharedSource(doc: Y.Doc, selection: SourceSelection): SharedSelection {
  return selectValidated(inspectDocument(doc), selection)
}

function resolveValidated({ doc, text, content }: ValidatedDocument, selection: SharedSelection): SourceSelection | null {
  const resolve = (bytes: number[]) => {
    if (!Array.isArray(bytes) || !bytes.every(value => Number.isInteger(value) && value >= 0 && value <= 255)) return null
    const point = Y.createAbsolutePositionFromRelativePosition(Y.decodeRelativePosition(Uint8Array.from(bytes)), doc)
    return point?.type === text && validIndex(content, point.index) ? point.index : null
  }
  try {
    const anchor = resolve(selection.anchor), head = resolve(selection.head)
    return anchor === null || head === null ? null : { anchor, head }
  } catch { return null }
}

export function resolveSharedSelection(doc: Y.Doc, selection: SharedSelection): SourceSelection | null {
  return resolveValidated(inspectDocument(doc), selection)
}

function replaceValidated({ doc, text, content }: ValidatedDocument, range: SourceSelection, expected: string, replacement: string): SourceSelection {
  const start = Math.min(range.anchor, range.head), end = Math.max(range.anchor, range.head)
  if (content.slice(start, end) !== expected) {
    throw new SharedDocumentError('changed_selection', '선택한 내용이 바뀌었습니다. 현재 내용을 읽고 다시 편집해 주세요.')
  }
  doc.transact(() => {
    text.delete(start, end - start)
    text.insert(start, replacement)
  })
  return { anchor: start, head: start + replacement.length }
}

// Keeper edits use anchors obtained by reading this draft. Changes elsewhere
// move those anchors; changes inside the selected text require a fresh read.
export function replaceSharedSelection(doc: Y.Doc, selection: SharedSelection, expected: string, replacement: string): SharedSelection {
  requireUnicode(replacement)
  const range = resolveSharedSelection(doc, selection)
  if (range === null) throw new SharedDocumentError('invalid_selection', '선택 영역을 현재 원고에서 찾지 못했습니다.')
  const next = replaceValidated(inspectDocument(doc), range, expected, replacement)
  return selectSharedSource(doc, next)
}

export function executeSharedDocumentOperation(operation: SharedDocumentOperation): SharedDocumentResult {
  let view: ValidatedDocument
  if (operation.kind === 'seed') {
    const doc = seedSharedDocument(operation.content)
    try { view = inspectDocument(doc) }
    catch (error) { doc.destroy(); throw error }
  } else view = restoreValidatedDocument(operation.state)
  const doc = view.doc
  try {
    let selection: SharedSelection | null = null
    if (operation.kind === 'merge') {
      for (const update of operation.updates) Y.applyUpdate(doc, update)
      if (operation.updates.length !== 0) view = inspectDocument(doc)
    } else if (operation.kind === 'select') {
      selection = selectValidated(view, operation)
    } else if (operation.kind === 'resolve') {
      selection = operation.selection
    } else if (operation.kind === 'edit') {
      requireUnicode(operation.replacement)
      const range = resolveValidated(view, operation.selection)
      if (range === null) throw new SharedDocumentError('invalid_selection', '선택 영역을 현재 원고에서 찾지 못했습니다.')
      const next = replaceValidated(view, range, operation.expected, operation.replacement)
      // A mutation invalidates every observation, including the encoded state.
      view = inspectDocument(doc)
      selection = selectValidated(view, next)
    }
    const range = selection === null ? null : resolveValidated(view, selection)
    if (selection !== null && range === null) {
      throw new SharedDocumentError('invalid_selection', '선택 영역을 현재 원고에서 찾지 못했습니다.')
    }
    return { state: view.state, content: view.content, selection, range }
  } finally { doc.destroy() }
}
