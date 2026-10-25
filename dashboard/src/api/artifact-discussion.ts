import { v7 as uuidV7 } from 'uuid'
import { ArtifactDiscussionCommandSchema, ArtifactDiscussionRequestSchema, ArtifactThreadSchema,
  sendArtifactDraftCommand, type ArtifactDraftTarget } from './artifact-drafts'
import type { ArtifactWorkspace } from './published-artifacts'

export type ArtifactThread = typeof ArtifactThreadSchema.Type
export type ArtifactDiscussionCommand = typeof ArtifactDiscussionCommandSchema.Type
export type ArtifactDiscussionRequest = typeof ArtifactDiscussionRequestSchema.Type
export function artifactDiscussionRequest(command: ArtifactDiscussionCommand): ArtifactDiscussionRequest { return { id: uuidV7(), command } }
export function sendArtifactDiscussion(target: ArtifactDraftTarget, request: ArtifactDiscussionRequest, workspace: ArtifactWorkspace) {
  return sendArtifactDraftCommand({ action: 'discuss', target, request }, workspace)
}
