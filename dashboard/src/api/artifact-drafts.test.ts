import { beforeEach, expect, it, vi } from 'vitest'
import { get, post } from './core'
import { fetchArtifactDraft, sendArtifactDraftCommand } from './artifact-drafts'
import { artifactDiscussionRequest, sendArtifactDiscussion } from './artifact-discussion'
vi.mock('./core', () => ({ get: vi.fn(), post: vi.fn() }))
const target = { artifact_id: `artifact-${'a'.repeat(32)}`, generation: '019c6e27-e55b-73d1-87d8-4e01f1f75043' }
const workspace = { basePath: '/workspace', mascRoot: '/runtime' }
const headers = { 'x-masc-expected-base-path': '/workspace', 'x-masc-expected-masc-root': '/runtime' }
const view = { draft: { schema: 'masc.artifact_draft.v2', target, base_revision: 1, base_sha256: 'a'.repeat(64),
  state: 'AAA=', sequence: 0, updated_by: 'keeper', updated_at: '2026-10-25T13:00:00Z' }, content: '', threads: [], discussion_receipts: [], selection: null }
beforeEach(() => { vi.mocked(get).mockReset(); vi.mocked(post).mockReset() })
it('binds read and mutation to the captured workspace and carries document-bound selections', async () => {
  vi.mocked(get).mockResolvedValue(view)
  await fetchArtifactDraft(target.artifact_id, workspace)
  expect(get).toHaveBeenCalledWith(`/api/v1/artifact-drafts/${target.artifact_id}`, { signal: undefined, extraHeaders: headers })
  const command = { action: 'edit' as const, selection: { target, position: { anchor: [1], head: [2] } }, expected: 'before', replacement: 'after' }
  vi.mocked(post).mockResolvedValue(view)
  await sendArtifactDraftCommand(command, workspace)
  expect(post).toHaveBeenCalledWith('/api/v1/artifact-drafts', command, headers)
})
it.each(['document', 'generation', 'selection'] as const)('rejects mismatched %s response identity', async mismatch => {
  const changed = mismatch === 'document' ? { ...target, artifact_id: `artifact-${'b'.repeat(32)}` }
    : { ...target, generation: '019c6e27-e55b-73d1-87d8-4e01f1f75044' }
  vi.mocked(post).mockResolvedValue(mismatch === 'selection' ? { ...view, selection: {
    selection: { target: changed, position: { anchor: [], head: [] } }, anchor: 0, head: 0,
  } } : { ...view, draft: { ...view.draft, target: changed } })
  await expect(sendArtifactDraftCommand({ action: 'merge', target, updates: [] }, workspace)).rejects.toThrow(Error)
  expect(post).toHaveBeenCalledTimes(1)
})
it('does not repeat an uncertain Keeper edit', async () => {
  vi.mocked(post).mockRejectedValue(new Error('lost response'))
  await expect(sendArtifactDraftCommand({ action: 'edit', selection: { target, position: { anchor: [], head: [] } }, expected: '', replacement: 'text' }, workspace)).rejects.toThrow('lost response')
  expect(post).toHaveBeenCalledTimes(1)
})
it('keeps a stable discussion request id across uncertain transport and sends no automatic retry', async () => {
  const request=artifactDiscussionRequest({kind:'reply',thread_id:target.generation,body:'함께 확인해요'})
  vi.mocked(post).mockRejectedValueOnce(new Error('lost response'))
  await expect(sendArtifactDiscussion(target,request,workspace)).rejects.toThrow('lost response')
  expect(post).toHaveBeenCalledTimes(1)
  vi.mocked(post).mockResolvedValue(view)
  await sendArtifactDiscussion(target,request,workspace)
  expect(vi.mocked(post).mock.calls[0]).toEqual(vi.mocked(post).mock.calls[1])
  expect(post).toHaveBeenLastCalledWith('/api/v1/artifact-drafts',{action:'discuss',target,request},headers)
})
it('requires the fresh discussion view and refuses the previous schema instead of inventing a migration', async () => {
  vi.mocked(get).mockResolvedValue({...view,draft:{...view.draft,schema:'masc.artifact_draft.v1'}})
  await expect(fetchArtifactDraft(target.artifact_id,workspace)).rejects.toThrow()
  const {discussion_receipts:_,...incomplete}=view
  vi.mocked(get).mockResolvedValue(incomplete)
  await expect(fetchArtifactDraft(target.artifact_id,workspace)).rejects.toThrow()
})
