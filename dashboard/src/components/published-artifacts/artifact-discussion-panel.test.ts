import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { ArtifactDiscussionPanel } from './artifact-discussion-panel'
import { ArtifactLiveSession, draftBase64, draftBytes, type ArtifactLiveState } from '../../lib/artifact-live-session'
import { seedSharedDocument, sharedSource, sharedState, selectSharedSource } from '../../lib/artifact-shared-document'
import { discussionLocals, discardDiscussionLocal, retainDiscussionLocal } from '../../lib/artifact-discussion-local'
import { fetchArtifactDraft, sendArtifactDraftCommand, type ArtifactDraftView } from '../../api/artifact-drafts'
import { streamArtifactDraft, sendArtifactPresence, type ArtifactDraftLiveFrame } from '../../api/artifact-draft-live'
import type { ArtifactDiscussionRequest, ArtifactThread } from '../../api/artifact-discussion'
vi.mock('../../api/artifact-drafts', async original => ({ ...await original<typeof import('../../api/artifact-drafts')>(), fetchArtifactDraft: vi.fn(), sendArtifactDraftCommand: vi.fn() }))
vi.mock('../../api/artifact-draft-live', async original => ({ ...await original<typeof import('../../api/artifact-draft-live')>(), streamArtifactDraft: vi.fn(), sendArtifactPresence: vi.fn() }))
const workspace = { basePath: '/discussion-panel-test', mascRoot: '/separate-runtime' }
const target = { artifact_id: `artifact-${'e'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
const at = '2026-10-26T02:00:00Z', source = '<p>원고 &amp; 😀</p>\r\n'
const sessions: ArtifactLiveSession[] = [], documents: Y.Doc[] = []
beforeEach(() => { vi.mocked(sendArtifactDraftCommand).mockReset(); vi.mocked(fetchArtifactDraft).mockReset(); vi.mocked(streamArtifactDraft).mockReset(); vi.mocked(sendArtifactPresence).mockReset().mockResolvedValue() })
afterEach(() => {
  cleanup(); sessions.splice(0).forEach(s => s.dispose()); documents.splice(0).forEach(d => d.destroy())
  vi.restoreAllMocks(); vi.unstubAllGlobals(); discussionLocals(workspace,target.artifact_id).forEach(discardDiscussionLocal); localStorage.clear()
})
function fixture(actor = 'human') {
  const authority=seedSharedDocument(source);documents.push(authority)
  let threads: readonly ArtifactThread[]=[], receipts: ArtifactDraftView['discussion_receipts']=[], sequence=0, current=true
  let changed: (state: ArtifactLiveState)=>void = ()=>{}
  const snapshot=():ArtifactDraftView=>({draft:{schema:'masc.artifact_draft.v2',target,base_revision:1,base_sha256:'a'.repeat(64),state:draftBase64(sharedState(authority)),sequence,updated_by:actor,updated_at:at},content:sharedSource(authority),threads,discussion_receipts:receipts,selection:null})
  const session=new ArtifactLiveSession(snapshot(),workspace,state=>changed(state),()=>current);sessions.push(session)
  const frame=():ArtifactDraftLiveFrame=>({schema:'masc.artifact_draft_live.v1',target,session_id:'self',document:snapshot(),peers:[{session_id:'self',actor,source:{kind:'dashboard_connection'},position:null,observed_at:at}]})
  vi.mocked(streamArtifactDraft).mockImplementation(async(_,__,receive,signal)=>{receive(frame());await new Promise<void>(resolve=>signal.addEventListener('abort',()=>resolve(),{once:true}))})
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command=>{
    if(command.action==='merge')command.updates.forEach(update=>Y.applyUpdate(authority,draftBytes(update)))
    return snapshot()
  })
  vi.mocked(fetchArtifactDraft).mockImplementation(async()=>snapshot())
  function Host() {
    const [state,setState]=useState(session.snapshot);changed=setState
    useEffect(()=>{void session.connect()},[])
    return html`<${ArtifactDiscussionPanel} session=${session} state=${state} onPending=${()=>{}} onReveal=${reveal} />`
  }
  const reveal=vi.fn()
  const mount=()=>render(html`<${Host} />`)
  const ack=(request:ArtifactDiscussionRequest,receiptActor=actor,applied:ArtifactThread['position']|null=null)=>{
    sequence++;receipts=[...receipts,{request,actor:receiptActor,at,applied}];return snapshot()
  }
  return {session,authority,snapshot,mount,ack,reveal,setThreads:(value:readonly ArtifactThread[])=>{threads=value;sequence++;session.acceptServerView(snapshot())},retire:()=>{current=false}}
}
async function start(f:ReturnType<typeof fixture>,mode:'source'|'html_text'='source') {
  f.mount()
  await waitFor(()=>expect((screen.getByRole('button',{name:'선택한 원문에 댓글'}) as HTMLButtonElement).disabled).toBe(false))
  f.session.select({anchor:3,head:3+'원고 &amp; 😀'.length},mode);f.session.select(null)
  fireEvent.click(screen.getByRole('button',{name:'선택한 원문에 댓글'}))
  fireEvent.input(screen.getByLabelText('댓글 내용'),{target:{value:'같이 다듬어요'}})
}
const pending=()=>discussionLocals(workspace,target.artifact_id)
const submitted=()=>{
  const call=vi.mocked(sendArtifactDraftCommand).mock.calls.find(([command])=>command.action==='discuss')![0]
  if(call.action!=='discuss')throw new Error('discussion missing')
  return call.request
}
it('anchors a blurred rendered sentence and sends literal text as an escaped proposal without editing the source',async()=>{
  const f=fixture();await start(f,'html_text')
  fireEvent.click(screen.getByRole('checkbox'))
  fireEvent.input(screen.getByLabelText('변경 제안 내용'),{target:{value:'새 <문장> & 😀'}})
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command=>command.action==='discuss'?f.ack(command.request):f.snapshot())
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  await waitFor(()=>expect(pending()).toHaveLength(0))
  expect(submitted().command).toMatchObject({kind:'comment',quote:'원고 &amp; 😀',body:'같이 다듬어요',proposal:'새 &lt;문장&gt; &amp; 😀'})
  expect(sharedSource(f.authority)).toBe(source);expect(f.session.content).toBe(source)
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1)
})
it('reconciles an applied request after losing its response without resending it on mount or result check',async()=>{
  const f=fixture();await start(f)
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command=>{if(command.action==='discuss')f.ack(command.request);throw new Error('response lost')})
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  await screen.findByRole('button',{name:'전송 결과 확인'})
  await waitFor(()=>expect(screen.getByRole('alert').textContent).toContain('response lost'))
  const saved=pending()[0]!
  cleanup();f.mount()
  await waitFor(()=>expect((screen.getByRole('button',{name:'전송 결과 확인'}) as HTMLButtonElement).disabled).toBe(false))
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1);expect(fetchArtifactDraft).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button',{name:'전송 결과 확인'}))
  await waitFor(()=>expect(pending()).toHaveLength(0))
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1)
  expect(saved.value.kind==='request'&&saved.value.request.id).toBe(submitted().id)
})
it('retries only explicitly and retains the exact request id and body',async()=>{
  const f=fixture();await start(f)
  vi.mocked(sendArtifactDraftCommand).mockRejectedValueOnce(new Error('not delivered')).mockImplementation(async command=>command.action==='discuss'?f.ack(command.request):f.snapshot())
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  await waitFor(()=>expect(screen.getByRole('alert').textContent).toContain('not delivered'))
  const first=submitted()
  fireEvent.click(screen.getByRole('button',{name:'같은 요청 다시 보내기'}))
  await waitFor(()=>expect(pending()).toHaveLength(0))
  expect(vi.mocked(sendArtifactDraftCommand).mock.calls.map(([command])=>command)).toEqual([{action:'discuss',target,request:first},{action:'discuss',target,request:first}])
})
it('preserves an unknown request if its receipt was attributed to a different actor',async()=>{
  const f=fixture();await start(f)
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command=>command.action==='discuss'?f.ack(command.request,'another actor'):f.snapshot())
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  await waitFor(()=>expect(screen.getByRole('alert').textContent).toContain('작성자 또는 보낸 내용과 다릅니다'))
  expect(pending()).toHaveLength(1)
})
it('keeps a frozen request in memory and its durable input during quota failure, then preserves newer input while the old response arrives',async()=>{
  const f=fixture();await start(f)
  const input=pending()[0]!, stored=localStorage.getItem(`masc.artifact-discussion-local.v1:${input.id}`)
  const storage=localStorage
  vi.stubGlobal('localStorage',{get length(){return storage.length},key:storage.key.bind(storage),getItem:storage.getItem.bind(storage),removeItem:storage.removeItem.bind(storage),setItem(){throw new DOMException('full','QuotaExceededError')}})
  let acknowledge!:(view:ArtifactDraftView)=>void
  vi.mocked(sendArtifactDraftCommand).mockImplementation(()=>new Promise(resolve=>{acknowledge=resolve}))
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  expect(localStorage.getItem(`masc.artifact-discussion-local.v1:${input.id}`)).toBe(stored)
  expect(pending()[0]?.persisted).toBe(false)
  fireEvent.click(screen.getByRole('button',{name:'선택한 원문에 댓글'}))
  fireEvent.input(screen.getByLabelText('댓글 내용'),{target:{value:'새로 쓰는 댓글'}})
  vi.unstubAllGlobals();acknowledge(f.ack(submitted()))
  await waitFor(()=>expect(pending()).toHaveLength(1))
  expect((screen.getByLabelText('댓글 내용') as HTMLTextAreaElement).value).toBe('새로 쓰는 댓글')
  const remaining=pending()[0]!
  expect(remaining.value.kind==='input'&&remaining.value.input.body).toBe('새로 쓰는 댓글')
})
it('preserves unsent input across an authority remount and restores it only after an explicit read, with the same operation id',async()=>{
  const f=fixture();await start(f)
  const input=pending()[0]!, operationId=input.value.kind==='input'?input.value.input.operationId:''
  f.retire();cleanup()
  const next=fixture();next.mount()
  await waitFor(()=>expect((screen.getByRole('button',{name:'원고와 댓글 입력 복구'}) as HTMLButtonElement).disabled).toBe(false))
  expect(fetchArtifactDraft).not.toHaveBeenCalled();expect(sendArtifactDraftCommand).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button',{name:'원고와 댓글 입력 복구'}))
  await screen.findByLabelText('댓글 내용')
  expect((screen.getByLabelText('댓글 내용') as HTMLTextAreaElement).value).toBe('같이 다듬어요')
  await waitFor(()=>expect(next.session.snapshot.pending).toBe(false))
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command=>command.action==='discuss'?next.ack(command.request):next.snapshot())
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  await waitFor(()=>expect(pending()).toHaveLength(0));expect(submitted().id).toBe(operationId)
})
it('offers a different generation for download only and hides records from another runtime root',async()=>{
  const value={kind:'input' as const,input:{kind:'reply' as const,operationId:target.generation,threadId:target.generation,body:'이전 세대'}}
  retainDiscussionLocal('old-generation',workspace,{...target,generation:'019f0000-0000-7000-8000-000000000001'},'human',value)
  const hidden=retainDiscussionLocal('other-root',{...workspace,mascRoot:'/other'},target,'human',{...value,input:{...value.input,body:'다른 루트'}})
  const f=fixture();f.mount()
  await screen.findByText('다른 세대의 원고입니다. 다운로드할 수만 있습니다.')
  expect((screen.getByRole('button',{name:'원고와 댓글 입력 복구'}) as HTMLButtonElement).disabled).toBe(true)
  expect(screen.queryByText('다른 루트')).toBeNull();expect(sendArtifactDraftCommand).not.toHaveBeenCalled()
  discardDiscussionLocal(hidden)
})
it('shows Keeper comments, reveals their live anchors and blocks applying a proposal to changed text',async()=>{
  const f=fixture();f.mount()
  const position=selectSharedSource(f.authority,{anchor:3,head:5})
  const thread:ArtifactThread={id:target.generation,position,quote:'원고',messages:[{id:target.generation,actor:'keeper-editor',at,body:'이 문장을 바꿔볼까요?'}],proposal:'새 글',decision:{kind:'pending'},resolved:false}
  f.setThreads([thread])
  const article=within(await screen.findByRole('article',{name:'댓글 묶음'}))
  expect(article.getByText(/keeper-editor/)).toBeTruthy()
  fireEvent.click(article.getByRole('button',{name:'원문 위치 보기'}));expect(f.reveal).toHaveBeenCalledWith(position)
  f.authority.getText('content').delete(3,2);f.setThreads([thread])
  await screen.findByText('댓글을 남긴 뒤 원문이 바뀌었습니다.')
  expect((article.getByRole('button',{name:'제안 반영'}) as HTMLButtonElement).disabled).toBe(true)
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command=>command.action==='discuss'?f.ack(command.request):f.snapshot())
  fireEvent.click(article.getByRole('button',{name:'대화 해결'}))
  await waitFor(()=>expect(pending()).toHaveLength(0))
  expect(submitted().command).toEqual({kind:'resolve',thread_id:thread.id})
})
