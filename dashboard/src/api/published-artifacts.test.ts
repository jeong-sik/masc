import { beforeEach, describe, expect, it, vi } from 'vitest'
import { Schema } from 'effect'
import nativeInventory from './fixtures/published-artifacts-native.json'
import { get, getPublic, post } from './core'
import { ArtifactPublicationSchema, captureArtifactWorkspace, fetchPublishedArtifact, fetchPublicArtifact, fetchPublishedArtifacts, setPublishedArtifactShared } from './published-artifacts'
import { resolveArtifactCheck, setArtifactCheck } from './published-artifact-checks'

vi.mock('./core', () => ({ get: vi.fn(), getPublic: vi.fn(), post: vi.fn() }))
beforeEach(() => vi.resetAllMocks())

// Captured from the matching native server at cc06814, using owned reports.
// Published_artifact.revision_fields emits normalized_artifact_ref_to_json:
// the content-addressed digest is inside body._blob in every report projection.
describe('published artifact native wire contract', () => {
  it('captures the canonical health roots without deriving the MASC root from the base', async () => {
    vi.mocked(get).mockResolvedValueOnce({ paths: {
      effective_base_path: '/workspace-a', effective_masc_root: '/separate-runtime-root',
    } })
    expect(await captureArtifactWorkspace('/workspace-a')).toEqual({
      basePath: '/workspace-a', mascRoot: '/separate-runtime-root',
    })
  })

  it('refuses incomplete health workspace identity before publication', async () => {
    vi.mocked(get).mockResolvedValueOnce({ paths: { effective_base_path: '/workspace-a' } })
    await expect(captureArtifactWorkspace('/workspace-a')).rejects.toThrow()
    expect(post).not.toHaveBeenCalled()
  })

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

  it('does not bypass a refused artifact read with a static snapshot', async () => {
    const artifact = nativeInventory.artifacts[0]!
    const refused = Object.assign(new Error('Unauthorized'), { status: 401 })
    vi.mocked(get).mockRejectedValueOnce(refused)
    await expect(fetchPublishedArtifact(artifact.id, '2')).rejects.toBe(refused)
    expect(get).toHaveBeenCalledTimes(1)
    expect(get).toHaveBeenCalledWith(`/api/v1/published-artifacts/${artifact.id}?revision=2`, {})
  })

  it('uses the explicitly anonymous transport for a public fixed revision', async () => {
    const artifact = nativeInventory.artifacts[0]!
    vi.mocked(getPublic).mockResolvedValueOnce({ artifact, content: '# public', revisions: [artifact], shared: true })
    expect((await fetchPublicArtifact(artifact.id, '2')).artifact.id).toBe(artifact.id)
    expect(getPublic).toHaveBeenCalledWith(`/api/v1/published-artifacts/${artifact.id}?revision=2`, { signal: undefined })
    expect(get).not.toHaveBeenCalled()
  })

  it('keeps the body cancellation contract on the unauthenticated fallback', async () => {
    const artifact = nativeInventory.artifacts[0]!, signal = new AbortController().signal
    const payload = { artifact, content: '# 공유 보고서', revisions: [artifact], shared: true }
    vi.mocked(get)
      .mockRejectedValueOnce(Object.assign(new Error('Unauthorized'), { status: 401 }))
      .mockResolvedValueOnce(payload)
    await fetchPublishedArtifact(artifact.id, '2', signal, undefined, true)
    expect(get).toHaveBeenNthCalledWith(1, `/api/v1/published-artifacts/${artifact.id}?revision=2`, { signal, consumeWithinTimeout: true })
    expect(get).toHaveBeenNthCalledWith(2, `/dashboard/assets/published-artifacts/${artifact.id}-r2.json`, { signal, consumeWithinTimeout: true })
  })

  it('toggles per-artifact external sharing via /api/v1/published-artifact-shares', async () => {
    const artifact = nativeInventory.artifacts[0]!
    const workspace = { basePath: '/workspace', mascRoot: '/workspace/.masc' }
    vi.mocked(post).mockResolvedValueOnce({ id: artifact.id, shared: true })
    expect(await setPublishedArtifactShared(artifact.id, true, workspace)).toEqual({ id: artifact.id, shared: true })
    expect(post).toHaveBeenCalledWith('/api/v1/published-artifact-shares', {
      id: artifact.id, shared: true, expected_workspace: { base_path: workspace.basePath, masc_root: workspace.mascRoot },
    }, { 'x-masc-expected-base-path': workspace.basePath, 'x-masc-expected-masc-root': workspace.mascRoot })
  })
})
