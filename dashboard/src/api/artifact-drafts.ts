import { Schema } from 'effect'
import { get, post } from './core'
import { PublishedArtifactSchema, artifactWorkspaceHeaders, type ArtifactWorkspace } from './published-artifacts'

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
const DraftSchema = Schema.Struct({
  schema: Schema.Literal('masc.artifact_draft.v1'), target: ArtifactDraftTargetSchema,
  base_revision: Integer.pipe(Schema.positive()),
  base_sha256: PublishedArtifactSchema.fields.body.fields._blob.fields.sha256,
  state: Schema.String.pipe(Schema.nonEmptyString()), sequence: Integer,
  updated_by: Schema.String.pipe(Schema.nonEmptyString()), updated_at: Schema.String.pipe(Schema.nonEmptyString()),
})
export const ArtifactDraftViewSchema = Schema.Struct({ draft: DraftSchema, content: Schema.String,
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
  return decode(await get<unknown>(`${path}/${encodeURIComponent(artifactId)}`, {
    signal, extraHeaders: artifactWorkspaceHeaders(workspace),
  }), artifactId)
}
export async function sendArtifactDraftCommand(command: ArtifactDraftCommand, workspace: ArtifactWorkspace): Promise<ArtifactDraftView> {
  const target = command.action === 'open' ? undefined : (command.action === 'edit' || command.action === 'resolve') ? command.selection.target : command.target
  const artifactId = command.action === 'open' ? command.artifact_id
    : (command.action === 'edit' || command.action === 'resolve') ? command.selection.target.artifact_id : command.target.artifact_id
  // The transport sends once. A caller retains its local CRDT updates and
  // reconciles uncertain responses; it must not blindly repeat Keeper edits.
  return decode(await post<unknown>(path, command, artifactWorkspaceHeaders(workspace)), artifactId, target)
}
