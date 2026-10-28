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
})
const ArtifactShareSchema = Schema.Struct({
  id: Schema.String.pipe(Schema.pattern(/^artifact-[0-9a-f]{32}$/)),
  shared: Schema.Boolean,
})
export type PublishedArtifact = typeof PublishedArtifactSchema.Type
export type ArtifactDocument = typeof DocumentSchema.Type
export type ArtifactList = typeof ListSchema.Type
export type ArtifactPublication = typeof ArtifactPublicationSchema.Type
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

export async function captureArtifactWorkspace(expectedBasePath: string, signal?: AbortSignal): Promise<ArtifactWorkspace> {
  const health = signal ? await get<unknown>('/health?full=1', { signal, consumeWithinTimeout: true })
    : await get<unknown>('/health?full=1')
  const { paths } = Schema.decodeUnknownSync(ArtifactWorkspaceSchema)(health)
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

export async function setPublishedArtifactShared(id: string, shared: boolean, workspace: ArtifactWorkspace): Promise<{ id: string; shared: boolean }> {
  const result = Schema.decodeUnknownSync(ArtifactShareSchema)(
    await post<unknown>('/api/v1/published-artifact-shares', {
      id, shared, expected_workspace: { base_path: workspace.basePath, masc_root: workspace.mascRoot },
    }, artifactWorkspaceHeaders(workspace)),
  )
  if (result.id !== id || result.shared !== shared) {
    throw new Error('외부 공유 상태 응답이 요청과 다릅니다.')
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

export async function fetchPublishedArtifact(id: string, revision: string | undefined, signal?: AbortSignal, workspace?: ArtifactWorkspace,
  consumeWithinTimeout = false): Promise<ArtifactDocument> {
  const raw = await get<unknown>(artifactRequestPath(id, revision), {
    signal, ...(workspace ? { extraHeaders: artifactWorkspaceHeaders(workspace) } : {}),
    ...(consumeWithinTimeout ? { consumeWithinTimeout: true } : {}),
  })
  return decodeArtifactDocument(id, revision, raw)
}

export async function fetchPublicArtifact(id: string, revision: string | undefined, signal?: AbortSignal): Promise<ArtifactDocument> {
  const raw = await getPublic<unknown>(artifactRequestPath(id, revision), { signal })
  return decodeArtifactDocument(id, revision, raw)
}
