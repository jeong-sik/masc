import { expect, it, vi } from 'vitest'
import { fetchControlPlane } from './core'
import { streamArtifactDraft, type ArtifactDraftLiveFrame } from './artifact-draft-live'
vi.mock('./core', () => ({ fetchControlPlane: vi.fn(), authHeaders: () => ({}), apiRequestErrorFromResponse: vi.fn() }))
it('decodes a full snapshot followed by a cursor-only null document through the SSE reader', async () => {
  const target = { artifact_id: `artifact-${'a'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
  const peer = { session_id: 'connection', actor: 'human', source: { kind: 'dashboard_connection' }, position: null, observed_at: '2026-10-26T08:00:00Z' }
  const first = { schema: 'masc.artifact_draft_live.v1', session_id: peer.session_id, target, peers: [peer], document: {
    draft: { schema: 'masc.artifact_draft.v1', target, base_revision: 1, base_sha256: 'a'.repeat(64), state: 'AAA=', sequence: 0, updated_by: 'writer', updated_at: peer.observed_at }, content: '원고 😀\r\n', selection: null } }
  const position = { anchor: [1, 2], head: [3, 4] }
  const presence = { ...first, document: null, peers: [{ ...peer, position }] }
  const body = [first, presence].map(frame => `event: draft\ndata: ${JSON.stringify(frame)}\n\n`).join('')
  vi.mocked(fetchControlPlane).mockResolvedValue(new Response(body, { headers: { 'content-type': 'text/event-stream' } }))
  const received: ArtifactDraftLiveFrame[] = [], controller = new AbortController()
  await streamArtifactDraft(target, { basePath: '/fixture', mascRoot: '/fixture/.masc' }, frame => {
    received.push(frame); if (received.length === 2) controller.abort()
  }, controller.signal)
  expect(received.map(frame => frame.document)).toEqual([first.document, null])
  expect(received[1]!.peers[0]!.position).toEqual(position)
})
