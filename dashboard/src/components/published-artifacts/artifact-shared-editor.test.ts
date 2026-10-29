import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { EditorView } from '@codemirror/view'
import { ArtifactSharedEditor, type ArtifactSharedCloseRequest } from './artifact-shared-editor'
import { ArtifactReader } from './artifact-reader'
import type { ArtifactDraftSnapshot } from './artifact-composer'
import { ApiRequestError } from '../../api/core'
import { seedSharedDocument, sharedSource, sharedState, selectSharedSource } from '../../lib/artifact-shared-document'
import { draftBase64, draftBytes } from '../../lib/artifact-live-session'
import type { ArtifactDraftView } from '../../api/artifact-drafts'
import { checkpointArtifactDraft, sendArtifactDraftCommand } from '../../api/artifact-drafts'
import { streamArtifactDraft, sendArtifactPresence, type ArtifactDraftLiveFrame } from '../../api/artifact-draft-live'
import { captureArtifactWorkspace, fetchWorkspacePublishedArtifact, publishArtifact, readPublishedDraft, type ArtifactDocument } from '../../api/published-artifacts'
import { artifactDraftRecoveries, discardArtifactDraftRecovery } from '../../lib/artifact-draft-recovery'
import { discussionLocals, discardDiscussionLocal, retainDiscussionLocal } from '../../lib/artifact-discussion-local'
vi.mock('../../api/published-artifacts', async original => ({ ...await original<typeof import('../../api/published-artifacts')>(),
  captureArtifactWorkspace: vi.fn(), fetchWorkspacePublishedArtifact: vi.fn(), publishArtifact: vi.fn(), readPublishedDraft: vi.fn() }))
vi.mock('../../api/artifact-drafts', async original => ({ ...await original<typeof import('../../api/artifact-drafts')>(),
  sendArtifactDraftCommand: vi.fn(), checkpointArtifactDraft: vi.fn() }))
vi.mock('../../api/artifact-draft-live', async original => ({ ...await original<typeof import('../../api/artifact-draft-live')>(),
  streamArtifactDraft: vi.fn(), sendArtifactPresence: vi.fn() }))
vi.mock('../../router', () => ({ navigate: vi.fn() }))
vi.mock('../common/markdown', () => ({ Markdown: ({ text }: { text: string }) => html`<div>${text}</div>` }))
const workspace = { basePath: '/fixture', mascRoot: '/separate-runtime-root' }
const documents: Y.Doc[] = []
const retainedDrafts = new Map<object, ArtifactDraftSnapshot>()
const draftRetention = {
  remember: (snapshot: ArtifactDraftSnapshot) => retainedDrafts.set(snapshot.identity, snapshot),
  forget: (identity: object) => retainedDrafts.delete(identity),
}
beforeEach(() => {
  retainedDrafts.clear()
  vi.mocked(captureArtifactWorkspace).mockReset().mockResolvedValue(workspace)
  vi.mocked(fetchWorkspacePublishedArtifact).mockReset(); vi.mocked(publishArtifact).mockReset(); vi.mocked(readPublishedDraft).mockReset()
  vi.mocked(sendArtifactDraftCommand).mockReset(); vi.mocked(checkpointArtifactDraft).mockReset(); vi.mocked(streamArtifactDraft).mockReset()
  vi.mocked(sendArtifactPresence).mockReset().mockResolvedValue()
})
afterEach(() => {
  cleanup()
  for (const char of ['a', 'b', 'c']) {
    for (const record of artifactDraftRecoveries(workspace, `artifact-${char.repeat(32)}`)) discardArtifactDraftRecovery(record)
    for (const record of discussionLocals(workspace, `artifact-${char.repeat(32)}`)) discardDiscussionLocal(record)
  }
  for (const doc of documents.splice(0)) doc.destroy()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

function fixture(char: string,source='shared source\r\n한글 😀\r\n') {
  const authority = seedSharedDocument(source); documents.push(authority)
  const target = { artifact_id: `artifact-${char.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
  let sequence = 0
  const snapshot = (): ArtifactDraftView => ({ content: sharedSource(authority), threads: [], discussion_receipts: [], selection: null, draft: {
    schema: 'masc.artifact_draft.v2', target, state: draftBase64(sharedState(authority)), base_revision: 1,
    base_sha256: 'a'.repeat(64), sequence, updated_by: 'human', updated_at: '2026-10-25T13:00:00Z',
  } })
  const frame = (): ArtifactDraftLiveFrame => ({ schema: 'masc.artifact_draft_live.v1', target, session_id: 'self', peers: [{session_id:'self',actor:'human',source:{kind:'dashboard_connection'},position:null,observed_at:'2026-10-26T03:00:00Z'}], document: snapshot() })
  vi.mocked(streamArtifactDraft).mockImplementation(async (_, __, callback, signal) => {
    callback(frame())
    await new Promise<void>(resolve => signal.addEventListener('abort', () => resolve(), { once: true }))
  })
  const merge = (updates: readonly string[]) => { updates.forEach(update => Y.applyUpdate(authority, draftBytes(update))); sequence++; return snapshot() }
  const artifact = { id: target.artifact_id, revision: 1, title: 'original title', summary: 'original summary', format: 'markdown' as const,
    author: 'publisher', created_at: '2026-10-25T13:00:00Z', task_id: null, goal_id: null, body: { _blob: { sha256: 'a'.repeat(64) } }, url: '/dashboard' }
  const doc: ArtifactDocument = { artifact, content: sharedSource(authority), revisions: [artifact] }
  vi.mocked(checkpointArtifactDraft).mockImplementation(async (requestedTarget, expectedSequence, publication) => {
    const document = snapshot()
    return { checkpoint: 'checkpointed', document: { ...document, draft: { ...document.draft, target: requestedTarget,
      base_revision: publication.artifact.revision, base_sha256: publication.artifact.body._blob.sha256, sequence: expectedSequence + 1 } } }
  })
  const mount = (isCurrent = () => true, onPublished = vi.fn(), openingDoc:ArtifactDocument=doc, onMutation=vi.fn()) => render(html`<${ArtifactSharedEditor} draftRetention=${draftRetention} doc=${openingDoc} workspaceRoot="/fixture" capturedWorkspace=${workspace}
    isCurrent=${isCurrent} onCloseRequest=${() => {}} onMutation=${onMutation} onPublished=${onPublished} onClose=${() => {}} />`)
  const editor = async () => {
    fireEvent.click(await screen.findByRole('button',{name:'원본 편집'}))
    return EditorView.findFromDOM(await screen.findByRole('textbox', { name: '공동 편집 원고' }))!
  }
  return { authority, target, snapshot, merge, doc, mount, editor }
}
it('chooses the shared draft base format rather than a newer publication format',async()=>{
  const f=fixture('a'),latest:ArtifactDocument={...f.doc,artifact:{...f.doc.artifact,revision:2,format:'html'}}
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  f.mount(()=>true,vi.fn(),latest)
  await screen.findByRole('region',{name:'Markdown 문장 편집'})
  expect(screen.queryByRole('region',{name:'HTML 문장 편집'})).toBeNull()
  expect(fetchWorkspacePublishedArtifact).toHaveBeenCalledWith(f.target.artifact_id,'1',workspace,expect.any(AbortSignal))
})
it('refuses a publication that does not match the shared draft base before opening either editor',async()=>{
  const f=fixture('b'),latest:ArtifactDocument={...f.doc,artifact:{...f.doc.artifact,revision:2,format:'html'}}
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue({...f.doc,artifact:{...f.doc.artifact,body:{_blob:{sha256:'b'.repeat(64)}}}})
  f.mount(()=>true,vi.fn(),latest)
  await screen.findByText('공유 원고의 게시 기준과 원본 문서가 다릅니다.')
  expect(streamArtifactDraft).not.toHaveBeenCalled()
  expect(screen.queryByTitle('문장을 눌러 편집하는 미리보기')).toBeNull()
})
it('comments on a rendered Markdown range with a raw Markdown proposal and leaves the source unchanged',async()=>{
  const source='# 제목\r\n\r\n**alpha**\r\n',f=fixture('a',source)
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command=>command.action==='discuss'?{
    ...f.snapshot(),discussion_receipts:[{request:command.request,actor:'human',at:'2026-10-26T03:00:00Z',applied:null}],
  }:f.snapshot())
  f.mount()
  const iframe=await screen.findByTitle('문장을 눌러 편집하는 미리보기') as HTMLIFrameElement
  await waitFor(()=>expect((screen.getByRole('button',{name:'선택한 원문에 댓글'}) as HTMLButtonElement).disabled).toBe(false))
  const token=new DOMParser().parseFromString(iframe.srcdoc,'text/html').querySelector('script')!.getAttribute('nonce')
  fireEvent(window,new MessageEvent('message',{source:iframe.contentWindow,data:{type:'masc.artifact.text.selected.v1',token,id:1}}))
  await screen.findByLabelText('선택한 문장')
  fireEvent.click(screen.getByRole('button',{name:'선택한 원문에 댓글'}))
  fireEvent.input(screen.getByLabelText('댓글 내용'),{target:{value:'이 부분을 바꿔요'}})
  fireEvent.click(screen.getByRole('checkbox'))
  fireEvent.input(screen.getByLabelText('변경 제안 내용'),{target:{value:'**제안** &amp; 글'}})
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  await waitFor(()=>expect(vi.mocked(sendArtifactDraftCommand).mock.calls.some(([c])=>c.action==='discuss')).toBe(true))
  const call=vi.mocked(sendArtifactDraftCommand).mock.calls.find(([c])=>c.action==='discuss')![0]
  expect(call.action==='discuss'&&call.request.command).toMatchObject({kind:'comment',quote:'alpha',body:'이 부분을 바꿔요',proposal:'**제안** &amp; 글'})
  expect(sharedSource(f.authority)).toBe(source)
})
it('binds actual editor transactions to exact CRLF source, handles remote edits and removes departed peer cursors', async () => {
  const authority = seedSharedDocument('원고 😀\r\n다음\r\n')
  const target = { artifact_id: `artifact-${'a'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
  let sequence = 0, receive!: (frame: ArtifactDraftLiveFrame) => void
  let peers: ArtifactDraftLiveFrame['peers'] = [{ session_id: 'self', actor: 'human', source: { kind: 'dashboard_connection' }, position: null, observed_at: '2026-10-25T13:00:00Z' }]
  const snapshot = (): ArtifactDraftView => ({ content: sharedSource(authority), threads: [], discussion_receipts: [], selection: null, draft: { schema: 'masc.artifact_draft.v2', target,
    state: draftBase64(sharedState(authority)), base_revision: 1, base_sha256: 'a'.repeat(64), sequence, updated_by: 'human', updated_at: '2026-10-25T13:00:00Z' } })
  const frame = () => ({ schema: 'masc.artifact_draft_live.v1' as const, target, session_id: 'self', peers, document: snapshot() })
  vi.mocked(sendArtifactPresence).mockResolvedValue()
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command => {
    if (command.action === 'merge') { command.updates.forEach(update => Y.applyUpdate(authority, draftBytes(update))); sequence++; receive(frame()) }
    return snapshot()
  })
  vi.mocked(streamArtifactDraft).mockImplementation(async (_, __, callback, signal) => {
    receive = callback; callback(frame())
    await new Promise<void>(resolve => signal.addEventListener('abort', () => resolve(), { once: true }))
  })
  const artifact = { id: target.artifact_id, revision: 1, title: '공동 원고', summary: '검증', format: 'markdown' as const, author: 'publisher',
    created_at: '2026-10-25T13:00:00Z', task_id: null, goal_id: null, body: { _blob: { sha256: 'a'.repeat(64) } }, url: '/dashboard' }
  render(html`<${ArtifactSharedEditor} draftRetention=${draftRetention} doc=${{ artifact, content: sharedSource(authority), revisions: [artifact] }} workspaceRoot="/fixture" capturedWorkspace=${workspace}
    isCurrent=${() => true} onCloseRequest=${() => {}} onMutation=${() => {}} onPublished=${() => {}} onClose=${() => {}} />`)
  fireEvent.click(await screen.findByRole('button',{name:'원본 편집'}))
  const editable = await screen.findByRole('textbox', { name: '공동 편집 원고' })
  const editor = EditorView.findFromDOM(editable)!
  expect(editor.state.doc.toString()).toBe('원고 😀\r\n다음\r\n')
  editor.dispatch({ changes: { from: 0, insert: '내 글 ' } })
  await waitFor(() => expect(sharedSource(authority)).toBe('내 글 원고 😀\r\n다음\r\n'))
  authority.getText('content').insert(authority.getText('content').length, '상대 글\n'); sequence++
  peers = [...peers, { session_id: 'other', actor: 'keeper-fixture', source: { kind: 'keeper_turn', turn_ref: 'fixture#1' }, position: selectSharedSource(authority, { anchor: 0, head: 3 }), observed_at: '2026-10-25T13:01:00Z' }]
  receive(frame())
  await waitFor(() => expect(editor.state.doc.toString()).toBe(sharedSource(authority)))
  await screen.findByLabelText('keeper-fixture의 편집 위치')
  peers = peers.slice(0, 1); receive(frame())
  await waitFor(() => expect(screen.queryByLabelText('keeper-fixture의 편집 위치')).toBeNull())
  cleanup(); authority.destroy()
})

it('publishes again only after explicit latest-version comparison, preserving its metadata and the original canonical workspace', async () => {
  const f = fixture('b'), onPublished = vi.fn()
  let latest = f.doc
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command => command.action === 'merge' ? f.merge(command.updates) : f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockImplementation(async () => latest)
  vi.mocked(publishArtifact).mockImplementation(async request => {
    const artifact = { ...latest.artifact, ...request, revision: latest.artifact.revision + 1,
      task_id: request.task_id ?? null, goal_id: request.goal_id ?? null }
    latest = { artifact, content: request.content, revisions: [artifact] }
    return { schema: 'masc.published_artifact.v1', artifact, revision_url: '/dashboard' }
  })
  vi.mocked(readPublishedDraft).mockImplementation(async () => latest)
  f.mount(() => true, onPublished)
  const editor = await f.editor()
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  const save = await screen.findByRole('button', { name: '새 버전 저장' })
  await waitFor(() => expect((save as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(save)
  await waitFor(() => expect(onPublished).toHaveBeenCalledTimes(1))
  expect(vi.mocked(publishArtifact).mock.calls[0]![0].expected_revision).toBe(1)
  expect(checkpointArtifactDraft).toHaveBeenCalledTimes(1)
  expect(vi.mocked(checkpointArtifactDraft).mock.calls[0]![0]).toEqual(f.target)
  expect(vi.mocked(checkpointArtifactDraft).mock.calls[0]![1]).toBe(0)
  expect(vi.mocked(checkpointArtifactDraft).mock.calls[0]![3]).toEqual(workspace)

  // Another publisher changed both content and metadata after our first post.
  latest = { ...latest, artifact: { ...latest.artifact, revision: 3, title: 'latest title', summary: 'latest summary',
    format: 'html', task_id: 'task-latest', goal_id: 'goal-latest' }, content: '<p>external publication</p>' }
  const frozen = editor.state.doc.toString()
  vi.mocked(captureArtifactWorkspace).mockResolvedValue({ basePath: '/fixture', mascRoot: '/replacement-runtime-root' })
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  const comparison = within(await screen.findByRole('region', { name: '최신 게시물과 원고 비교' }))
  expect(comparison.getByText('<p>external publication</p>')).toBeTruthy()
  expect(comparison.getByText(frozen, { normalizer: value => value })).toBeTruthy()
  expect(screen.queryByLabelText('문서 본문')).toBeNull()
  expect(publishArtifact).toHaveBeenCalledTimes(1)
  editor.dispatch({ changes: { from: 0, insert: 'later shared edit ' } })
  await waitFor(() => expect(sharedSource(f.authority)).toBe(`later shared edit ${frozen}`))
  fireEvent.click(comparison.getByRole('button', { name: '이 원고로 새 버전 준비' }))
  expect((await screen.findByLabelText('문서 본문') as HTMLTextAreaElement).value).toBe(frozen)
  expect((screen.getByLabelText('문서 제목') as HTMLInputElement).value).toBe('latest title')
  expect((screen.getByLabelText('문서 요약') as HTMLInputElement).value).toBe('latest summary')
  expect((screen.getByLabelText('문서 형식') as HTMLSelectElement).value).toBe('html')
  const secondSave = screen.getByRole('button', { name: '새 버전 저장' })
  await waitFor(() => expect((secondSave as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(secondSave)
  await waitFor(() => expect(onPublished).toHaveBeenCalledTimes(2))
  expect(vi.mocked(publishArtifact).mock.calls[1]).toEqual([{
    id: f.target.artifact_id, expected_revision: 3, title: 'latest title', summary: 'latest summary', format: 'html',
    content: frozen, task_id: 'task-latest', goal_id: 'goal-latest',
  }, workspace])
  expect(fetchWorkspacePublishedArtifact).toHaveBeenLastCalledWith(f.target.artifact_id, undefined, workspace)
  expect(captureArtifactWorkspace).not.toHaveBeenCalled()
  expect(checkpointArtifactDraft).toHaveBeenCalledTimes(2)
  // The later edit must not change the sequence attached to the frozen publication.
  expect(vi.mocked(checkpointArtifactDraft).mock.calls[1]![1]).toBe(1)
  expect(retainedDrafts.size).toBe(0)
  expect(editor.state.doc.toString()).toBe(`later shared edit ${frozen}`)
})

it('keeps later unsaved shared edits open after a frozen publication succeeds', async () => {
  const f = fixture('a'), onPublished = vi.fn()
  let finishMerge!: () => void
  vi.mocked(sendArtifactDraftCommand).mockImplementation(command => command.action === 'merge'
    ? new Promise(resolve => { finishMerge = () => resolve(f.merge(command.updates)) })
    : Promise.resolve(f.snapshot()))
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  const artifact = { ...f.doc.artifact, revision: 2 }
  vi.mocked(publishArtifact).mockResolvedValue({ schema: 'masc.published_artifact.v1', artifact, revision_url: '/revision' })
  vi.mocked(readPublishedDraft).mockResolvedValue({ ...f.doc, artifact })
  f.mount(() => true, onPublished)
  const editor = await f.editor()
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  const save = await screen.findByRole('button', { name: '새 버전 저장' })
  editor.dispatch({ changes: { from: 0, insert: 'later local edit ' } })
  await waitFor(() => expect(vi.mocked(sendArtifactDraftCommand).mock.calls.some(([command]) => command.action === 'merge')).toBe(true))
  fireEvent.click(save)
  const viewPublished = await screen.findByRole('button', { name: '게시한 버전 보기' })
  expect(onPublished).not.toHaveBeenCalled()
  expect(editor.state.doc.toString()).toContain('later local edit ')
  const confirm = vi.fn(() => false); vi.stubGlobal('confirm', confirm)
  fireEvent.click(viewPublished)
  expect(confirm).toHaveBeenCalledTimes(1)
  expect(onPublished).not.toHaveBeenCalled()
  finishMerge()
  await screen.findByText(/공동 편집을 계속하거나 게시한 버전을 볼 수 있습니다/)
  fireEvent.click(viewPublished)
  expect(onPublished).toHaveBeenCalledTimes(1)
})

it.each(['sentence', 'comment'] as const)('does not navigate when %s input races publication readback', async kind => {
  const f = fixture('b', '# alpha\n'), onPublished = vi.fn()
  let finishRead!: (value: ArtifactDocument) => void
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  const artifact = { ...f.doc.artifact, revision: 2 }
  vi.mocked(publishArtifact).mockResolvedValue({ schema: 'masc.published_artifact.v1', artifact, revision_url: '/revision' })
  vi.mocked(readPublishedDraft).mockImplementation(() => new Promise(resolve => { finishRead = resolve }))
  f.mount(() => true, onPublished)
  const iframe = await screen.findByTitle('문장을 눌러 편집하는 미리보기') as HTMLIFrameElement
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  const save = await screen.findByRole('button', { name: '새 버전 저장' }) as HTMLButtonElement
  await waitFor(() => expect(save.disabled).toBe(false))
  fireEvent.click(save)
  await waitFor(() => expect(readPublishedDraft).toHaveBeenCalledTimes(1))
  const token = new DOMParser().parseFromString(iframe.srcdoc, 'text/html').querySelector('script')!.getAttribute('nonce')
  fireEvent(window, new MessageEvent('message', { source: iframe.contentWindow, data: { type: 'masc.artifact.text.selected.v1', token, id: 0 } }))
  await screen.findByLabelText('선택한 문장')
  if (kind === 'comment') fireEvent.click(await screen.findByRole('button', { name: '선택한 원문에 댓글' }))
  const input = screen.getByLabelText(kind === 'sentence' ? '선택한 문장' : '댓글 내용')
  await act(async () => {
    fireEvent.input(input, { target: { value: 'not yet submitted' } })
    finishRead({ ...f.doc, artifact })
    await Promise.resolve()
  })
  await screen.findByRole('button', { name: '게시한 버전 보기' })
  expect(onPublished).not.toHaveBeenCalled()
  expect((input as HTMLTextAreaElement).value).toBe('not yet submitted')
})

it('keeps an unconfirmed discussion request visible when publication finishes', async () => {
  const f = fixture('c', '# alpha\n'), onPublished = vi.fn()
  let finishRead!: (value: ArtifactDocument) => void
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command => {
    if (command.action === 'discuss') throw new ApiRequestError({ method: 'POST', path: '/discussion', status: 503, detail: 'response lost' })
    return f.snapshot()
  })
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  const artifact = { ...f.doc.artifact, revision: 2 }
  vi.mocked(publishArtifact).mockResolvedValue({ schema: 'masc.published_artifact.v1', artifact, revision_url: '/revision' })
  vi.mocked(readPublishedDraft).mockImplementation(() => new Promise(resolve => { finishRead = resolve }))
  f.mount(() => true, onPublished)
  const iframe = await screen.findByTitle('문장을 눌러 편집하는 미리보기') as HTMLIFrameElement
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  const save = await screen.findByRole('button', { name: '새 버전 저장' }) as HTMLButtonElement
  await waitFor(() => expect(save.disabled).toBe(false))
  fireEvent.click(save)
  await waitFor(() => expect(readPublishedDraft).toHaveBeenCalledTimes(1))
  const token = new DOMParser().parseFromString(iframe.srcdoc, 'text/html').querySelector('script')!.getAttribute('nonce')
  fireEvent(window, new MessageEvent('message', { source: iframe.contentWindow, data: { type: 'masc.artifact.text.selected.v1', token, id: 0 } }))
  await screen.findByLabelText('선택한 문장')
  fireEvent.click(await screen.findByRole('button', { name: '선택한 원문에 댓글' }))
  fireEvent.input(screen.getByLabelText('댓글 내용'), { target: { value: 'recover this comment' } })
  fireEvent.click(screen.getByRole('button', { name: '댓글 보내기' }))
  await screen.findByRole('button', { name: '전송 결과 확인' })
  await act(() => finishRead({ ...f.doc, artifact }))
  await screen.findByRole('button', { name: '게시한 버전 보기' })
  expect(onPublished).not.toHaveBeenCalled()
  expect(discussionLocals(workspace, f.target.artifact_id)).toHaveLength(1)
  expect(screen.getByRole('button', { name: '전송 결과 확인' })).toBeTruthy()
})

it('checks saved discussion records again before navigating after publication', async () => {
  const f = fixture('c'), onPublished = vi.fn()
  let finishRead!: (value: ArtifactDocument) => void
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  const artifact = { ...f.doc.artifact, revision: 2 }
  vi.mocked(publishArtifact).mockResolvedValue({ schema: 'masc.published_artifact.v1', artifact, revision_url: '/revision' })
  vi.mocked(readPublishedDraft).mockImplementation(() => new Promise(resolve => { finishRead = resolve }))
  f.mount(() => true, onPublished)
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  const save = await screen.findByRole('button', { name: '새 버전 저장' }) as HTMLButtonElement
  await waitFor(() => expect(save.disabled).toBe(false))
  fireEvent.click(save)
  await waitFor(() => expect(readPublishedDraft).toHaveBeenCalledTimes(1))
  retainDiscussionLocal(crypto.randomUUID(), workspace, f.target, 'human', { kind: 'input', input: {
    kind: 'reply', operationId: f.target.generation, threadId: f.target.generation, body: 'recover later' } })
  await act(() => finishRead({ ...f.doc, artifact }))
  await screen.findByRole('button', { name: '게시한 버전 보기' })
  expect(onPublished).not.toHaveBeenCalled()
})

it('can prepare a new publication after a cached page is restored and the user reconnects', async () => {
  const f = fixture('a')
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  f.mount()
  await f.editor()
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent(window, new Event('pagehide'))
  fireEvent(window, new Event('pageshow'))
  const reconnect = screen.queryByRole('button', { name: '다시 연결' })
  if (reconnect) fireEvent.click(reconnect)
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  await waitFor(() => expect(fetchWorkspacePublishedArtifact).toHaveBeenCalledTimes(1))
  await screen.findByRole('button', { name: '새 버전 저장' })
})

it('keeps restored offline edits recoverable until the user reconnects', async () => {
  const f = fixture('b')
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command => command.action === 'merge' ? f.merge(command.updates) : f.snapshot())
  f.mount()
  const editor = await f.editor(), original = editor.state.doc.toString()
  fireEvent(window, new Event('pagehide')); fireEvent(window, new Event('pageshow'))
  editor.dispatch({ changes: { from: 0, insert: 'offline ' } })
  expect(editor.state.doc.toString()).toBe(`offline ${original}`)
  expect(sharedSource(f.authority)).toBe(original)
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1)
  expect(artifactDraftRecoveries(workspace, f.target.artifact_id)[0]?.persisted).toBe(true)
  fireEvent.click(await screen.findByRole('button', { name: '다시 연결' }))
  await waitFor(() => expect(sharedSource(f.authority)).toBe(`offline ${original}`))
  await waitFor(() => expect(artifactDraftRecoveries(workspace, f.target.artifact_id)).toHaveLength(0))
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(2)
})

it('does not replay an interrupted open and only reopens on explicit request', async () => {
  const f = fixture('b')
  let finishOpen!: (value: ArtifactDraftView) => void
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
    .mockImplementationOnce(() => new Promise(resolve => { finishOpen = resolve }))
  f.mount()
  await waitFor(() => expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1))
  fireEvent(window, new Event('pagehide')); fireEvent(window, new Event('pageshow'))
  finishOpen(f.snapshot())
  const reopen = await screen.findByRole('button', { name: '공동 편집 다시 열기' })
  expect(streamArtifactDraft).not.toHaveBeenCalled()
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1)
  fireEvent.click(reopen)
  await waitFor(() => expect(streamArtifactDraft).toHaveBeenCalledTimes(1))
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(2)
})

it('does not join a draft from a base read started before pagehide', async () => {
  const f = fixture('a'), newer = { ...f.doc, artifact: { ...f.doc.artifact, revision: 2 } }
  let finish!: (value: ArtifactDocument) => void
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockImplementationOnce(() => new Promise(resolve => { finish = resolve })).mockResolvedValue(f.doc)
  f.mount(() => true, vi.fn(), newer)
  await waitFor(() => expect(fetchWorkspacePublishedArtifact).toHaveBeenCalledTimes(1))
  fireEvent(window, new Event('pagehide')); fireEvent(window, new Event('pageshow'))
  finish(f.doc)
  const reopen = await screen.findByRole('button', { name: '공동 편집 다시 열기' })
  expect(streamArtifactDraft).not.toHaveBeenCalled()
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1)
  fireEvent.click(reopen)
  await waitFor(() => expect(streamArtifactDraft).toHaveBeenCalledTimes(1))
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(2)
})

it.each(['open', 'base'] as const)('manually reopens while the old %s is stuck and isolates its late completion', async phase => {
  const f = fixture('a'), newer = { ...f.doc, artifact: { ...f.doc.artifact, revision: 2 } }
  let finishOld!: () => void, finishNew!: () => void
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  if (phase === 'open') vi.mocked(sendArtifactDraftCommand)
    .mockImplementationOnce(() => new Promise(resolve => { finishOld = () => resolve(f.snapshot()) }))
    .mockImplementationOnce(() => new Promise(resolve => { finishNew = () => resolve(f.snapshot()) }))
  if (phase === 'base') vi.mocked(fetchWorkspacePublishedArtifact)
    .mockImplementationOnce(() => new Promise(resolve => { finishOld = () => resolve(f.doc) }))
    .mockImplementationOnce(() => new Promise(resolve => { finishNew = () => resolve(f.doc) }))
  f.mount(() => true, vi.fn(), phase === 'base' ? newer : f.doc)
  const calls = () => phase === 'open' ? vi.mocked(sendArtifactDraftCommand).mock.calls : vi.mocked(fetchWorkspacePublishedArtifact).mock.calls
  const signalAt = (index: number) => phase === 'open' ? vi.mocked(sendArtifactDraftCommand).mock.calls[index]![2]! : vi.mocked(fetchWorkspacePublishedArtifact).mock.calls[index]![3]!
  await waitFor(() => expect(calls()).toHaveLength(1))
  const oldSignal = signalAt(0)
  fireEvent(window, new Event('pagehide')); fireEvent(window, new Event('pageshow'))
  expect(oldSignal.aborted).toBe(true)
  const reopen = await screen.findByRole('button', { name: '공동 편집 다시 열기' })
  fireEvent.click(reopen)
  await waitFor(() => expect(calls()).toHaveLength(2))
  expect(signalAt(1).aborted).toBe(false)
  finishOld()
  await Promise.resolve(); await Promise.resolve()
  expect(screen.queryByRole('button', { name: '공동 편집 다시 열기' })).toBeNull()
  expect(streamArtifactDraft).not.toHaveBeenCalled()
  finishNew()
  await waitFor(() => expect(streamArtifactDraft).toHaveBeenCalledTimes(1))
  expect(calls()).toHaveLength(2)
})

it('keeps a reopened draft bound to its original workspace and respects a refusal', async () => {
  const f = fixture('a')
  let finishOld!: (value: ArtifactDraftView) => void
  vi.mocked(sendArtifactDraftCommand)
    .mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
    .mockRejectedValueOnce(new Error('workspace precondition failed'))
  f.mount()
  await waitFor(() => expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1))
  fireEvent(window, new Event('pagehide')); fireEvent(window, new Event('pageshow'))
  fireEvent.click(await screen.findByRole('button', { name: '공동 편집 다시 열기' }))
  await waitFor(() => expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(2))
  expect(vi.mocked(sendArtifactDraftCommand).mock.calls[1]![1]).toEqual(workspace)
  expect(captureArtifactWorkspace).not.toHaveBeenCalled()
  expect(streamArtifactDraft).not.toHaveBeenCalled()
  finishOld(f.snapshot())
})

it('never revives a genuinely closed editor on pageshow', async () => {
  const f = fixture('b')
  let close: ArtifactSharedCloseRequest | null = null
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  render(html`<${ArtifactSharedEditor} draftRetention=${draftRetention} doc=${f.doc} workspaceRoot="/fixture" capturedWorkspace=${workspace}
    isCurrent=${() => true} onCloseRequest=${(request: ArtifactSharedCloseRequest | null) => { close = request }}
    onMutation=${() => {}} onPublished=${() => {}} onClose=${() => {}} />`)
  await f.editor()
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  expect(close!().kind).toBe('close')
  fireEvent(window, new Event('pagehide')); fireEvent(window, new Event('pageshow'))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  expect(fetchWorkspacePublishedArtifact).not.toHaveBeenCalled()
  expect(publishArtifact).not.toHaveBeenCalled()
})

it('does not open a composer from a pre-hide latest-version read after restore', async () => {
  const f = fixture('a')
  let finish!: (value: ArtifactDocument) => void
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockImplementation(() => new Promise(resolve => { finish = resolve }))
  f.mount(); await f.editor()
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  await waitFor(() => expect(fetchWorkspacePublishedArtifact).toHaveBeenCalledTimes(1))
  fireEvent(window, new Event('pagehide')); fireEvent(window, new Event('pageshow'))
  finish(f.doc)
  await Promise.resolve(); await Promise.resolve()
  expect(screen.queryByRole('button', { name: '새 버전 저장' })).toBeNull()
  expect(retainedDrafts.size).toBe(0)
  expect(publishArtifact).not.toHaveBeenCalled()
})

it('allows a fresh explicit save from a prepared composer after page restore', async () => {
  const f = fixture('b'), onPublished = vi.fn()
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  const artifact = { ...f.doc.artifact, revision: 2 }
  vi.mocked(publishArtifact).mockResolvedValue({ schema: 'masc.published_artifact.v1', artifact, revision_url: '/revision' })
  vi.mocked(readPublishedDraft).mockResolvedValue({ ...f.doc, artifact })
  f.mount(() => true, onPublished)
  await f.editor()
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  const save = await screen.findByRole('button', { name: '새 버전 저장' })
  await waitFor(() => expect((save as HTMLButtonElement).disabled).toBe(false))
  fireEvent.input(screen.getByLabelText('문서 요약'), { target: { value: '보존된 사본' } })
  fireEvent(window, new Event('pagehide')); fireEvent(window, new Event('pageshow'))
  expect(retainedDrafts.size).toBe(1)
  fireEvent.click(save)
  await waitFor(() => expect(onPublished).toHaveBeenCalledTimes(1))
  expect(publishArtifact).toHaveBeenCalledTimes(1)
  expect(checkpointArtifactDraft).toHaveBeenCalledTimes(1)
})

it.each(['hidden', 'restored'] as const)('retains an in-flight publication completed while %s without a readback or second save', async completion => {
  const f = fixture('c'), onMutation = vi.fn(), onPublished = vi.fn()
  let finish!: (value: Awaited<ReturnType<typeof publishArtifact>>) => void
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  vi.mocked(publishArtifact).mockImplementation(() => new Promise(resolve => { finish = resolve }))
  f.mount(() => true, onPublished, f.doc, onMutation)
  await f.editor()
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  const save = await screen.findByRole('button', { name: '새 버전 저장' })
  await waitFor(() => expect((save as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(save)
  await waitFor(() => expect(publishArtifact).toHaveBeenCalledTimes(1))
  fireEvent(window, new Event('pagehide'))
  if (completion === 'restored') fireEvent(window, new Event('pageshow'))
  expect((save as HTMLButtonElement).disabled).toBe(true)
  const artifact = { ...f.doc.artifact, revision: 2 }
  finish({ schema: 'masc.published_artifact.v1', artifact, revision_url: '/revision' })
  if (completion === 'hidden') {
    await waitFor(() => expect(onMutation).toHaveBeenCalledWith(expect.objectContaining({ kind: 'published', verified: false })))
    fireEvent(window, new Event('pageshow'))
  }
  await screen.findByText(/페이지가 바뀌기 전에 보낸 게시 응답/)
  expect(onMutation).toHaveBeenCalledWith(expect.objectContaining({ kind: 'published', verified: false }))
  expect(readPublishedDraft).not.toHaveBeenCalled()
  expect(checkpointArtifactDraft).not.toHaveBeenCalled()
  expect(onPublished).not.toHaveBeenCalled()
  fireEvent.click(save)
  expect(publishArtifact).toHaveBeenCalledTimes(1)
  expect(retainedDrafts.size).toBe(1)
})

it('reports a pre-hide checkpoint result without applying it to the restored session', async () => {
  const f = fixture('c'), onMutation = vi.fn()
  let finish!: (value: Awaited<ReturnType<typeof checkpointArtifactDraft>>) => void
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  const artifact = { ...f.doc.artifact, revision: 2 }
  vi.mocked(publishArtifact).mockResolvedValue({ schema: 'masc.published_artifact.v1', artifact, revision_url: '/revision' })
  vi.mocked(readPublishedDraft).mockResolvedValue({ ...f.doc, artifact })
  vi.mocked(checkpointArtifactDraft).mockImplementation(() => new Promise(resolve => { finish = resolve }))
  f.mount(() => true, vi.fn(), f.doc, onMutation); await f.editor()
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  const save = await screen.findByRole('button', { name: '새 버전 저장' })
  await waitFor(() => expect((save as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(save)
  await waitFor(() => expect(checkpointArtifactDraft).toHaveBeenCalledTimes(1))
  fireEvent(window, new Event('pagehide')); fireEvent(window, new Event('pageshow'))
  const document = f.snapshot()
  finish({ checkpoint: 'checkpointed', document: { ...document, draft: { ...document.draft,
    base_revision: 2, base_sha256: artifact.body._blob.sha256, sequence: 1 } } })
  await waitFor(() => expect(onMutation).toHaveBeenCalledWith(expect.objectContaining({ kind: 'checkpoint', status: 'checkpointed' })))
  expect(screen.getByText(/게시된 v1에서 시작한 공유 원고/)).toBeTruthy()
  expect(checkpointArtifactDraft).toHaveBeenCalledTimes(1)
})

it.each([400, 409, 408, 503].flatMap(status => (['hidden', 'restored'] as const).map(phase => [status, phase] as const)))(
  'settles a pre-hide publication status %i while %s without replaying', async (status, phase) => {
  const f = fixture('a'), onMutation = vi.fn()
  let reject!: (error: Error) => void
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  vi.mocked(publishArtifact).mockImplementation(() => new Promise((_, fail) => { reject = fail }))
  f.mount(() => true, vi.fn(), f.doc, onMutation)
  await f.editor()
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  const save = await screen.findByRole('button', { name: '새 버전 저장' })
  await waitFor(() => expect((save as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(save)
  await waitFor(() => expect(publishArtifact).toHaveBeenCalledTimes(1))
  fireEvent(window, new Event('pagehide'))
  if (phase === 'restored') fireEvent(window, new Event('pageshow'))
  reject(new ApiRequestError({ method: 'POST', path: '/api/v1/published-artifacts', status, detail: 'response' }))
  if (phase === 'hidden') { await Promise.resolve(); await Promise.resolve(); fireEvent(window, new Event('pageshow')) }
  if (status === 409) await screen.findByText(/다른 사용자가 먼저 저장했습니다/)
  else if (status === 400) await screen.findByText(/response/)
  else {
    await screen.findByText(/자동으로 다시 저장하지 않습니다/)
    expect(onMutation).toHaveBeenCalledWith(expect.objectContaining({ kind: 'unconfirmed' }))
  }
  expect((screen.getByRole('button', { name: '편집 닫기' }) as HTMLButtonElement).disabled).toBe(false)
  expect(publishArtifact).toHaveBeenCalledTimes(1)
  expect(checkpointArtifactDraft).not.toHaveBeenCalled()
  expect(retainedDrafts.size).toBe(1)
})

it('keeps a verified publication and shared source when its edited composer copy cannot advance the shared base', async () => {
  const f = fixture('a'), onPublished = vi.fn(), onMutation = vi.fn()
  let latest = f.doc
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockImplementation(async () => latest)
  vi.mocked(publishArtifact).mockImplementation(async request => {
    const artifact = { ...latest.artifact, ...request, revision: 2, task_id: request.task_id ?? null, goal_id: request.goal_id ?? null }
    latest = { artifact, content: request.content, revisions: [artifact] }
    return { schema: 'masc.published_artifact.v1', artifact, revision_url: '/revision' }
  })
  vi.mocked(readPublishedDraft).mockImplementation(async () => latest)
  vi.mocked(checkpointArtifactDraft).mockRejectedValue(new ApiRequestError({ method: 'POST', path: '/checkpoint', status: 409, detail: 'source mismatch' }))
  f.mount(() => true, onPublished, f.doc, onMutation)
  const editor = await f.editor(), original = editor.state.doc.toString()
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  fireEvent.input(await screen.findByLabelText('문서 본문'), { target: { value: 'different publication copy' } })
  const save = screen.getByRole('button', { name: '새 버전 저장' })
  await waitFor(() => expect((save as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(save)
  await waitFor(() => expect(onPublished).toHaveBeenCalledTimes(1))
  await waitFor(() => expect(onMutation).toHaveBeenCalledWith(expect.objectContaining({ kind: 'checkpoint', status: 'refused' })))
  expect(onMutation).toHaveBeenCalledWith(expect.objectContaining({ kind: 'published', verified: true }))
  expect(checkpointArtifactDraft).toHaveBeenCalledTimes(1)
  expect(editor.state.doc.toString()).toBe(original)
  expect(sharedSource(f.authority)).toBe(original)
})

it.each(['authority', 'pagehide', 'restore'] as const)('does not start a checkpoint after %s during publication readback', async retirement => {
  const f = fixture('b'), onMutation = vi.fn()
  let current = true, finishRead!: (value: ArtifactDocument) => void
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  const artifact = { ...f.doc.artifact, revision: 2 }
  vi.mocked(publishArtifact).mockResolvedValue({ schema: 'masc.published_artifact.v1', artifact, revision_url: '/revision' })
  vi.mocked(readPublishedDraft).mockImplementation(() => new Promise(resolve => { finishRead = resolve }))
  const mounted = f.mount(() => current, vi.fn(), f.doc, onMutation)
  await f.editor()
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  const save = await screen.findByRole('button', { name: '새 버전 저장' })
  await waitFor(() => expect((save as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(save)
  await waitFor(() => expect(readPublishedDraft).toHaveBeenCalledTimes(1))
  // Retire the authority or window before the component's cleanup runs.
  if (retirement === 'authority') current = false
  else {
    fireEvent(window, new Event('pagehide'))
    if (retirement === 'restore') fireEvent(window, new Event('pageshow'))
  }
  finishRead({ ...f.doc, artifact })
  await waitFor(() => expect(onMutation).toHaveBeenCalledWith(expect.objectContaining({ kind: 'published', verified: true })))
  expect(checkpointArtifactDraft).not.toHaveBeenCalled()
  if (retirement === 'restore') await screen.findByText(/공동 원고 기준은 자동으로 갱신하지 않았습니다/)
  mounted.unmount()
})

it.each([408, 503])('retains status %i as an uncertain checkpoint after the old editor is closed, without replaying it', async status => {
  const f = fixture('c'), onMutation = vi.fn()
  let current = true, rejectCheckpoint!: (reason: Error) => void
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  const artifact = { ...f.doc.artifact, revision: 2 }
  vi.mocked(publishArtifact).mockResolvedValue({ schema: 'masc.published_artifact.v1', artifact, revision_url: '/revision' })
  vi.mocked(readPublishedDraft).mockResolvedValue({ ...f.doc, artifact })
  vi.mocked(checkpointArtifactDraft).mockImplementation(() => new Promise((_, reject) => { rejectCheckpoint = reject }))
  const mounted = f.mount(() => current, vi.fn(), f.doc, onMutation)
  const editor = await f.editor(), original = editor.state.doc.toString()
  await waitFor(() => expect((screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: '새 버전으로 게시' }))
  const save = await screen.findByRole('button', { name: '새 버전 저장' })
  await waitFor(() => expect((save as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(save)
  await waitFor(() => expect(checkpointArtifactDraft).toHaveBeenCalledTimes(1))
  current = false; mounted.unmount()
  rejectCheckpoint(new ApiRequestError({ method: 'POST', path: '/checkpoint', status, detail: 'response unavailable' }))
  await waitFor(() => expect(onMutation).toHaveBeenCalledWith(expect.objectContaining({ kind: 'checkpoint', status: 'unconfirmed' })))
  expect(onMutation).toHaveBeenCalledWith(expect.objectContaining({ kind: 'published', verified: true }))
  expect(checkpointArtifactDraft).toHaveBeenCalledTimes(1)
  expect(sharedSource(f.authority)).toBe(original)
})

it('offers an in-flight owner’s full local draft after remount without replaying it until explicit resume', async () => {
  const f = fixture('c')
  let current = true, mergeCount = 0
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command => {
    if (command.action !== 'merge') return f.snapshot()
    if (++mergeCount === 1) return new Promise<ArtifactDraftView>(() => {})
    return f.merge(command.updates)
  })
  const retired = f.mount(() => current)
  const editor = await f.editor(), original = editor.state.doc.toString()
  editor.dispatch({ changes: { from: 0, insert: 'unacknowledged ' } })
  await waitFor(() => expect(mergeCount).toBe(1))
  current = false; retired.unmount()
  const retained = artifactDraftRecoveries(workspace, f.target.artifact_id)
  expect(retained).toHaveLength(1)
  expect(retained[0]?.persisted).toBe(true)
  f.mount()
  const reopened = await f.editor()
  await screen.findByText(/복구 원고 ·/)
  expect(reopened.state.doc.toString()).toBe(original)
  expect(sharedSource(f.authority)).toBe(original)
  expect(mergeCount).toBe(1)
  expect(screen.getByRole('button', { name: '복구 원고 다운로드' })).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: '공유 원고에 합치기' }))
  await waitFor(() => expect(mergeCount).toBe(2))
  await waitFor(() => expect(reopened.state.doc.toString()).toBe(`unacknowledged ${original}`))
  expect(sharedSource(f.authority)).toBe(`unacknowledged ${original}`)
  await waitFor(() => expect(artifactDraftRecoveries(workspace, f.target.artifact_id)).toHaveLength(0))
})

it('retains the old durable recovery during an in-flight resume when browser quota blocks the new owner’s copy', async () => {
  const f = fixture('c')
  let mergeCount = 0, acknowledge!: () => void
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command => {
    if (command.action !== 'merge') return f.snapshot()
    if (++mergeCount === 1) return new Promise<ArtifactDraftView>(() => {})
    return new Promise<ArtifactDraftView>(resolve => { acknowledge = () => resolve(f.merge(command.updates)) })
  })
  const retired = f.mount(), editor = await f.editor()
  editor.dispatch({ changes: { from: 0, insert: 'durable unacknowledged ' } })
  await waitFor(() => expect(mergeCount).toBe(1))
  retired.unmount()
  const old = artifactDraftRecoveries(workspace, f.target.artifact_id)[0]!
  expect(old.persisted).toBe(true)
  const storage = localStorage
  const oldKey = Array.from({ length: storage.length }, (_, index) => storage.key(index)!)
    .find(key => JSON.parse(storage.getItem(key) ?? 'null')?.id === old.id)!
  const durable = storage.getItem(oldKey)
  expect(durable).not.toBeNull()
  vi.stubGlobal('localStorage', { get length() { return storage.length }, key: storage.key.bind(storage),
    getItem: storage.getItem.bind(storage), removeItem: storage.removeItem.bind(storage),
    setItem() { throw new Error('quota exceeded') },
  })
  f.mount()
  const reopened = await f.editor()
  await screen.findByText(/복구 원고 ·/)
  expect(mergeCount).toBe(1)
  fireEvent.click(screen.getByRole('button', { name: '공유 원고에 합치기' }))
  await waitFor(() => expect(mergeCount).toBe(2))
  await screen.findByText(/브라우저에 복구 원고를 저장하지 못했습니다/)
  expect(reopened.state.doc.toString()).toBe(`durable unacknowledged ${f.doc.content}`)
  expect(storage.getItem(oldKey)).toBe(durable)
  expect(artifactDraftRecoveries(workspace, f.target.artifact_id).some(record => record.id === old.id && record.persisted)).toBe(true)
  const otherTab=new Y.Doc();documents.push(otherTab);Y.applyUpdate(otherTab,draftBytes(old.state));otherTab.getText('content').insert(0,'other tab ')
  const external={...JSON.parse(durable!),revision:crypto.randomUUID(),state:draftBase64(sharedState(otherTab)),at:'2026-10-26T03:11:12Z'}
  const externalKey=`masc.artifact-draft-recovery.v1:${external.id}:${external.revision}`
  storage.setItem(externalKey,JSON.stringify(external));window.dispatchEvent(new Event('storage'))
  await screen.findByText(`복구 원고 · ${new Date(external.at).toLocaleString()}`)
  expect(reopened.state.doc.toString()).not.toContain('other tab ')
  acknowledge()
  await waitFor(() => expect(storage.getItem(oldKey)).toBeNull())
  expect(storage.getItem(externalKey)).not.toBeNull()
  await waitFor(() => expect(artifactDraftRecoveries(workspace, f.target.artifact_id)).toHaveLength(1))
  expect(artifactDraftRecoveries(workspace,f.target.artifact_id)[0]?.revision).toBe(external.revision)
  expect(screen.getAllByRole('button',{name:'공유 원고에 합치기'})).toHaveLength(1)
})


it('retains the publication copy and later edits outside the retired shared editor without writing under replacement authority', async () => {
  const f = fixture('b')
  let current = true
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  const view = f.mount(() => current)
  await f.editor()
  const prepare = screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement
  await waitFor(() => expect(prepare.disabled).toBe(false))
  fireEvent.click(prepare)
  await screen.findByLabelText('문서 본문')
  expect(retainedDrafts.size).toBe(1)
  expect([...retainedDrafts.values()][0]!.base).toEqual({ id: f.target.artifact_id, revision: 1 })
  const content = '\uFEFF# 게시 전 원고\r\n한글 😀\n'
  fireEvent.input(screen.getByLabelText('문서 제목'), { target: { value: 'local publication title' } })
  fireEvent.input(screen.getByLabelText('문서 본문'), { target: { value: content } })
  const snapshot = [...retainedDrafts.values()][0]!
  expect(snapshot.value).toEqual({ title: 'local publication title', summary: f.doc.artifact.summary,
    format: 'markdown', content, task_id: null, goal_id: null })
  current = false
  fireEvent.click(screen.getByRole('button', { name: '새 버전 저장' }))
  expect(publishArtifact).not.toHaveBeenCalled()
  view.unmount()
  expect(retainedDrafts.get(snapshot.identity)?.value.content).toBe(content)
  expect(sharedSource(f.authority)).toBe(f.doc.content)
})


it.each(['editor', 'reader'] as const)('requires an explicit discard decision when %s closes a locally edited publication copy', async close => {
  const f = fixture('b')
  vi.mocked(sendArtifactDraftCommand).mockResolvedValue(f.snapshot())
  vi.mocked(fetchWorkspacePublishedArtifact).mockResolvedValue(f.doc)
  const onClose = vi.fn()
  const view = render(html`<${ArtifactReader} doc=${f.doc} fixedRevision=${false} workspaceRoot="/fixture" shareWorkspace=${workspace}
    draftRetention=${draftRetention} checkState=${{ kind: 'known', check: null }} authRevision=${0}
    isCurrent=${() => true} onMutation=${() => {}} onPublication=${() => {}} onPublished=${() => {}}
    onCheckChanged=${() => {}} onClose=${() => { onClose(); view.unmount() }} />`)
  fireEvent.click(screen.getByRole('button', { name: '공동 편집', exact: true }))
  await f.editor()
  const prepare = screen.getByRole('button', { name: '새 버전으로 게시' }) as HTMLButtonElement
  await waitFor(() => expect(prepare.disabled).toBe(false))
  fireEvent.click(prepare)
  const body = await screen.findByLabelText('문서 본문')
  const content = '\uFEFF# 아직 게시하지 않음\r\n한글 😀\n'
  fireEvent.input(body, { target: { value: content } })
  const blobs: Blob[] = []
  vi.spyOn(URL, 'createObjectURL').mockImplementation(blob => { blobs.push(blob as Blob); return 'blob:local-publication' })
  vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {})
  vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
  vi.stubGlobal('confirm', vi.fn(() => false))
  const closeButton = () => screen.getByRole('button', { name: close === 'editor' ? '공동 편집 닫기' : '목록으로', exact: true })
  fireEvent.click(closeButton())
  expect(window.confirm).toHaveBeenCalledTimes(1)
  expect((screen.getByLabelText('문서 본문') as HTMLTextAreaElement).value).toBe(content)
  expect(retainedDrafts.size).toBe(1)
  expect(onClose).not.toHaveBeenCalled()
  const composer = within(screen.getByRole('region', { name: '아티팩트 편집' }))
  fireEvent.click(composer.getByRole('button', { name: '원고 다운로드' }))
  expect(new Uint8Array(await blobs[0]!.arrayBuffer())).toEqual(new TextEncoder().encode(content))
  vi.mocked(window.confirm).mockReturnValue(true)
  fireEvent.click(closeButton())
  expect(retainedDrafts.size).toBe(0)
  expect(screen.queryByLabelText('문서 본문')).toBeNull()
  expect(onClose).toHaveBeenCalledTimes(close === 'reader' ? 1 : 0)
  expect(publishArtifact).not.toHaveBeenCalled()
  expect(sharedSource(f.authority)).toBe(f.doc.content)
})
