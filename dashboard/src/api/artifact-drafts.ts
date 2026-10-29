import { Schema } from 'effect'
import { getWithResponse, post } from './core'
import { PublishedArtifactSchema, artifactWorkspaceBody, artifactWorkspaceHeaders, artifactWorkspaceQuery, requireArtifactWorkspaceRead, type ArtifactWorkspace } from './published-artifacts'
import type { ArtifactDiscussionRequest } from './artifact-discussion'

const Integer = Schema.Int.pipe(Schema.between(0, Number.MAX_SAFE_INTEGER))
export const ArtifactDraftTargetSchema = Schema.Struct({
  artifact_id: PublishedArtifactSchema.fields.id,
  generation: Schema.String.pipe(Schema.pattern(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)),
})
export const ArtifactDraftPositionSchema = Schema.Struct({
  anchor: Schema.Array(Schema.Int.pipe(Schema.between(0, 255))),
  head: Schema.Array(Schema.Int.pipe(Schema.between(0, 255))),
})
export const ArtifactDraftSelectionSchema = Schema.Struct({ target: ArtifactDraftTargetSchema, position: ArtifactDraftPositionSchema })
const DiscussionId = ArtifactDraftTargetSchema.fields.generation
export const ArtifactDiscussionCommandSchema = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('comment'), position: ArtifactDraftPositionSchema, quote: Schema.String, body: Schema.String,
    proposal: Schema.optional(Schema.NullOr(Schema.String)) }),
  Schema.Struct({ kind: Schema.Literal('reply'), thread_id: DiscussionId, body: Schema.String }),
  Schema.Struct({ kind: Schema.Literal('resolve','reopen','accept','reject'), thread_id: DiscussionId }))
export const ArtifactDiscussionRequestSchema = Schema.Struct({ id: DiscussionId, command: ArtifactDiscussionCommandSchema })
export const ArtifactDiscussionEventSchema = Schema.Struct({ request: ArtifactDiscussionRequestSchema,
  actor: Schema.String, at: Schema.String, applied: Schema.NullOr(ArtifactDraftPositionSchema) })
export const ArtifactThreadSchema = Schema.Struct({ id: DiscussionId, position: ArtifactDraftPositionSchema, quote: Schema.String,
  messages: Schema.Array(Schema.Struct({ id: DiscussionId, actor: Schema.String, at: Schema.String, body: Schema.String })),
  proposal: Schema.NullOr(Schema.String), decision: Schema.Union(Schema.Struct({ kind: Schema.Literal('pending') }),
    Schema.Struct({ kind: Schema.Literal('applied','rejected'), event: ArtifactDiscussionEventSchema })), resolved: Schema.Boolean })
const DraftSchema = Schema.Struct({
  schema: Schema.Literal('masc.artifact_draft.v2'), target: ArtifactDraftTargetSchema,
  base_revision: Integer.pipe(Schema.positive()),
  base_sha256: PublishedArtifactSchema.fields.body.fields._blob.fields.sha256,
  state: Schema.String.pipe(Schema.nonEmptyString()), sequence: Integer,
  updated_by: Schema.String.pipe(Schema.nonEmptyString()), updated_at: Schema.String.pipe(Schema.nonEmptyString()),
})
export const ArtifactDraftViewSchema = Schema.Struct({ draft: DraftSchema, content: Schema.String,
  threads: Schema.Array(ArtifactThreadSchema), discussion_receipts: Schema.Array(ArtifactDiscussionEventSchema),
  selection: Schema.NullOr(Schema.Struct({ selection: ArtifactDraftSelectionSchema, anchor: Integer, head: Integer })),
})
export type ArtifactDraftTarget = typeof ArtifactDraftTargetSchema.Type
export type ArtifactDraftSelection = typeof ArtifactDraftSelectionSchema.Type
export type ArtifactDraftView = typeof ArtifactDraftViewSchema.Type
export type ArtifactDraftCommand =
  | { action: 'open'; artifact_id: string; revision: number }
  | { action: 'merge'; target: ArtifactDraftTarget; updates: readonly string[] }
  | { action: 'select'; target: ArtifactDraftTarget; anchor: number; head: number }
  | { action: 'resolve'; selection: ArtifactDraftSelection }
  | { action: 'edit'; selection: ArtifactDraftSelection; expected: string; replacement: string }
  | { action: 'discuss'; target: ArtifactDraftTarget; request: ArtifactDiscussionRequest }
const path = '/api/v1/artifact-drafts'
const sameTarget = (a: ArtifactDraftTarget, b: ArtifactDraftTarget) => a.artifact_id === b.artifact_id && a.generation === b.generation
function decode(input: unknown, artifactId: string, target?: ArtifactDraftTarget): ArtifactDraftView {
  const view = Schema.decodeUnknownSync(ArtifactDraftViewSchema)(input)
  if (view.draft.target.artifact_id !== artifactId || (target && !sameTarget(view.draft.target, target))
    || (view.selection && !sameTarget(view.selection.selection.target, view.draft.target))) {
    throw new Error('공유 원고 응답의 문서 또는 세대가 요청과 다릅니다.')
  }
  return view
}
export async function fetchArtifactDraft(artifactId: string, workspace: ArtifactWorkspace, signal?: AbortSignal): Promise<ArtifactDraftView> {
  const response = await getWithResponse<unknown>(`${path}/${encodeURIComponent(artifactId)}?${artifactWorkspaceQuery(workspace)}`, {
    signal, extraHeaders: artifactWorkspaceHeaders(workspace),
  })
  requireArtifactWorkspaceRead(response.headers)
  return decode(response.data, artifactId)
}
export async function sendArtifactDraftCommand(command: ArtifactDraftCommand, workspace: ArtifactWorkspace): Promise<ArtifactDraftView> {
  const target = command.action === 'open' ? undefined : (command.action === 'edit' || command.action === 'resolve') ? command.selection.target : command.target
  const artifactId = command.action === 'open' ? command.artifact_id
    : (command.action === 'edit' || command.action === 'resolve') ? command.selection.target.artifact_id : command.target.artifact_id
  // The transport sends once. A caller retains its local CRDT updates and
  // reconciles uncertain responses; it must not blindly repeat Keeper edits.
  return decode(await post<unknown>(path, { ...command, expected_workspace: artifactWorkspaceBody(workspace) }, artifactWorkspaceHeaders(workspace)), artifactId, target)
}
