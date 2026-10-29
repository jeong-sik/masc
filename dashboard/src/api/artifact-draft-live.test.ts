import { expect, it, vi } from 'vitest'
import { fetchControlPlane } from './core'
import { streamArtifactDraft, type ArtifactDraftLiveFrame } from './artifact-draft-live'
vi.mock('./core', () => ({ fetchControlPlane: vi.fn(), authHeaders: () => ({}), apiRequestErrorFromResponse: vi.fn() }))
it('decodes a full snapshot followed by a cursor-only null document through the SSE reader', async () => {
  const target = { artifact_id: `artifact-${'a'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
  const peer = { session_id: 'connection', actor: 'human', source: { kind: 'dashboard_connection' }, position: null, observed_at: '2026-10-26T08:00:00Z' }
  const first = { schema: 'masc.artifact_draft_live.v1', session_id: peer.session_id, target, peers: [peer], document: {
    draft: { schema: 'masc.artifact_draft.v2', target, base_revision: 1, base_sha256: 'a'.repeat(64), state: 'AAA=', sequence: 0, updated_by: 'writer', updated_at: peer.observed_at }, content: '원고 😀\r\n', threads: [], discussion_receipts: [], selection: null } }
  const position = { anchor: [1, 2], head: [3, 4] }
  const presence = { ...first, document: null, peers: [{ ...peer, position }] }
  const body = [first, presence].map(frame => `event: draft\ndata: ${JSON.stringify(frame)}\n\n`).join('')
  vi.mocked(fetchControlPlane).mockResolvedValue(new Response(body, { headers: { 'content-type': 'text/event-stream', 'x-masc-workspace-read': 'matched-v1' } }))
  const received: ArtifactDraftLiveFrame[] = [], controller = new AbortController()
  await streamArtifactDraft(target, { basePath: '/fixture', mascRoot: '/fixture/.masc' }, frame => {
    received.push(frame); if (received.length === 2) controller.abort()
  }, controller.signal)
  expect(received.map(frame => frame.document)).toEqual([first.document, null])
  expect(received[1]!.peers[0]!.position).toEqual(position)
})
it('refuses a stream without a workspace receipt before applying a frame', async () => {
  const target = { artifact_id: `artifact-${'b'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
  const cancelled=vi.fn()
  const body=new ReadableStream({cancel:cancelled})
  vi.mocked(fetchControlPlane).mockResolvedValue(new Response(body, { headers: { 'content-type': 'text/event-stream' } }))
  const receive=vi.fn()
  await expect(streamArtifactDraft(target,{basePath:'/fixture',mascRoot:'/fixture/.masc'},receive,new AbortController().signal)).rejects.toThrow(/작업 공간 확인 응답/)
  expect(receive).not.toHaveBeenCalled()
  expect(cancelled).toHaveBeenCalledTimes(1)
})
