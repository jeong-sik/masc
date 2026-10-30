import * as Y from 'yjs'

// The published revision remains immutable. A shared source draft has exactly
// one text type; authenticated actors, comments and live presence belong to the
// server envelope, never to client-controlled CRDT fields.
const contentKey = 'content'
export type SharedSelection = { anchor: number[]; head: number[] }
export type SourceSelection = { anchor: number; head: number }
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

function textOf(doc: Y.Doc): Y.Text {
  const text = doc.getText(contentKey)
  // A Y.Map view can write attributes onto the same root without adding a
  // shared type or changing its text delta. Use its public map size: the plain
  // object returned by getAttributes() loses keys such as a string __proto__.
  const mapView = new Y.Doc()
  let hasMetadata: boolean
  try {
    Y.applyUpdate(mapView, Y.encodeStateAsUpdate(doc))
    hasMetadata = mapView.getMap(contentKey).size !== 0
  } finally { mapView.destroy() }
  if (doc.share.size !== 1 || hasMetadata
    || text.toDelta().some((part: { insert?: unknown; attributes?: unknown }) => typeof part.insert !== 'string' || part.attributes !== undefined)) {
    throw new SharedDocumentError('invalid_document', '공동 편집 원고에는 본문 텍스트만 저장할 수 있습니다.')
  }
  requireUnicode(text.toString())
  return text
}

export function seedSharedDocument(content: string): Y.Doc {
  requireUnicode(content)
  const doc = new Y.Doc()
  doc.getText(contentKey).insert(0, content)
  return doc
}

export function restoreSharedDocument(state: Uint8Array): Y.Doc {
  const doc = new Y.Doc()
  try {
    Y.applyUpdate(doc, state)
    textOf(doc)
    return doc
  } catch (error) {
    doc.destroy()
    throw error
  }
}

export function sharedSource(doc: Y.Doc): string { return textOf(doc).toString() }
export function sharedState(doc: Y.Doc): Uint8Array { textOf(doc); return Y.encodeStateAsUpdate(doc) }

export function mergeSharedUpdates(state: Uint8Array, updates: readonly Uint8Array[]): { state: Uint8Array; content: string } {
  const doc = restoreSharedDocument(state)
  try {
    for (const update of updates) Y.applyUpdate(doc, update)
    return { state: sharedState(doc), content: sharedSource(doc) }
  } finally { doc.destroy() }
}

function validIndex(content: string, index: number): boolean {
  if (!Number.isSafeInteger(index) || index < 0 || index > content.length) return false
  const before = content.charCodeAt(index - 1), after = content.charCodeAt(index)
  return !(before >= 0xD800 && before <= 0xDBFF && after >= 0xDC00 && after <= 0xDFFF)
}

export function selectSharedSource(doc: Y.Doc, { anchor, head }: SourceSelection): SharedSelection {
  const text = textOf(doc), content = text.toString()
  if (!validIndex(content, anchor) || !validIndex(content, head)) {
    throw new SharedDocumentError('invalid_selection', '선택 영역이 원고 범위를 벗어나거나 문자를 나눕니다.')
  }
  const end = Math.max(anchor, head)
  const position = (index: number) => Array.from(Y.encodeRelativePosition(
    Y.createRelativePositionFromTypeIndex(text, index, anchor !== head && index === end ? -1 : 0),
  ))
  return { anchor: position(anchor), head: position(head) }
}

export function resolveSharedSelection(doc: Y.Doc, selection: SharedSelection): SourceSelection | null {
  const text = textOf(doc)
  const resolve = (bytes: number[]) => {
    if (!Array.isArray(bytes) || !bytes.every(value => Number.isInteger(value) && value >= 0 && value <= 255)) return null
    const point = Y.createAbsolutePositionFromRelativePosition(Y.decodeRelativePosition(Uint8Array.from(bytes)), doc)
    return point?.type === text && validIndex(text.toString(), point.index) ? point.index : null
  }
  try {
    const anchor = resolve(selection.anchor), head = resolve(selection.head)
    return anchor === null || head === null ? null : { anchor, head }
  } catch { return null }
}

// Keeper edits use anchors obtained by reading this draft. Changes elsewhere
// move those anchors; changes inside the selected text require a fresh read.
export function replaceSharedSelection(doc: Y.Doc, selection: SharedSelection, expected: string, replacement: string): SharedSelection {
  requireUnicode(replacement)
  const range = resolveSharedSelection(doc, selection)
  if (range === null) throw new SharedDocumentError('invalid_selection', '선택 영역을 현재 원고에서 찾지 못했습니다.')
  const start = Math.min(range.anchor, range.head), end = Math.max(range.anchor, range.head)
  const text = textOf(doc)
  if (text.toString().slice(start, end) !== expected) {
    throw new SharedDocumentError('changed_selection', '선택한 내용이 바뀌었습니다. 현재 내용을 읽고 다시 편집해 주세요.')
  }
  doc.transact(() => {
    text.delete(start, end - start)
    text.insert(start, replacement)
  })
  return selectSharedSource(doc, { anchor: start, head: start + replacement.length })
}
