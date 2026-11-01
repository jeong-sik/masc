import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { ArtifactDiscussionPanel } from './artifact-discussion-panel'
import { ArtifactLiveSession, draftBase64, draftBytes, type ArtifactLiveState } from '../../lib/artifact-live-session'
import { seedSharedDocument, restoreSharedDocument, sharedSource, sharedState, selectSharedSource } from '../../lib/artifact-shared-document'
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
function fixture(actor = 'human', storedState?: string) {
  const authority=storedState ? restoreSharedDocument(draftBytes(storedState)) : seedSharedDocument(source);documents.push(authority)
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
    return html`<${ArtifactDiscussionPanel} session=${session} state=${state} onPending=${onPending} onReveal=${reveal} />`
  }
  const reveal=vi.fn(), onPending=vi.fn()
  const mount=()=>render(html`<${Host} />`)
  const ack=(request:ArtifactDiscussionRequest,receiptActor=actor,applied:ArtifactThread['position']|null=null)=>{
    sequence++;receipts=[...receipts,{request,actor:receiptActor,at,applied}];return snapshot()
  }
  return {session,authority,snapshot,mount,ack,reveal,onPending,setThreads:(value:readonly ArtifactThread[])=>{threads=value;sequence++;session.acceptServerView(snapshot())},retire:()=>{current=false},restore:()=>{current=true}}
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
it('updates retained discussion input without rescanning unrelated local copies',async()=>{
  const value={kind:'input' as const,input:{kind:'reply' as const,operationId:target.generation,threadId:target.generation,body:'another retained input'}}
  const scopes=[
    {workspace,target,id:'another-operation'},
    {workspace,target:{...target,artifact_id:`artifact-${'f'.repeat(32)}`},id:'another-document'},
    {workspace:{...workspace,mascRoot:'/another-runtime'},target,id:'another-workspace'},
  ]
  const copies=scopes.map(scope=>{
    retainDiscussionLocal(scope.id,scope.workspace,scope.target,'human',value)
    return discussionLocals(scope.workspace,scope.target.artifact_id).find(record=>record.id===scope.id)!
  })
  try {
    const f=fixture();await start(f)
    const previous=pending().find(record=>!scopes.some(scope=>scope.id===record.id))!
    const key=(record:{id:string;revision:string})=>`masc.artifact-discussion-local.v1:${record.id}:${record.revision}`
    const storage=localStorage, originalCopies=copies.map(record=>storage.getItem(key(record)))
    const counts={enumeratedKeys:0,readValues:0,storedValues:0,removedValues:0}
    vi.stubGlobal('localStorage',{
      get length(){return storage.length},
      key(index:number){counts.enumeratedKeys++;return storage.key(index)},
      getItem(name:string){counts.readValues++;return storage.getItem(name)},
      setItem(name:string,value:string){counts.storedValues++;storage.setItem(name,value)},
      removeItem(name:string){counts.removedValues++;storage.removeItem(name)},
    })
    fireEvent.input(screen.getByLabelText('댓글 내용'),{target:{value:'updated and retained once'}})
    const observed={...counts}
    vi.unstubAllGlobals()
    const current=pending().find(record=>record.id===previous.id)!
    expect(current.value.kind==='input'&&current.value.input.body).toBe('updated and retained once')
    expect(current.value.kind==='input'&&current.value.input.operationId)
      .toBe(previous.value.kind==='input'&&previous.value.input.operationId)
    expect(current.revision).not.toBe(previous.revision)
    expect(JSON.parse(storage.getItem(key(current))!).value).toEqual(current.value)
    expect(storage.getItem(key(previous))).toBeNull()
    expect(copies.map(record=>storage.getItem(key(record)))).toEqual(originalCopies)
    console.info('discussion-input-storage',JSON.stringify(observed))
    expect(observed.storedValues).toBe(1)
    expect(observed.enumeratedKeys).toBe(0)
    expect(observed.readValues).toBe(0)
  } finally {
    vi.unstubAllGlobals();copies.forEach(discardDiscussionLocal)
  }
})
it('stops rescanning after confirmed recovery cleanup while preserving the operation and acknowledgement',async()=>{
  const original=fixture();await start(original)
  const old=pending()[0]!, storage=localStorage
  const key=(record:{id:string;revision:string})=>`masc.artifact-discussion-local.v1:${record.id}:${record.revision}`
  const foreign=retainDiscussionLocal('foreign-recovered-input',workspace,{...target,artifact_id:`artifact-${'f'.repeat(32)}`},'human',old.value).record
  const foreignBytes=storage.getItem(key(foreign))
  original.retire();cleanup()
  const f=fixture('human',original.snapshot().draft.state);f.mount()
  await waitFor(()=>expect((screen.getByRole('button',{name:'원고와 댓글 입력 복구'}) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button',{name:'원고와 댓글 입력 복구'}))
  await screen.findByLabelText('댓글 내용')
  await waitFor(()=>expect(f.session.snapshot.pending).toBe(false))
  expect(storage.getItem(key(old))).toBeNull()
  const restored=pending()[0]!
  expect(restored.id).not.toBe(old.id)
  const counts={enumeratedKeys:0,readValues:0,storedValues:0,removedValues:0}
  vi.stubGlobal('localStorage',{
    get length(){return storage.length},key(index:number){counts.enumeratedKeys++;return storage.key(index)},
    getItem(name:string){counts.readValues++;return storage.getItem(name)},
    setItem(name:string,value:string){counts.storedValues++;storage.setItem(name,value)},
    removeItem(name:string){counts.removedValues++;storage.removeItem(name)},
  })
  fireEvent.input(screen.getByLabelText('댓글 내용'),{target:{value:'recovered input edited once'}})
  const observed={...counts};vi.unstubAllGlobals()
  const current=pending()[0]!
  expect(current.id).toBe(restored.id)
  expect(current.value.kind==='input'&&current.value.input.body).toBe('recovered input edited once')
  expect(current.value.kind==='input'&&current.value.input.operationId).toBe(old.value.kind==='input'&&old.value.input.operationId)
  expect(current.value.kind==='input'&&current.value.input.kind==='comment'&&current.value.input.source)
    .toEqual(old.value.kind==='input'&&old.value.input.kind==='comment'&&old.value.input.source)
  expect(JSON.parse(storage.getItem(key(current))!).value).toEqual(current.value)
  expect(storage.getItem(key(restored))).toBeNull()
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command=>command.action==='discuss'?f.ack(command.request):f.snapshot())
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  await waitFor(()=>expect(pending()).toHaveLength(0))
  expect(submitted().id).toBe(old.value.kind==='input'&&old.value.input.operationId)
  expect(submitted().command).toMatchObject({body:'recovered input edited once'})
  expect(f.onPending).toHaveBeenLastCalledWith(false)
  expect(storage.getItem(key(foreign))).toBe(foreignBytes)
  discardDiscussionLocal(foreign)
  console.info('discussion-recovered-input-storage',JSON.stringify(observed))
  expect(observed.storedValues).toBe(1)
  expect(observed.enumeratedKeys).toBe(0)
  expect(observed.readValues).toBe(0)
})
it.each(['write','origin removal'] as const)('keeps rereading after recovered-input %s failure until cleanup is confirmed',async failure=>{
  const original=fixture();await start(original)
  const old=pending()[0]!, storage=localStorage
  const key=(record:{id:string;revision:string})=>`masc.artifact-discussion-local.v1:${record.id}:${record.revision}`
  const oldKey=key(old), originalBytes=storage.getItem(oldKey)
  original.retire();cleanup()
  const f=fixture('human',original.snapshot().draft.state);f.mount()
  await waitFor(()=>expect((screen.getByRole('button',{name:'원고와 댓글 입력 복구'}) as HTMLButtonElement).disabled).toBe(false))
  let failing=true, enumeratedKeys=0
  vi.stubGlobal('localStorage',{
    get length(){return storage.length},key(index:number){enumeratedKeys++;return storage.key(index)},
    getItem:storage.getItem.bind(storage),
    setItem(name:string,value:string){if(failing&&failure==='write')throw new DOMException('full','QuotaExceededError');storage.setItem(name,value)},
    removeItem(name:string){if(failing&&failure==='origin removal'&&name===oldKey)throw new Error('origin cleanup failed');storage.removeItem(name)},
  })
  fireEvent.click(screen.getByRole('button',{name:'원고와 댓글 입력 복구'}))
  await screen.findByLabelText('댓글 내용')
  await waitFor(()=>expect(f.session.snapshot.pending).toBe(false))
  enumeratedKeys=0
  fireEvent.input(screen.getByLabelText('댓글 내용'),{target:{value:'recovered edit during failure'}})
  const failedKeys=enumeratedKeys
  expect(storage.getItem(oldKey)).toBe(originalBytes)
  expect(failedKeys).toBeGreaterThan(0)
  const retained=pending().find(record=>record.id!==old.id)!
  expect(retained.value.kind==='input'&&retained.value.input.body).toBe('recovered edit during failure')
  expect(retained.persisted).toBe(failure==='origin removal')
  failing=false;enumeratedKeys=0
  fireEvent.input(screen.getByLabelText('댓글 내용'),{target:{value:'recovered edit after repair'}})
  const cleanupKeys=enumeratedKeys
  expect(storage.getItem(oldKey)).toBeNull()
  expect(cleanupKeys).toBeGreaterThan(0)
  enumeratedKeys=0
  fireEvent.input(screen.getByLabelText('댓글 내용'),{target:{value:'own edit after confirmed cleanup'}})
  const ownKeys=enumeratedKeys
  vi.unstubAllGlobals()
  const current=pending()[0]!
  expect(current.value.kind==='input'&&current.value.input.body).toBe('own edit after confirmed cleanup')
  expect(current.value.kind==='input'&&current.value.input.operationId).toBe(old.value.kind==='input'&&old.value.input.operationId)
  expect(JSON.parse(storage.getItem(key(current))!).value).toEqual(current.value)
  console.info('discussion-recovered-failure-boundary',failure,JSON.stringify({failedKeys,cleanupKeys,ownKeys}))
  expect(ownKeys).toBe(0)
})
it.each(['write','remove'] as const)('rereads recovery copies when an own %s fails',async failure=>{
  const f=fixture();await start(f)
  const previous=pending()[0]!, storage=localStorage
  const key=(record:{id:string;revision:string})=>`masc.artifact-discussion-local.v1:${record.id}:${record.revision}`
  const previousBytes=storage.getItem(key(previous))
  let enumeratedKeys=0
  vi.stubGlobal('localStorage',{
    get length(){return storage.length},
    key(index:number){enumeratedKeys++;return storage.key(index)},
    getItem:storage.getItem.bind(storage),
    setItem(name:string,value:string){if(failure==='write')throw new DOMException('full','QuotaExceededError');storage.setItem(name,value)},
    removeItem(name:string){if(failure==='remove')throw new Error('storage removal failed');storage.removeItem(name)},
  })
  fireEvent.input(screen.getByLabelText('댓글 내용'),{target:{value:'input survives storage failure'}})
  const observedKeys=enumeratedKeys
  vi.unstubAllGlobals()
  const records=pending(), current=records.find(record=>record.id===previous.id&&record.revision!==previous.revision)!
  expect(current.value.kind==='input'&&current.value.input.body).toBe('input survives storage failure')
  expect(current.persisted).toBe(failure==='remove')
  expect(storage.getItem(key(previous))).toBe(previousBytes)
  expect(observedKeys).toBeGreaterThan(0)
  expect(records.some(record=>record.revision===previous.revision)).toBe(failure==='remove')
  vi.stubGlobal('confirm',vi.fn(()=>true))
  fireEvent.click(screen.getByRole('button',{name:'작성 취소'}))
  expect(f.onPending).toHaveBeenLastCalledWith(failure==='remove')
  if(failure==='remove') {
    fireEvent.click(screen.getByRole('button',{name:'복구본 지우기'}))
    expect(storage.getItem(key(previous))).toBeNull()
    expect(f.onPending).toHaveBeenLastCalledWith(false)
  }
})
it('keeps an externally observed recovery actionable while editing and rereads external deletion',async()=>{
  const f=fixture();await start(f)
  const previous=pending()[0]!, storage=localStorage
  const previousKey=`masc.artifact-discussion-local.v1:${previous.id}:${previous.revision}`
  const external={...JSON.parse(storage.getItem(previousKey)!),id:crypto.randomUUID(),revision:crypto.randomUUID()}
  const key=`masc.artifact-discussion-local.v1:${external.id}:${external.revision}`
  storage.setItem(key,JSON.stringify(external))
  fireEvent(window,new Event('storage'))
  fireEvent.input(screen.getByLabelText('댓글 내용'),{target:{value:'own input after external recovery'}})
  vi.stubGlobal('confirm',vi.fn(()=>true))
  fireEvent.click(screen.getByRole('button',{name:'복구본 지우기'}))
  expect(storage.getItem(key)).toBeNull()
  const remaining=pending()
  expect(remaining).toHaveLength(1)
  expect(remaining[0]!.value.kind==='input'&&remaining[0]!.value.input.body).toBe('own input after external recovery')
  storage.setItem(key,JSON.stringify(external));fireEvent(window,new Event('storage'))
  storage.removeItem(key);fireEvent(window,new Event('storage'))
  fireEvent.click(screen.getByRole('button',{name:'작성 취소'}))
  expect(f.onPending).toHaveBeenLastCalledWith(false)
})
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
it('retains a discussion request when its pre-hide acknowledgement arrives after suspension',async()=>{
  const f=fixture();await start(f)
  let finish!:(view:ArtifactDraftView)=>void
  vi.mocked(sendArtifactDraftCommand).mockImplementation(()=>new Promise(resolve=>{finish=resolve}))
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  const request=submitted()
  expect(pending()).toHaveLength(1)
  f.retire();f.session.suspend()
  finish(f.ack(request))
  await waitFor(()=>expect(f.session.snapshot.connection).toBe('disconnected'))
  await Promise.resolve();await Promise.resolve()
  expect(pending()).toHaveLength(1)
  expect(f.session.snapshot.view.draft.sequence).toBe(0)
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1)
  f.restore()
  void f.session.connect()
  await waitFor(()=>expect((screen.getByRole('button',{name:'전송 결과 확인'}) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button',{name:'전송 결과 확인'}))
  await waitFor(()=>expect(pending()).toHaveLength(0))
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1)
})
it('retains a local discussion input when its recovery read finishes in the old page lifecycle',async()=>{
  const f=fixture();await start(f)
  const saved=pending()[0]!
  cleanup();f.mount()
  await waitFor(()=>expect((screen.getByRole('button',{name:'원고와 댓글 입력 복구'}) as HTMLButtonElement).disabled).toBe(false))
  let finish!:(view:ArtifactDraftView)=>void
  vi.mocked(fetchArtifactDraft).mockImplementationOnce(()=>new Promise(resolve=>{finish=resolve}))
  fireEvent.click(screen.getByRole('button',{name:'원고와 댓글 입력 복구'}))
  f.retire();f.session.suspend();finish(f.snapshot())
  await Promise.resolve();await Promise.resolve()
  expect(pending().some(record=>record.revision===saved.revision)).toBe(true)
  expect(screen.queryByLabelText('댓글 내용')).toBeNull()
  expect(sendArtifactDraftCommand).not.toHaveBeenCalled()
  f.restore();void f.session.connect()
  await waitFor(()=>expect((screen.getByRole('button',{name:'원고와 댓글 입력 복구'}) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button',{name:'원고와 댓글 입력 복구'}))
  await screen.findByLabelText('댓글 내용')
  expect((screen.getByLabelText('댓글 내용') as HTMLTextAreaElement).value).toBe('같이 다듬어요')
})
it.each(['send','recover'] as const)('does not let an old %s rejection replace a current notice',async phase=>{
  const f=fixture();await start(f)
  let reject!:(error:Error)=>void
  if(phase==='send') {
    vi.mocked(sendArtifactDraftCommand).mockImplementationOnce(()=>new Promise((_,fail)=>{reject=fail}))
    fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  } else {
    cleanup();f.mount()
    await waitFor(()=>expect((screen.getByRole('button',{name:'원고와 댓글 입력 복구'}) as HTMLButtonElement).disabled).toBe(false))
    vi.mocked(fetchArtifactDraft).mockImplementationOnce(()=>new Promise((_,fail)=>{reject=fail}))
    fireEvent.click(screen.getByRole('button',{name:'원고와 댓글 입력 복구'}))
  }
  await Promise.resolve();await Promise.resolve()
  f.session.suspend();void f.session.connect()
  await waitFor(()=>expect((screen.getByRole('button',{name:'선택한 원문에 댓글'}) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button',{name:'선택한 원문에 댓글'}))
  expect(screen.getByText('입력은 이 브라우저에 보관합니다. 내용을 확인한 뒤 보내 주세요.')).toBeTruthy()
  reject(new Error('stale refusal sentinel'))
  await Promise.resolve();await Promise.resolve()
  expect(screen.getByText('입력은 이 브라우저에 보관합니다. 내용을 확인한 뒤 보내 주세요.')).toBeTruthy()
  expect(screen.queryByText(/stale refusal sentinel/)).toBeNull()
  expect(pending().length).toBeGreaterThan(0)
})
it('allows an explicit result check while an old discussion send hangs without letting its finally unlock the new check',async()=>{
  const f=fixture();await start(f)
  let rejectOld!:(error:Error)=>void, finishNew!:(view:ArtifactDraftView)=>void
  vi.mocked(sendArtifactDraftCommand).mockImplementationOnce(()=>new Promise((_,reject)=>{rejectOld=reject}))
  vi.mocked(fetchArtifactDraft).mockImplementationOnce(()=>new Promise(resolve=>{finishNew=resolve}))
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  const request=submitted()
  const oldSignal=vi.mocked(sendArtifactDraftCommand).mock.calls[0]![2]!
  f.session.suspend();fireEvent(window,new Event('pagehide'));void f.session.connect()
  expect(oldSignal.aborted).toBe(true)
  const check=await screen.findByRole('button',{name:'전송 결과 확인'})
  await waitFor(()=>expect((check as HTMLButtonElement).disabled).toBe(false))
  expect(fetchArtifactDraft).not.toHaveBeenCalled()
  fireEvent.click(check)
  expect(fetchArtifactDraft).toHaveBeenCalledTimes(1)
  expect(vi.mocked(fetchArtifactDraft).mock.calls[0]![2]!.aborted).toBe(false)
  rejectOld(new Error('old send failed'))
  await Promise.resolve();await Promise.resolve()
  expect((check as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(check);expect(fetchArtifactDraft).toHaveBeenCalledTimes(1)
  finishNew(f.ack(request))
  await waitFor(()=>expect(pending()).toHaveLength(0))
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1)
})
it('retries the identical request explicitly while an old discussion send hangs and ignores its late receipt',async()=>{
  const f=fixture();await start(f)
  let finishOld!:(view:ArtifactDraftView)=>void, finishNew!:(view:ArtifactDraftView)=>void
  vi.mocked(sendArtifactDraftCommand)
    .mockImplementationOnce(()=>new Promise(resolve=>{finishOld=resolve}))
    .mockImplementationOnce(()=>new Promise(resolve=>{finishNew=resolve}))
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  const request=submitted()
  f.session.suspend();fireEvent(window,new Event('pagehide'));void f.session.connect()
  const retry=await screen.findByRole('button',{name:'같은 요청 다시 보내기'})
  await waitFor(()=>expect((retry as HTMLButtonElement).disabled).toBe(false))
  expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1)
  fireEvent.click(retry)
  expect(vi.mocked(sendArtifactDraftCommand).mock.calls.map(([command])=>command)).toEqual([
    {action:'discuss',target,request},{action:'discuss',target,request},
  ])
  const receipt=f.ack(request)
  finishOld(receipt)
  await Promise.resolve();await Promise.resolve()
  expect(pending()).toHaveLength(1)
  expect((retry as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(retry);expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(2)
  finishNew(receipt)
  await waitFor(()=>expect(pending()).toHaveLength(0))
})
it('allows an explicit recovery while an old recovery read hangs without letting its finally unlock the new read',async()=>{
  const f=fixture();await start(f)
  cleanup();f.mount()
  const recover=await screen.findByRole('button',{name:'원고와 댓글 입력 복구'})
  await waitFor(()=>expect((recover as HTMLButtonElement).disabled).toBe(false))
  let rejectOld!:(error:Error)=>void, finishNew!:(view:ArtifactDraftView)=>void
  vi.mocked(fetchArtifactDraft)
    .mockImplementationOnce(()=>new Promise((_,reject)=>{rejectOld=reject}))
    .mockImplementationOnce(()=>new Promise(resolve=>{finishNew=resolve}))
  fireEvent.click(recover)
  const oldSignal=vi.mocked(fetchArtifactDraft).mock.calls[0]![2]!
  f.session.suspend();fireEvent(window,new Event('pagehide'));void f.session.connect()
  expect(oldSignal.aborted).toBe(true)
  await waitFor(()=>expect((recover as HTMLButtonElement).disabled).toBe(false))
  expect(fetchArtifactDraft).toHaveBeenCalledTimes(1)
  fireEvent.click(recover)
  expect(fetchArtifactDraft).toHaveBeenCalledTimes(2)
  expect(vi.mocked(fetchArtifactDraft).mock.calls[1]![2]!.aborted).toBe(false)
  rejectOld(new Error('old recovery failed'))
  await Promise.resolve();await Promise.resolve()
  expect((recover as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(recover);expect(fetchArtifactDraft).toHaveBeenCalledTimes(2)
  finishNew(f.snapshot())
  await screen.findByLabelText('댓글 내용')
  expect((screen.getByLabelText('댓글 내용') as HTMLTextAreaElement).value).toBe('같이 다듬어요')
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
it('does not send from a stale rendered button after the workspace or credential authority is withdrawn',async()=>{
  const f=fixture();await start(f)
  f.retire();expect(f.session.current).toBe(false)
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  expect(sendArtifactDraftCommand).not.toHaveBeenCalled()
  expect(pending()[0]?.value.kind).toBe('input')
  expect((screen.getByLabelText('댓글 내용') as HTMLTextAreaElement).value).toBe('같이 다듬어요')
})
it('does not check or retry a saved request from a retired connection handler',async()=>{
  const f=fixture();await start(f)
  vi.mocked(sendArtifactDraftCommand).mockRejectedValueOnce(new Error('response lost'))
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  await waitFor(()=>expect(screen.getByRole('alert').textContent).toContain('response lost'))
  f.retire()
  fireEvent.click(screen.getByRole('button',{name:'전송 결과 확인'}))
  fireEvent.click(screen.getByRole('button',{name:'같은 요청 다시 보내기'}))
  expect(fetchArtifactDraft).not.toHaveBeenCalled();expect(sendArtifactDraftCommand).toHaveBeenCalledTimes(1)
  expect(pending()).toHaveLength(1)
})
it('keeps a frozen request in memory and its durable input during quota failure, then preserves newer input while the old response arrives',async()=>{
  const f=fixture();await start(f)
  const input=pending()[0]!, key=`masc.artifact-discussion-local.v1:${input.id}:${input.revision}`, stored=localStorage.getItem(key)
  const storage=localStorage
  vi.stubGlobal('localStorage',{get length(){return storage.length},key:storage.key.bind(storage),getItem:storage.getItem.bind(storage),removeItem:storage.removeItem.bind(storage),setItem(){throw new DOMException('full','QuotaExceededError')}})
  let acknowledge!:(view:ArtifactDraftView)=>void
  vi.mocked(sendArtifactDraftCommand).mockImplementation(()=>new Promise(resolve=>{acknowledge=resolve}))
  fireEvent.click(screen.getByRole('button',{name:'댓글 보내기'}))
  expect(localStorage.getItem(key)).toBe(stored)
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
  const hidden=retainDiscussionLocal('other-root',{...workspace,mascRoot:'/other'},target,'human',{...value,input:{...value.input,body:'다른 루트'}}).record
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
