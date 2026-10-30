import { expect, it } from 'vitest'
import type { ArtifactPublication } from '../api/published-artifacts'
import { ArtifactPublicationOutcomes } from './artifact-publication-outcomes'

it('settles only the original operation and workspace, even for the same artifact revision', () => {
  const outcomes = new ArtifactPublicationOutcomes(), owner = { authority: { workspaceRoot: '/workspace' } }
  const publication: ArtifactPublication = { schema: 'masc.published_artifact.v1', revision_url: '/revision', artifact: {
    id: `artifact-${'a'.repeat(32)}`, revision: 2, title: 'report', summary: '', format: 'markdown', author: 'author',
    created_at: '2026-10-28T00:00:00Z', task_id: null, goal_id: null, body: { _blob: { sha256: 'a'.repeat(64) } }, url: '/artifact',
  } }
  const first = { kind: 'checkpoint' as const, identity: {}, title: 'report', publication,
    workspace: { basePath: '/workspace', mascRoot: '/runtime-a' }, status: 'pending' as const }
  const otherRoot = { ...first, identity: {}, workspace: { ...first.workspace, mascRoot: '/runtime-b' } }
  const concurrent = { ...first, identity: {} }
  outcomes.record(owner, first); outcomes.record(owner, otherRoot); outcomes.record(owner, concurrent)
  outcomes.record(owner, { ...first, status: 'unconfirmed', detail: 'late response' })
  const records = outcomes.records()
  expect(records).toHaveLength(3)
  expect(records.map(record => record.outcome)).toEqual([
    { ...first, status: 'unconfirmed', detail: 'late response' }, otherRoot, concurrent,
  ])
})
