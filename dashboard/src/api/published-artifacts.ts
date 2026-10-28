import { Schema } from 'effect'
import { get, getPublic, post } from './core'

const revisionFields = {
  revision: Schema.Int.pipe(Schema.positive(), Schema.lessThanOrEqualTo(Number.MAX_SAFE_INTEGER)),
  body: Schema.Struct({ _blob: Schema.Struct({ sha256: Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/)) }) }),
  title: Schema.String, summary: Schema.String,
  format: Schema.Literal('markdown', 'html'),
  author: Schema.String, created_at: Schema.String,
  task_id: Schema.NullOr(Schema.String), goal_id: Schema.NullOr(Schema.String),
}
export const ArtifactRevisionSchema = Schema.Struct(revisionFields)
export const PublishedArtifactSchema = Schema.Struct({
  ...revisionFields,
  id: Schema.String.pipe(Schema.pattern(/^artifact-[0-9a-f]{32}$/)),
  url: Schema.String,
})
export const ArtifactPublicationSchema = Schema.Struct({
  schema: Schema.Literal('masc.published_artifact.v1'),
  artifact: PublishedArtifactSchema,
  revision_url: Schema.String,
})
const ListSchema = Schema.Struct({
  artifacts: Schema.Array(PublishedArtifactSchema),
  diagnostics: Schema.Array(Schema.Struct({ id: Schema.String, error: Schema.String })),
})
const DocumentSchema = Schema.Struct({
  artifact: PublishedArtifactSchema, content: Schema.String, revisions: Schema.Array(ArtifactRevisionSchema),
  shared: Schema.optional(Schema.Boolean),
  share_version: Schema.optional(Schema.Int.pipe(Schema.nonNegative(), Schema.lessThanOrEqualTo(Number.MAX_SAFE_INTEGER))),
})
const ShareSnapshotSchema = Schema.Struct({
  version: Schema.Int.pipe(Schema.nonNegative(), Schema.lessThanOrEqualTo(Number.MAX_SAFE_INTEGER)),
  shared: Schema.Boolean,
})
const ArtifactShareSchema = Schema.Struct({
  id: Schema.String.pipe(Schema.pattern(/^artifact-[0-9a-f]{32}$/)),
  receipt: Schema.Struct({
    operation_id: Schema.String.pipe(Schema.pattern(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)),
    expected_version: Schema.Int.pipe(Schema.nonNegative(), Schema.lessThanOrEqualTo(Number.MAX_SAFE_INTEGER)),
    expected_artifact_revision: Schema.Int.pipe(Schema.positive(), Schema.lessThanOrEqualTo(Number.MAX_SAFE_INTEGER)),
    expected_artifact_sha256: Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/)),
    publication_matches: Schema.Boolean,
    requested: Schema.Boolean,
    outcome: Schema.Literal('applied', 'conflict'),
    snapshot: ShareSnapshotSchema,
  }),
  current: ShareSnapshotSchema,
})
export type ArtifactShareOperation = { id: string; operationId: string; expectedVersion: number; shared: boolean;
  expectedArtifactRevision: number; expectedArtifactSha256: string }
export type ArtifactShareResult = typeof ArtifactShareSchema.Type
export type PublishedArtifact = typeof PublishedArtifactSchema.Type
export type ArtifactDocument = typeof DocumentSchema.Type
export type ArtifactList = typeof ListSchema.Type
export type ArtifactPublication = typeof ArtifactPublicationSchema.Type
export function latestArtifactRevision(doc: ArtifactDocument): typeof ArtifactRevisionSchema.Type | undefined {
  return doc.revisions.reduce<typeof ArtifactRevisionSchema.Type | undefined>(
    (latest, revision) => !latest || revision.revision > latest.revision ? revision : latest, undefined)
}
export type ArtifactDraft = {
  title: string; summary: string; format: 'markdown' | 'html'; content: string;
  task_id?: string | null; goal_id?: string | null;
}
export type ArtifactPublicationRequest = ArtifactDraft & (
  { id?: never; expected_revision?: never } | { id: string; expected_revision: number }
)
const ArtifactWorkspaceSchema = Schema.Struct({ paths: Schema.Struct({
  effective_base_path: Schema.String.pipe(Schema.nonEmptyString()),
  effective_masc_root: Schema.String.pipe(Schema.nonEmptyString()),
}) })
export type ArtifactWorkspace = { readonly basePath: string; readonly mascRoot: string }

export async function captureArtifactWorkspace(expectedBasePath: string): Promise<ArtifactWorkspace> {
  const { paths } = Schema.decodeUnknownSync(ArtifactWorkspaceSchema)(await get<unknown>('/health?full=1'))
  if (paths.effective_base_path !== expectedBasePath) {
    throw new Error('서버의 작업 공간이 원고를 작성한 작업 공간과 다릅니다. 원고를 보관하고 연결을 확인해 주세요.')
  }
  return { basePath: paths.effective_base_path, mascRoot: paths.effective_masc_root }
}

export function artifactWorkspaceHeaders(workspace: ArtifactWorkspace): Record<string, string> {
  return { 'x-masc-expected-base-path': workspace.basePath, 'x-masc-expected-masc-root': workspace.mascRoot }
}

// A publication is sent once. Callers retain the returned identity before
// readback; a failed response/readback must never trigger an automatic retry.
export async function publishArtifact(request: ArtifactPublicationRequest, workspace: ArtifactWorkspace): Promise<ArtifactPublication> {
  const result = Schema.decodeUnknownSync(ArtifactPublicationSchema)(
    await post<unknown>('/api/v1/published-artifacts', request, artifactWorkspaceHeaders(workspace)),
  )
  if (request.id !== undefined && (result.artifact.id !== request.id
    || result.artifact.revision !== request.expected_revision + 1)) {
    throw new Error('저장 응답의 문서 또는 버전이 요청과 다릅니다. 적용 여부를 확인해 주세요.')
  }
  return result
}

export async function readPublishedDraft(publication: ArtifactPublication, sent: ArtifactDraft, workspace: ArtifactWorkspace): Promise<ArtifactDocument> {
  const doc = await fetchPublishedArtifact(publication.artifact.id, String(publication.artifact.revision), undefined, workspace)
  if (doc.content !== sent.content || doc.artifact.title !== sent.title
    || doc.artifact.summary !== sent.summary || doc.artifact.format !== sent.format
    || doc.artifact.body._blob.sha256 !== publication.artifact.body._blob.sha256) {
    throw new Error('저장된 문서가 보낸 내용과 다릅니다. 원고를 보관하고 적용 여부를 확인해 주세요.')
  }
  return doc
}

export function artifactHref(id: string, revision?: number): string {
  const params = new URLSearchParams({ section: 'artifacts', artifact: id })
  if (revision !== undefined) params.set('revision', String(revision))
  return `/dashboard/#/workspace?${params}`
}

export async function setPublishedArtifactShared(operation: ArtifactShareOperation, workspace: ArtifactWorkspace): Promise<ArtifactShareResult> {
  let raw: unknown
  let conflicted = false
  try {
    raw = await post<unknown>('/api/v1/published-artifact-shares', {
      id: operation.id, shared: operation.shared, operation_id: operation.operationId,
      expected_version: operation.expectedVersion,
      expected_artifact_revision: operation.expectedArtifactRevision, expected_artifact_sha256: operation.expectedArtifactSha256,
      expected_workspace: { base_path: workspace.basePath, masc_root: workspace.mascRoot },
    }, artifactWorkspaceHeaders(workspace))
  } catch (error) {
    if (typeof error !== 'object' || error === null || !('status' in error)
      || error.status !== 409 || !('responseData' in error)) throw error
    raw = error.responseData
    conflicted = true
  }
  const result = Schema.decodeUnknownSync(ArtifactShareSchema)(raw)
  const receipt = result.receipt
  if (result.id !== operation.id || receipt.operation_id !== operation.operationId
    || receipt.expected_version !== operation.expectedVersion || receipt.requested !== operation.shared
    || receipt.expected_artifact_revision !== operation.expectedArtifactRevision
    || receipt.expected_artifact_sha256 !== operation.expectedArtifactSha256
    || (receipt.outcome === 'conflict') !== conflicted
    || (receipt.outcome === 'applied' && (!receipt.publication_matches || receipt.snapshot.version !== operation.expectedVersion + 1
      || receipt.snapshot.shared !== operation.shared))
    || (receipt.outcome === 'conflict' && receipt.publication_matches && receipt.snapshot.version === operation.expectedVersion)
    || result.current.version < receipt.snapshot.version) {
    throw new Error('외부 공유 요청 결과가 보낸 작업과 다릅니다. 적용 여부를 확인해 주세요.')
  }
  return result
}

export async function fetchPublishedArtifacts(signal?: AbortSignal): Promise<ArtifactList> {
  return Schema.decodeUnknownSync(ListSchema)(await get<unknown>('/api/v1/published-artifacts', { signal }))
}

function artifactRequestPath(id: string, revision: string | undefined): string {
  const query = revision === undefined ? '' : `?revision=${encodeURIComponent(revision)}`
  return `/api/v1/published-artifacts/${encodeURIComponent(id)}${query}`
}

function decodeArtifactDocument(id: string, revision: string | undefined, raw: unknown): ArtifactDocument {
  const doc = Schema.decodeUnknownSync(DocumentSchema)(raw)
  if (doc.artifact.id !== id || (revision !== undefined && String(doc.artifact.revision) !== revision)) {
    throw new Error('요청한 문서와 저장된 문서의 식별자가 다릅니다.')
  }
  return doc
}

export async function fetchPublishedArtifact(id: string, revision: string | undefined, signal?: AbortSignal, workspace?: ArtifactWorkspace): Promise<ArtifactDocument> {
  const raw = await get<unknown>(artifactRequestPath(id, revision), {
    signal, ...(workspace ? { extraHeaders: artifactWorkspaceHeaders(workspace) } : {}),
  })
  return decodeArtifactDocument(id, revision, raw)
}

export async function fetchPublicArtifact(id: string, revision: string | undefined, signal?: AbortSignal): Promise<ArtifactDocument> {
  const raw = await getPublic<unknown>(artifactRequestPath(id, revision), { signal })
  return decodeArtifactDocument(id, revision, raw)
}
