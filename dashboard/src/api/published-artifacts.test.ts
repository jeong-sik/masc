import { beforeEach, describe, expect, it, vi } from 'vitest'
import { Schema } from 'effect'
import nativeInventory from './fixtures/published-artifacts-native.json'
import { get, post } from './core'
import { ArtifactPublicationSchema, fetchPublishedArtifact, fetchPublishedArtifacts } from './published-artifacts'
import { resolveArtifactCheck, setArtifactCheck } from './published-artifact-checks'

vi.mock('./core', () => ({ get: vi.fn(), post: vi.fn() }))
beforeEach(() => vi.resetAllMocks())

// Captured from the matching native server at cc06814, using owned reports.
// Published_artifact.revision_fields emits normalized_artifact_ref_to_json:
// the content-addressed digest is inside body._blob in every report projection.
describe('published artifact native wire contract', () => {
  it('admits the real catalog, document history and publication envelope', async () => {
    vi.mocked(get).mockResolvedValueOnce(nativeInventory)
    const listing = await fetchPublishedArtifacts()
    expect(listing.artifacts).toHaveLength(2)
    const artifact = nativeInventory.artifacts[0]!
    const history = [artifact, { ...artifact, revision: 1 }]
    vi.mocked(get).mockResolvedValueOnce({ artifact, content: '# 원본\r\nΩ', revisions: history })
    const document = await fetchPublishedArtifact(artifact.id, '2')
    expect(document.artifact.body._blob.sha256).toBe(artifact.body._blob.sha256)
    expect(document.revisions[1]!.body._blob.sha256).toBe(artifact.body._blob.sha256)
    expect(document.content).toBe('# 원본\r\nΩ')
    expect(Schema.decodeUnknownSync(ArtifactPublicationSchema)({
      schema: 'masc.published_artifact.v1', artifact, revision_url: `${artifact.url}&revision=2`,
    }).artifact).toEqual(listing.artifacts[0])
  })

  it('uses the admitted native digest for shared check resolution and mutation', async () => {
    vi.mocked(get).mockResolvedValueOnce(nativeInventory)
    const artifact = (await fetchPublishedArtifacts()).artifacts[0]!
    const check = { id: artifact.id, revision: artifact.revision, body_sha256: artifact.body._blob.sha256,
      checked: true, change_id: `check-${'c'.repeat(32)}`, changed_by: 'second-client', changed_at: '2026-10-21T08:44:18Z' }
    expect(resolveArtifactCheck(artifact, { checks: [check], diagnostics: [] })).toEqual({ kind: 'known', check })
    vi.mocked(post).mockResolvedValueOnce({ check })
    expect(await setArtifactCheck(artifact, null, true)).toEqual(check)
    expect(post).toHaveBeenCalledWith('/api/v1/published-artifact-checks', {
      id: artifact.id, revision: artifact.revision, body_sha256: check.body_sha256, checked: true, expected_change_id: null,
    })
    expect(resolveArtifactCheck(artifact, { checks: [{ ...check, body_sha256: '0'.repeat(64) }], diagnostics: [] }).kind).toBe('unknown')
  })

  it.each([
    { sha256: 'a'.repeat(64) },
    { _blob: { sha256: 'invalid-digest' } },
  ])('refuses a noncanonical or invalid body reference', async body => {
    vi.mocked(get).mockResolvedValueOnce({ ...nativeInventory, artifacts: [{ ...nativeInventory.artifacts[0], body }] })
    await expect(fetchPublishedArtifacts()).rejects.toThrow()
  })
})
