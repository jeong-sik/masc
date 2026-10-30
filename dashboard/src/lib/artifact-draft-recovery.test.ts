import { afterEach, expect, it, vi } from 'vitest'
import { artifactDraftRecoveries, discardArtifactDraftRecovery, retainArtifactDraft } from './artifact-draft-recovery'
const workspace = { basePath: '/recovery-fixture', mascRoot: '/recovery-fixture/.masc' }
const target = { artifact_id: `artifact-${'d'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
const ids = ['recovery-a', 'recovery-b']
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); artifactDraftRecoveries(workspace,target.artifact_id).forEach(discardArtifactDraftRecovery) })
it('preserves retired owners separately and acknowledges only that owner’s recovery', () => {
  retainArtifactDraft(ids[0]!, workspace, target, 'first-owner')
  const second=retainArtifactDraft(ids[1]!, workspace, target, 'second-owner')
  discardArtifactDraftRecovery(second)
  expect(artifactDraftRecoveries(workspace, target.artifact_id).map(record => record.state)).toEqual(['first-owner'])
  expect(artifactDraftRecoveries({ ...workspace, mascRoot: '/other/.masc' }, target.artifact_id)).toEqual([])
  expect(artifactDraftRecoveries(workspace, `artifact-${'e'.repeat(32)}`)).toEqual([])
})
it('can load durable recovery after module reload and keeps older generations for download', async () => {
  retainArtifactDraft(ids[0]!, workspace, target, 'full CRDT snapshot')
  vi.resetModules()
  const reloaded = await import('./artifact-draft-recovery')
  const record = reloaded.artifactDraftRecoveries(workspace, target.artifact_id)[0]!
  expect(record.state).toBe('full CRDT snapshot'); expect(record.persisted).toBe(true)
  expect(record.target.generation).toBe(target.generation)
  reloaded.discardArtifactDraftRecovery(record)
})
it('retains the newer in-page snapshot and reports a storage failure', () => {
  retainArtifactDraft(ids[0]!, workspace, target, 'old')
  const storage = localStorage
  vi.stubGlobal('localStorage', { getItem: storage.getItem.bind(storage), key: storage.key.bind(storage), get length() { return storage.length }, setItem() { throw new Error('quota') } })
  expect(retainArtifactDraft(ids[0]!, workspace, target, 'new').persisted).toBe(false)
  expect(artifactDraftRecoveries(workspace, target.artifact_id)[0]?.state).toBe('new')
})
