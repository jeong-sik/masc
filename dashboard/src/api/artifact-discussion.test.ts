import { expect, it } from 'vitest'
import { artifactDiscussionRequest, matchArtifactDiscussionReceipt } from './artifact-discussion'
import type { ArtifactDraftView } from './artifact-drafts'
const target = { artifact_id: `artifact-${'d'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
const command = { kind: 'comment' as const, position: { anchor: [1], head: [2] }, quote: '문장', body: '댓글' }
const request = artifactDiscussionRequest(command)
const event = { request, actor: 'human', at: '2026-10-26T02:00:00Z', applied: null }
const view: ArtifactDraftView = { draft: { schema: 'masc.artifact_draft.v2', target, base_revision: 1, base_sha256: 'a'.repeat(64), state: 'AAA=', sequence: 1, updated_by: 'human', updated_at: event.at }, content: '', threads: [], discussion_receipts: [event], selection: null }
it('reconciles the exact actor, request and target, including canonical absent proposal', () => {
  expect(matchArtifactDiscussionReceipt(view, target, 'human', request)).toBe(event)
  expect(matchArtifactDiscussionReceipt({ ...view, discussion_receipts: [{ ...event, request: { ...request, command: { ...command, proposal: null } } }] }, target, 'human', request)).toBeTruthy()
  expect(matchArtifactDiscussionReceipt({ ...view, discussion_receipts: [] }, target, 'human', request)).toBeNull()
})
it('keeps recovery for mismatched authors, reused ids, duplicate receipts and invalid effects', () => {
  for (const changed of [ { ...event, actor: 'other' }, { ...event, request: { ...request, command: { kind: 'reply' as const, thread_id: target.generation, body: '댓글' } } }, { ...event, applied: { anchor: [], head: [] } } ]) {
    expect(() => matchArtifactDiscussionReceipt({ ...view, discussion_receipts: [changed] }, target, 'human', request)).toThrow()
  }
  expect(() => matchArtifactDiscussionReceipt({ ...view, discussion_receipts: [event,event] }, target, 'human', request)).toThrow()
  expect(() => matchArtifactDiscussionReceipt(view, { ...target, generation: '019f0000-0000-7000-8000-000000000001' }, 'human', request)).toThrow()
  const accept = artifactDiscussionRequest({ kind: 'accept', thread_id: target.generation })
  expect(() => matchArtifactDiscussionReceipt({ ...view, discussion_receipts: [{ ...event, request: accept }] }, target, 'human', accept)).toThrow()
})
