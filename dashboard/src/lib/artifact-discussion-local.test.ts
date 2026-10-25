import { afterEach, expect, it, vi } from 'vitest'
import { discussionLocals, discardDiscussionLocal, retainDiscussionLocal, type DiscussionLocalValue } from './artifact-discussion-local'
const workspace = { basePath: '/discussion-local-test', mascRoot: '/runtime' }
const target = { artifact_id: `artifact-${'d'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
const input: DiscussionLocalValue = { kind: 'input', input: { kind: 'reply', operationId: target.generation, threadId: target.generation, body: '이전 입력' } }
const key = (id: string) => `masc.artifact-discussion-local.v1:${id}`
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); discussionLocals(workspace, target.artifact_id).forEach(discardDiscussionLocal); localStorage.clear() })
it('preserves newer in-page and other-tab input when an earlier request is acknowledged', () => {
  const old = retainDiscussionLocal('same', workspace, target, 'human', input)
  const newer = retainDiscussionLocal('same', workspace, target, 'human', { ...input, input: { ...input.input, body: '새 입력' } })
  discardDiscussionLocal(old)
  expect(discussionLocals(workspace, target.artifact_id)).toEqual([newer])
  const external = { ...JSON.parse(localStorage.getItem(key('same'))!), revision: crypto.randomUUID(), value: { ...input, input: { ...input.input, body: '다른 탭' } } }
  localStorage.setItem(key('same'), JSON.stringify(external))
  discardDiscussionLocal(newer)
  expect(JSON.parse(localStorage.getItem(key('same'))!).value.input.body).toBe('다른 탭')
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
  expect(JSON.parse(localStorage.getItem(key('quota'))!).value).toEqual(input)
  vi.unstubAllGlobals(); discardDiscussionLocal(pending)
  expect(localStorage.getItem(key('quota'))).toBeNull()
})
it('offers other generations separately while isolating canonical workspace roots', () => {
  const original = retainDiscussionLocal('scope', workspace, target, 'human', input)
  const older = retainDiscussionLocal('generation', workspace, { ...target, generation: '019f0000-0000-7000-8000-000000000001' }, 'human', input)
  expect(discussionLocals({ ...workspace, mascRoot: '/other' }, target.artifact_id)).toEqual([])
  expect(discussionLocals(workspace, target.artifact_id)).toEqual([original, older])
})
