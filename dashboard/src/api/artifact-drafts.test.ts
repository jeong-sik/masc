import { beforeEach, expect, it, vi } from 'vitest'
import { get, post } from './core'
import { fetchArtifactDraft, sendArtifactDraftCommand } from './artifact-drafts'
vi.mock('./core', () => ({ get: vi.fn(), post: vi.fn() }))
const target = { artifact_id: `artifact-${'a'.repeat(32)}`, generation: '019c6e27-e55b-73d1-87d8-4e01f1f75043' }
const workspace = { basePath: '/workspace', mascRoot: '/runtime' }
const headers = { 'x-masc-expected-base-path': '/workspace', 'x-masc-expected-masc-root': '/runtime' }
const view = { draft: { schema: 'masc.artifact_draft.v1', target, base_revision: 1, base_sha256: 'a'.repeat(64),
  state: 'AAA=', sequence: 0, updated_by: 'keeper', updated_at: '2026-10-25T13:00:00Z' }, content: '', selection: null }
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
