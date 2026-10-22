import { Schema } from 'effect'
import { get } from './core'

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
})
export type PublishedArtifact = typeof PublishedArtifactSchema.Type
export type ArtifactDocument = typeof DocumentSchema.Type
export type ArtifactList = typeof ListSchema.Type

export function artifactHref(id: string, revision?: number): string {
  const params = new URLSearchParams({ section: 'artifacts', artifact: id })
  if (revision !== undefined) params.set('revision', String(revision))
  return `/dashboard/#/workspace?${params}`
}

export async function fetchPublishedArtifacts(signal?: AbortSignal): Promise<ArtifactList> {
  return Schema.decodeUnknownSync(ListSchema)(await get<unknown>('/api/v1/published-artifacts', { signal }))
}

export async function fetchPublishedArtifact(id: string, revision: string | undefined, signal?: AbortSignal): Promise<ArtifactDocument> {
  const query = revision === undefined ? '' : `?revision=${encodeURIComponent(revision)}`
  const doc = Schema.decodeUnknownSync(DocumentSchema)(await get<unknown>(`/api/v1/published-artifacts/${encodeURIComponent(id)}${query}`, { signal }))
  if (doc.artifact.id !== id || (revision !== undefined && String(doc.artifact.revision) !== revision)) {
    throw new Error('요청한 문서와 저장된 문서의 식별자가 다릅니다.')
  }
  return doc
}
