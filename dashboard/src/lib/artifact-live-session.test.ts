import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { ArtifactLiveSession, draftBase64, draftBytes } from './artifact-live-session'
import { seedSharedDocument, sharedState, sharedSource, selectSharedSource } from './artifact-shared-document'
import { sendArtifactDraftCommand, type ArtifactDraftView } from '../api/artifact-drafts'
import { streamArtifactDraft, sendArtifactPresence, type ArtifactDraftLiveFrame } from '../api/artifact-draft-live'
vi.mock('../api/artifact-drafts', () => ({ sendArtifactDraftCommand: vi.fn() }))
vi.mock('../api/artifact-draft-live', () => ({ streamArtifactDraft: vi.fn(), sendArtifactPresence: vi.fn() }))
const target = { artifact_id: `artifact-${'a'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
const workspace = { basePath: '/fixture', mascRoot: '/fixture/.masc' }, initial = '원고 😀\r\n마지막\r\n'
let authority: Y.Doc, view: ArtifactDraftView, receivers: ((frame: ArtifactDraftLiveFrame) => void)[], sessions: ArtifactLiveSession[]
const snapshot = (): ArtifactDraftView => ({ ...view, content: sharedSource(authority), draft: { ...view.draft, state: draftBase64(sharedState(authority)) } })
const frame = (index: number): ArtifactDraftLiveFrame => ({ schema: 'masc.artifact_draft_live.v1', target, session_id: `session-${index}`, document: snapshot(),
  peers: [{ session_id: `session-${index}`, actor: 'human', position: null, observed_at: '2026-10-25T13:00:00Z' }] })
function open(isCurrent = () => true) { const session = new ArtifactLiveSession(snapshot(), workspace, () => {}, isCurrent); sessions.push(session); void session.connect(); return session }
async function commit(command: Parameters<typeof sendArtifactDraftCommand>[0]) {
  if (command.action !== 'merge') throw new Error('only merge')
  command.updates.forEach(update => Y.applyUpdate(authority, draftBytes(update)))
  view = { ...snapshot(), draft: { ...snapshot().draft, sequence: view.draft.sequence + 1 } }
  receivers.forEach((receive, index) => receive(frame(index)))
  return snapshot()
}
beforeEach(() => {
  sessions = []; receivers = []; authority = seedSharedDocument(initial)
  view = { draft: { schema: 'masc.artifact_draft.v1', target, base_revision: 1, base_sha256: 'b'.repeat(64), state: draftBase64(sharedState(authority)), sequence: 0, updated_by: 'publisher', updated_at: '2026-10-25T13:00:00Z' }, content: initial, selection: null }
  vi.mocked(sendArtifactPresence).mockReset().mockResolvedValue()
  vi.mocked(sendArtifactDraftCommand).mockReset().mockImplementation(commit)
  vi.mocked(streamArtifactDraft).mockReset().mockImplementation(async (_, __, receive, signal) => {
    const index = receivers.push(receive) - 1; receive(frame(index))
    await new Promise<void>(resolve => signal.addEventListener('abort', () => resolve(), { once: true }))
  })
})
afterEach(() => { sessions.forEach(session => session.dispose()); authority.destroy() })
describe('live shared drafts', () => {
  it('merges concurrent inputs preserving CRLF, emoji and both inserts', async () => {
    const gates: (() => void)[] = []
    vi.mocked(sendArtifactDraftCommand).mockImplementation(async command => { await new Promise<void>(resolve => gates.push(resolve)); return commit(command) })
    const a = open(), b = open()
    a.doc.getText('content').insert(0, 'A '); b.doc.getText('content').insert(0, 'B ')
    expect(gates).toHaveLength(2); gates[1]!(); gates[0]!()
    await vi.waitFor(() => expect(a.snapshot.pending || b.snapshot.pending).toBe(false))
    expect(a.content).toBe(b.content); expect(a.content.endsWith(initial)).toBe(true)
    expect(a.content).toContain('A '); expect(a.content).toContain('B ')
    expect(sharedSource(authority)).toBe(a.content)
  })
  it('retains ambiguous saves and retries only on explicit reconnection', async () => {
    vi.mocked(sendArtifactDraftCommand).mockImplementationOnce(async command => { await commit(command); throw new Error('response lost') }).mockImplementation(commit)
    const a = open(); a.doc.getText('content').insert(0, '보관 ')
    await vi.waitFor(() => expect(a.snapshot.connection).toBe('disconnected'))
    expect(a.content).toBe(`보관 ${initial}`); expect(a.snapshot.pending).toBe(true); expect(a.snapshot.peers).toEqual([])
    expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1)
    void a.connect()
    await vi.waitFor(() => expect(a.snapshot.pending).toBe(false))
    expect(a.content).toBe(`보관 ${initial}`); expect(sharedSource(authority)).toBe(a.content)
    expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(2)
  })
  it('waits for durable insert before sending its relative cursor and leaves on dispose', async () => {
    let release!: () => void
    vi.mocked(sendArtifactDraftCommand).mockImplementation(async command => { await new Promise<void>(resolve => { release = resolve }); return commit(command) })
    const a = open()
    await vi.waitFor(() => expect(sendArtifactPresence).toHaveBeenCalledTimes(1)); vi.mocked(sendArtifactPresence).mockClear()
    a.doc.getText('content').insert(0, '새 글 '); a.select({ anchor: 0, head: 3 })
    expect(sendArtifactPresence).not.toHaveBeenCalled(); release()
    await vi.waitFor(() => expect(sendArtifactPresence).toHaveBeenCalledTimes(1))
    expect(vi.mocked(sendArtifactPresence).mock.calls[0]![3]).toEqual({ action: 'position', position: selectSharedSource(a.doc, { anchor: 0, head: 3 }) })
    a.dispose(); sessions = []
    expect(vi.mocked(sendArtifactPresence).mock.lastCall?.[3]).toEqual({ action: 'leave' })
  })
  it('keeps local changes without sending under a changed workspace or credential', () => {
    let current = true; const a = open(() => current); current = false
    a.doc.getText('content').insert(0, 'local ')
    expect(sendArtifactDraftCommand).not.toHaveBeenCalled(); expect(a.content).toBe(`local ${initial}`); expect(a.snapshot.pending).toBe(true)
  })
})
