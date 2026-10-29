import { beforeEach, describe, expect, it, vi } from 'vitest'
import { Schema } from 'effect'
import nativeInventory from './fixtures/published-artifacts-native.json'
import { get, getPublic, getWithResponse, post } from './core'
import { ArtifactPublicationSchema, captureArtifactWorkspace, fetchPublishedArtifact, fetchWorkspacePublishedArtifact, fetchPublicArtifact, fetchPublishedArtifacts, setPublishedArtifactShared } from './published-artifacts'
import { resolveArtifactCheck, setArtifactCheck } from './published-artifact-checks'

vi.mock('./core', () => ({ DEFAULT_POST_TIMEOUT_MS: 30_000, get: vi.fn(), getPublic: vi.fn(), getWithResponse: vi.fn(), post: vi.fn() }))
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

  it('requires the workspace admission receipt on an observed sharing document', async () => {
    const artifact = nativeInventory.artifacts[0]!
    const workspace = { basePath: '/workspace-a', mascRoot: '/runtime-a' }
    const data = { artifact, content: 'body', revisions: [artifact], shared: false, share_version: 0 }
    vi.mocked(getWithResponse).mockResolvedValueOnce({ data, headers: new Headers({ 'x-masc-workspace-read': 'matched-v1' }) })
    expect((await fetchWorkspacePublishedArtifact(artifact.id, '2', workspace)).artifact.id).toBe(artifact.id)
    expect(getWithResponse).toHaveBeenCalledWith(
      `/api/v1/published-artifacts/${artifact.id}?revision=2&expected_base_path=%2Fworkspace-a&expected_masc_root=%2Fruntime-a`,
      { signal: undefined, consumeWithinTimeout: true, extraHeaders: { 'x-masc-expected-base-path': '/workspace-a', 'x-masc-expected-masc-root': '/runtime-a' } },
    )
    vi.mocked(getWithResponse).mockResolvedValueOnce({ data, headers: new Headers() })
    await expect(fetchWorkspacePublishedArtifact(artifact.id, '2', workspace)).rejects.toThrow(/작업 공간 확인 응답/)
  })

  it('toggles per-artifact external sharing via /api/v1/published-artifact-shares', async () => {
    const artifact = nativeInventory.artifacts[0]!
    const workspace = { basePath: '/workspace', mascRoot: '/workspace/.masc' }
    const operation = { id: artifact.id, shared: true, expectedVersion: 0, operationId: '01890e2a-4c8e-7b21-9f3c-000000000031',
      expectedArtifactRevision: artifact.revision, expectedArtifactSha256: artifact.body._blob.sha256 }
    const reply = { id: artifact.id, receipt: { operation_id: operation.operationId, expected_version: 0,
      expected_artifact_revision: operation.expectedArtifactRevision, expected_artifact_sha256: operation.expectedArtifactSha256,
      publication_matches: true, requested: true, outcome: 'applied', snapshot: { version: 1, shared: true } }, current: { version: 2, shared: false } }
    vi.mocked(post).mockResolvedValueOnce(reply)
    expect(await setPublishedArtifactShared(operation, workspace)).toEqual(reply)
    expect(post).toHaveBeenCalledWith('/api/v1/published-artifact-shares', {
      id: artifact.id, shared: true, operation_id: operation.operationId, expected_version: 0,
      expected_artifact_revision: operation.expectedArtifactRevision, expected_artifact_sha256: operation.expectedArtifactSha256,
      expected_workspace: { base_path: workspace.basePath, masc_root: workspace.mascRoot },
    }, { 'x-masc-expected-base-path': workspace.basePath, 'x-masc-expected-masc-root': workspace.mascRoot }, 30_000, undefined, true)
  })

  it('keeps an old conflict receipt separate from the current sharing state', async () => {
    const id = nativeInventory.artifacts[0]!.id
    const workspace = { basePath: '/workspace', mascRoot: '/workspace/.masc' }
    const operation = { id, shared: true, expectedVersion: 0, operationId: '01890e2a-4c8e-7b21-9f3c-000000000032',
      expectedArtifactRevision: 2, expectedArtifactSha256: 'a'.repeat(64) }
    const reply = { id, receipt: { operation_id: operation.operationId, expected_version: 0,
      expected_artifact_revision: 2, expected_artifact_sha256: 'a'.repeat(64), publication_matches: true,
      requested: true, outcome: 'conflict', snapshot: { version: 1, shared: false } }, current: { version: 2, shared: true } }
    vi.mocked(post).mockRejectedValueOnce(Object.assign(new Error('conflict'), { status: 409, responseData: reply }))
    expect(await setPublishedArtifactShared(operation, workspace)).toEqual(reply)
  })

  it('recognizes a publication conflict without requiring the share version to change', async () => {
    const id = nativeInventory.artifacts[0]!.id
    const workspace = { basePath: '/workspace', mascRoot: '/workspace/.masc' }
    const operation = { id, shared: true, expectedVersion: 0, operationId: '01890e2a-4c8e-7b21-9f3c-000000000033',
      expectedArtifactRevision: 2, expectedArtifactSha256: 'a'.repeat(64) }
    const reply = { id, receipt: { operation_id: operation.operationId, expected_version: 0,
      expected_artifact_revision: 2, expected_artifact_sha256: 'a'.repeat(64), publication_matches: false,
      requested: true, outcome: 'conflict', snapshot: { version: 0, shared: false } }, current: { version: 0, shared: false } }
    vi.mocked(post).mockRejectedValueOnce(Object.assign(new Error('conflict'), { status: 409, responseData: reply }))
    expect(await setPublishedArtifactShared(operation, workspace)).toEqual(reply)
  })

  it('reports a workspace refusal for this attempt without claiming the operation settled', async () => {
    const id = nativeInventory.artifacts[0]!.id
    const workspace = { basePath: '/workspace', mascRoot: '/workspace/.masc' }
    const operation = { id, shared: true, expectedVersion: 0, operationId: '01890e2a-4c8e-7b21-9f3c-000000000034',
      expectedArtifactRevision: 2, expectedArtifactSha256: 'a'.repeat(64) }
    vi.mocked(post).mockRejectedValueOnce(Object.assign(new Error('conflict'), {
      status: 409, responseData: { code: 'workspace_precondition_failed' },
    }))
    await expect(setPublishedArtifactShared(operation, workspace)).rejects.toThrow(/이번 시도.*다른 시도는 미확인/)
  })
})
