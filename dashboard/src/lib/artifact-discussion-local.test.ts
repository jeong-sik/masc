import { afterEach, expect, it, vi } from 'vitest'
import { discussionLocals, discardDiscussionLocal, retainDiscussionLocal, type DiscussionLocalValue, type DiscussionLocalRecord } from './artifact-discussion-local'
const workspace = { basePath: '/discussion-local-test', mascRoot: '/runtime' }
const target = { artifact_id: `artifact-${'d'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
const input: DiscussionLocalValue = { kind: 'input', input: { kind: 'reply', operationId: target.generation, threadId: target.generation, body: '이전 입력' } }
const key = (record: Pick<DiscussionLocalRecord,'id'|'revision'>) => `masc.artifact-discussion-local.v1:${record.id}:${record.revision}`
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); discussionLocals(workspace, target.artifact_id).forEach(discardDiscussionLocal); localStorage.clear() })
it('preserves newer in-page and other-tab input when an earlier request is acknowledged', () => {
  const old = retainDiscussionLocal('same', workspace, target, 'human', input)
  const newer = retainDiscussionLocal('same', workspace, target, 'human', { ...input, input: { ...input.input, body: '새 입력' } })
  discardDiscussionLocal(old)
  expect(discussionLocals(workspace, target.artifact_id)).toEqual([newer])
  const external = { ...JSON.parse(localStorage.getItem(key(newer))!), revision: crypto.randomUUID(), value: { ...input, input: { ...input.input, body: '다른 탭' } } }
  localStorage.setItem(key(external), JSON.stringify(external))
  discardDiscussionLocal(newer)
  expect(JSON.parse(localStorage.getItem(key(external))!).value.input.body).toBe('다른 탭')
  expect(discussionLocals(workspace, target.artifact_id)[0]?.value).toEqual(external.value)
})
it('retains a durable input if request storage exceeds quota, then clears it only after the matching acknowledgement', () => {
  const saved = retainDiscussionLocal('quota', workspace, target, 'human', input)
  const storage = localStorage
  vi.stubGlobal('localStorage', { get length() { return storage.length }, key: storage.key.bind(storage), getItem: storage.getItem.bind(storage), removeItem: storage.removeItem.bind(storage), setItem() { throw new DOMException('full','QuotaExceededError') } })
  const pending = retainDiscussionLocal('quota', workspace, target, 'human', { kind: 'request', request: { id: input.input.operationId, command: { kind: 'reply', thread_id: target.generation, body: '전송한 입력' } } })
  expect(pending.persisted).toBe(false)
  expect(pending.storedRevision).toBe(saved.revision)
  expect(discussionLocals(workspace, target.artifact_id)).toEqual([pending])
  expect(JSON.parse(localStorage.getItem(key(saved))!).value).toEqual(input)
  vi.unstubAllGlobals(); discardDiscussionLocal(pending)
  expect(localStorage.getItem(key(saved))).toBeNull()
})
it('preserves another tab write interleaved with deletion itself, without depending on a localStorage lock', () => {
  const old=retainDiscussionLocal('interleaved',workspace,target,'human',input)
  const storage=localStorage, remove=storage.removeItem.bind(storage)
  const external={...JSON.parse(storage.getItem(key(old))!),revision:crypto.randomUUID(),value:{...input,input:{...input.input,body:'동시에 쓴 새 입력'}}}
  vi.stubGlobal('localStorage',{get length(){return storage.length},key:storage.key.bind(storage),getItem:storage.getItem.bind(storage),setItem:storage.setItem.bind(storage),removeItem(storageKey:string){
    if(storageKey===key(old))storage.setItem(key(external),JSON.stringify(external))
    remove(storageKey)
  }})
  discardDiscussionLocal(old)
  expect(storage.getItem(key(old))).toBeNull()
  expect(JSON.parse(storage.getItem(key(external))!).value.input.body).toBe('동시에 쓴 새 입력')
  expect(discussionLocals(workspace,target.artifact_id)).toHaveLength(1)
})
it('can discard a separate old immutable copy while preserving newer memory and its quota fallback', () => {
  const old=retainDiscussionLocal('discard-old',workspace,target,'human',input)
  const storage=localStorage
  const external={...JSON.parse(storage.getItem(key(old))!),revision:crypto.randomUUID()}
  storage.setItem(key(external),JSON.stringify(external))
  const copy=discussionLocals(workspace,target.artifact_id).find(record=>record.revision===external.revision)!
  vi.stubGlobal('localStorage',{get length(){return storage.length},key:storage.key.bind(storage),getItem:storage.getItem.bind(storage),removeItem:storage.removeItem.bind(storage),setItem(){throw new DOMException('full','QuotaExceededError')}})
  const newer=retainDiscussionLocal(old.id,workspace,target,'human',{...input,input:{...input.input,body:'메모리의 새 입력'}})
  discardDiscussionLocal(copy);discardDiscussionLocal(old)
  expect(storage.getItem(key(copy))).toBeNull()
  expect(storage.getItem(key(old))).not.toBeNull()
  expect(discussionLocals(workspace,target.artifact_id)).toEqual([newer])
})
it('offers other generations separately while isolating canonical workspace roots', () => {
  const original = retainDiscussionLocal('scope', workspace, target, 'human', input)
  const older = retainDiscussionLocal('generation', workspace, { ...target, generation: '019f0000-0000-7000-8000-000000000001' }, 'human', input)
  expect(discussionLocals({ ...workspace, mascRoot: '/other' }, target.artifact_id)).toEqual([])
  expect(discussionLocals(workspace, target.artifact_id)).toEqual([original, older])
})
