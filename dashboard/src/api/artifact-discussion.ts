import { v7 as uuidV7 } from 'uuid'
import { ArtifactDiscussionCommandSchema, ArtifactDiscussionRequestSchema, ArtifactThreadSchema,
  sendArtifactDraftCommand, type ArtifactDraftTarget } from './artifact-drafts'
import type { ArtifactDraftView } from './artifact-drafts'
import { sameDraftTarget } from './artifact-draft-live'
import type { ArtifactWorkspace } from './published-artifacts'

export type ArtifactThread = typeof ArtifactThreadSchema.Type
export type ArtifactDiscussionCommand = typeof ArtifactDiscussionCommandSchema.Type
export type ArtifactDiscussionRequest = typeof ArtifactDiscussionRequestSchema.Type
export function artifactDiscussionRequest(command: ArtifactDiscussionCommand): ArtifactDiscussionRequest { return { id: uuidV7(), command } }
export function sendArtifactDiscussion(target: ArtifactDraftTarget, request: ArtifactDiscussionRequest, workspace: ArtifactWorkspace, signal?: AbortSignal) {
  return sendArtifactDraftCommand({ action: 'discuss', target, request }, workspace, signal)
}
function sameCommand(a: ArtifactDiscussionCommand, b: ArtifactDiscussionCommand): boolean {
  switch (a.kind) {
    case 'comment': return b.kind === 'comment' && a.body === b.body && a.quote === b.quote && (a.proposal ?? null) === (b.proposal ?? null)
      && a.position.anchor.length === b.position.anchor.length && a.position.head.length === b.position.head.length
      && a.position.anchor.every((byte, index) => byte === b.position.anchor[index]) && a.position.head.every((byte, index) => byte === b.position.head[index])
    case 'reply': return b.kind === 'reply' && a.thread_id === b.thread_id && a.body === b.body
    case 'resolve': case 'reopen': case 'accept': case 'reject': return a.kind === b.kind && 'thread_id' in b && a.thread_id === b.thread_id
  }
}
export function matchArtifactDiscussionReceipt(view: ArtifactDraftView, target: ArtifactDraftTarget, actor: string, request: ArtifactDiscussionRequest) {
  if (!sameDraftTarget(view.draft.target, target)) throw new Error('요청한 공유 원고와 응답의 문서 또는 세대가 다릅니다.')
  const matches = view.discussion_receipts.filter(event => event.request.id === request.id)
  if (matches.length === 0) return null
  const event = matches[0]!
  if (matches.length !== 1 || event.actor !== actor || !sameCommand(event.request.command, request.command)
    || (request.command.kind === 'accept' ? event.applied === null : event.applied !== null)) {
    throw new Error('이 요청 ID의 처리 기록이 작성자 또는 보낸 내용과 다릅니다. 원고를 보존합니다.')
  }
  return event
}
