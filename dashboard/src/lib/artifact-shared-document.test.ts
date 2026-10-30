import * as Y from 'yjs'
import { afterEach, expect, it } from 'vitest'
import { mergeSharedUpdates, replaceSharedSelection, resolveSharedSelection, restoreSharedDocument,
  seedSharedDocument, selectSharedSource, sharedSource, sharedState } from './artifact-shared-document'

const docs: Y.Doc[] = []
const keep = (doc: Y.Doc) => { docs.push(doc); return doc }
const seed = (text: string) => keep(seedSharedDocument(text))
const copy = (doc: Y.Doc) => keep(restoreSharedDocument(sharedState(doc)))
afterEach(() => { for (const doc of docs.splice(0)) doc.destroy() })

it('converges concurrent human and Keeper edits in either delivery order and after duplicate delivery', () => {
  const source = seed('한글 😀\r\n공동 편집\r\n'), human = copy(source), keeper = copy(source)
  const state = sharedState(source)
  replaceSharedSelection(human, selectSharedSource(human, { anchor: 0, head: 2 }), '한글', '한국어')
  const start = sharedSource(keeper).indexOf('공동')
  replaceSharedSelection(keeper, selectSharedSource(keeper, { anchor: start, head: start + 2 }), '공동', '실시간 공동')
  const a = Y.encodeStateAsUpdate(human, Y.encodeStateVector(source))
  const b = Y.encodeStateAsUpdate(keeper, Y.encodeStateVector(source))
  const first = mergeSharedUpdates(state, [a, b, a]), second = mergeSharedUpdates(state, [b, a, b])
  expect(first.content).toBe('한국어 😀\r\n실시간 공동 편집\r\n')
  expect(second.content).toBe(first.content)
  expect(sharedSource(keep(restoreSharedDocument(first.state)))).toBe(first.content)
})

it('keeps a Keeper selection attached to the same text after another writer inserts before it', () => {
  const doc = seed('첫 줄\n편집할 문장\n마지막 줄')
  const anchor = selectSharedSource(doc, { anchor: 4, head: 10 })
  const remote = copy(doc)
  replaceSharedSelection(remote, selectSharedSource(remote, { anchor: 0, head: 0 }), '', '새 줄\n')
  Y.applyUpdate(doc, sharedState(remote))
  expect(resolveSharedSelection(doc, anchor)).toEqual({ anchor: 8, head: 14 })
  replaceSharedSelection(doc, anchor, '편집할 문장', '함께 편집한 문장')
  expect(sharedSource(doc)).toBe('새 줄\n첫 줄\n함께 편집한 문장\n마지막 줄')
})

it('refuses a stale Keeper replacement when a human changed the selected text', () => {
  const doc = seed('사용자가 작성한 원고')
  const selection = selectSharedSource(doc, { anchor: 0, head: 3 })
  replaceSharedSelection(doc, selectSharedSource(doc, { anchor: 1, head: 1 }), '', '먼저')
  const before = sharedState(doc)
  expect(() => replaceSharedSelection(doc, selection, '사용자', 'Keeper')).toThrow('선택한 내용이 바뀌었습니다')
  expect(sharedState(doc)).toEqual(before)
  expect(sharedSource(doc)).toBe('사먼저용자가 작성한 원고')
})

it('keeps the selection direction and excludes concurrent insertions at its boundaries', () => {
  const doc = seed('앞본문뒤'), selection = selectSharedSource(doc, { anchor: 3, head: 1 })
  replaceSharedSelection(doc, selectSharedSource(doc, { anchor: 3, head: 3 }), '', '추가')
  expect(resolveSharedSelection(doc, selection)).toEqual({ anchor: 3, head: 1 })
  replaceSharedSelection(doc, selection, '본문', '수정')
  expect(sharedSource(doc)).toBe('앞수정추가뒤')
})

it('rejects invalid ranges and interior item positions whose IDs do not exist in the document', () => {
  const doc = seed('가😀나'), other = seed('다른 문서')
  for (const point of [-1, 2, 5, 0.5, NaN]) {
    expect(() => selectSharedSource(doc, { anchor: point, head: point })).toThrow()
  }
  expect(resolveSharedSelection(other, selectSharedSource(doc, { anchor: 1, head: 3 }))).toBeNull()
  expect(resolveSharedSelection(doc, { anchor: [256], head: [] })).toBeNull()
})

it('leaves document and generation identity to the caller envelope for root-anchored boundary positions', () => {
  const doc = seed('원고'), other = seed('다른 원고')
  const end = selectSharedSource(doc, { anchor: 2, head: 2 })
  // Yjs end positions identify the root, not a unique document. Callers must
  // bind selections to a document and generation before resolving them.
  expect(resolveSharedSelection(other, end)).toEqual({ anchor: 5, head: 5 })
})

it('refuses arbitrary client-controlled metadata or rich-text objects in a source document', () => {
  const source = seed('정상 원고'), malicious = copy(source)
  malicious.getMap('actor').set('name', 'trusted-keeper')
  expect(() => mergeSharedUpdates(sharedState(source), [Y.encodeStateAsUpdate(malicious)])).toThrow('본문 텍스트만')
  expect(sharedSource(source)).toBe('정상 원고')
  const rich = seed('원고')
  rich.getText('content').format(0, 1, { bold: true })
  expect(() => sharedState(rich)).toThrow('본문 텍스트만')
})

it.each(['actor', 'arbitrary metadata key', '__proto__'])('refuses same-root map metadata named %s from a genuine alternative view', key => {
  const source = seed('safe text'), state = sharedState(source)
  const remote = keep(new Y.Doc())
  Y.applyUpdate(remote, state)
  remote.getMap('content').set(key, 'trusted-keeper')
  const update = Y.encodeStateAsUpdate(remote)
  const observed = keep(new Y.Doc())
  Y.applyUpdate(observed, update)
  expect(observed.getMap('content').get(key)).toBe('trusted-keeper')
  expect(() => mergeSharedUpdates(state, [update])).toThrow('본문 텍스트만')
  expect(() => restoreSharedDocument(update)).toThrow('본문 텍스트만')
  expect(sharedSource(source)).toBe('safe text')
})

it('preserves a dependent update across persisted restore when it arrives before its predecessor', () => {
  const source = seed('source'), remote = copy(source), state = sharedState(source)
  const before = Y.encodeStateVector(remote)
  remote.getText('content').insert(0, 'first ')
  const first = Y.encodeStateAsUpdate(remote, before), between = Y.encodeStateVector(remote)
  remote.getText('content').insert(0, 'second ')
  const second = Y.encodeStateAsUpdate(remote, between)
  const pending = mergeSharedUpdates(state, [second])
  expect(pending.content).toBe('source')
  const restored = copy(keep(restoreSharedDocument(pending.state)))
  const merged = mergeSharedUpdates(sharedState(restored), [first])
  expect(merged.content).toBe('second first source')
  expect(sharedSource(keep(restoreSharedDocument(merged.state)))).toBe(sharedSource(remote))
})
