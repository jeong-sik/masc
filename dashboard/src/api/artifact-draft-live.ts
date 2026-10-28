import { Schema } from 'effect'
import { authHeaders, fetchControlPlane, apiRequestErrorFromResponse } from './core'
import { ArtifactDraftTargetSchema, ArtifactDraftPositionSchema, ArtifactDraftViewSchema, type ArtifactDraftTarget } from './artifact-drafts'
import { artifactWorkspaceHeaders, type ArtifactWorkspace } from './published-artifacts'
import { readSse } from '../lib/sse-reader'

export const ArtifactDraftLiveSchema = Schema.Struct({
  schema: Schema.Literal('masc.artifact_draft_live.v1'),
  session_id: Schema.String.pipe(Schema.nonEmptyString()), target: ArtifactDraftTargetSchema,
  peers: Schema.Array(Schema.Struct({ session_id: Schema.String.pipe(Schema.nonEmptyString()),
    actor: Schema.String.pipe(Schema.nonEmptyString()), source: Schema.Union(
      Schema.Struct({ kind: Schema.Literal('dashboard_connection') }),
      Schema.Struct({ kind: Schema.Literal('keeper_turn'), turn_ref: Schema.String.pipe(Schema.nonEmptyString()) })), position: Schema.NullOr(ArtifactDraftPositionSchema),
    observed_at: Schema.String.pipe(Schema.nonEmptyString()) })),
  document: Schema.NullOr(ArtifactDraftViewSchema),
})
export type ArtifactDraftLiveFrame = typeof ArtifactDraftLiveSchema.Type
export type ArtifactDraftPeer = ArtifactDraftLiveFrame['peers'][number]
export type ArtifactDraftPosition = typeof ArtifactDraftPositionSchema.Type
export const sameDraftTarget = (a: ArtifactDraftTarget, b: ArtifactDraftTarget) => a.artifact_id === b.artifact_id && a.generation === b.generation
export async function streamArtifactDraft(target: ArtifactDraftTarget, workspace: ArtifactWorkspace,
  onFrame: (frame: ArtifactDraftLiveFrame) => void, signal: AbortSignal): Promise<void> {
  const path = `/api/v1/artifact-draft-events/${encodeURIComponent(target.artifact_id)}?generation=${encodeURIComponent(target.generation)}`
  const response = await fetchControlPlane(path, { signal,
    headers: { ...authHeaders(), ...artifactWorkspaceHeaders(workspace), Accept: 'text/event-stream' } })
  if (!response.ok) throw await apiRequestErrorFromResponse('GET', path, response)
  if (!response.body || !response.headers.get('content-type')?.startsWith('text/event-stream')) throw new Error('공동 편집 연결을 열지 못했습니다.')
  await readSse(response.body, (event, data) => {
    if (event !== 'draft') return
    const frame = Schema.decodeUnknownSync(ArtifactDraftLiveSchema)(JSON.parse(data))
    if (!sameDraftTarget(frame.target, target) || (frame.document && !sameDraftTarget(frame.document.draft.target, target))
      || !frame.peers.some(peer => peer.session_id === frame.session_id)) throw new Error('공동 편집 응답의 문서 또는 세션이 다릅니다.')
    onFrame(frame)
  })
  if (!signal.aborted) throw new Error('공동 편집 연결이 끊겼습니다. 원고를 보관하고 다시 연결해 주세요.')
}
export async function sendArtifactPresence(target: ArtifactDraftTarget, sessionId: string, workspace: ArtifactWorkspace,
  command: { action: 'position'; position: ArtifactDraftPosition | null } | { action: 'leave' }, signal?: AbortSignal): Promise<void> {
  const path = '/api/v1/artifact-draft-presence'
  const response = await fetchControlPlane(path, { method: 'POST', keepalive: command.action === 'leave', signal,
    headers: { ...authHeaders(), ...artifactWorkspaceHeaders(workspace), 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...command, target, session_id: sessionId }) })
  if (!response.ok) throw await apiRequestErrorFromResponse('POST', path, response)
}
