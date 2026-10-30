import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { ArtifactSentenceEditor } from './artifact-sentence-editor'
import { ArtifactLiveSession, draftBase64, draftBytes, type ArtifactLiveState } from '../../lib/artifact-live-session'
import { seedSharedDocument, sharedSource, sharedState } from '../../lib/artifact-shared-document'
import { sendArtifactDraftCommand, type ArtifactDraftView } from '../../api/artifact-drafts'
import { sendArtifactPresence, streamArtifactDraft, type ArtifactDraftLiveFrame } from '../../api/artifact-draft-live'
import { artifactSentenceRecoveries, discardArtifactSentence } from '../../lib/artifact-sentence-recovery'
import { artifactDraftRecoveries, discardArtifactDraftRecovery } from '../../lib/artifact-draft-recovery'
import type { ArtifactWorkspace } from '../../api/published-artifacts'

vi.mock('../../api/artifact-drafts', async original => ({ ...await original<typeof import('../../api/artifact-drafts')>(), sendArtifactDraftCommand: vi.fn() }))
vi.mock('../../api/artifact-draft-live', async original => ({ ...await original<typeof import('../../api/artifact-draft-live')>(), streamArtifactDraft: vi.fn(), sendArtifactPresence: vi.fn() }))
const owned: (() => void)[] = []
beforeEach(() => { vi.mocked(sendArtifactDraftCommand).mockReset(); vi.mocked(streamArtifactDraft).mockReset(); vi.mocked(sendArtifactPresence).mockReset().mockResolvedValue() })
afterEach(() => {
  cleanup(); owned.splice(0).forEach(dispose => dispose()); vi.restoreAllMocks(); vi.unstubAllGlobals()
  for (const mascRoot of ['/fixture/.masc','/different-root']) {
    const workspace = {basePath:'/fixture',mascRoot}
    artifactSentenceRecoveries(workspace,`artifact-${'e'.repeat(32)}`).forEach(discardArtifactSentence)
    artifactDraftRecoveries(workspace,`artifact-${'e'.repeat(32)}`).forEach(discardArtifactDraftRecovery)
  }
})

async function fixture(format:'html'|'markdown'='html',source='<style>p{color:red}</style>\r\n<p>alpha &amp; 친구 😀</p>') {
  let activeFormat=format
  const authority = seedSharedDocument(source)
  const target = { artifact_id: `artifact-${'e'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
  let sequence = 0, receive!: (frame: ArtifactDraftLiveFrame) => void, changed: (state: ArtifactLiveState) => void = () => {}
  const snapshot = (): ArtifactDraftView => ({ content: sharedSource(authority), threads: [], discussion_receipts: [], selection: null, draft: { schema: 'masc.artifact_draft.v2', target,
    state: draftBase64(sharedState(authority)), base_revision: 1, base_sha256: 'a'.repeat(64), sequence, updated_by: 'actor', updated_at: '2026-10-26T01:00:00Z' } })
  const frame = (): ArtifactDraftLiveFrame => ({ schema: 'masc.artifact_draft_live.v1', session_id: 'self', target, peers: [], document: snapshot() })
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command => {
    if (command.action === 'merge') { command.updates.forEach(update => Y.applyUpdate(authority, draftBytes(update))); sequence++ }
    return snapshot()
  })
  vi.mocked(streamArtifactDraft).mockImplementation(async (_, __, callback, signal) => {
    receive = callback; callback(frame())
    await new Promise<void>(resolve => signal.addEventListener('abort', () => resolve(), { once: true }))
  })
  const workspace = { basePath: '/fixture', mascRoot: '/fixture/.masc' }
  let session = new ArtifactLiveSession(snapshot(), workspace, state => changed(state))
  owned.push(() => { session.dispose(); authority.destroy() })
  const pending = vi.fn()
  function Host() {
    const [state, setState] = useState(session.snapshot); changed = setState
    return html`<${ArtifactSentenceEditor} session=${session} state=${state} format=${activeFormat} onPending=${pending} />`
  }
  let mounted = render(html`<${Host} />`); void session.connect()
  await waitFor(() => expect(session.snapshot.connection).toBe('connected'))
  const message = () => {
    const iframe = screen.getByTitle('문장을 눌러 편집하는 미리보기') as HTMLIFrameElement
    const document = new DOMParser().parseFromString(iframe.srcdoc, 'text/html')
    const token = document.querySelector('script')!.getAttribute('nonce')!
    return { iframe, data: { type: 'masc.artifact.text.selected.v1', token, id: 0 } }
  }
  const select = (id=0) => { const {iframe,data} = message(); fireEvent(window, new MessageEvent('message', {source:iframe.contentWindow, data:{...data,id}})) }
  const remoteInsert = (index: number, text: string) => { authority.getText('content').insert(index,text); sequence++; receive(frame()) }
  const remount = async (nextWorkspace: ArtifactWorkspace = workspace,nextFormat=activeFormat) => {
    mounted.unmount(); session.dispose()
    activeFormat=nextFormat
    session = new ArtifactLiveSession(snapshot(), nextWorkspace, state => changed(state))
    mounted = render(html`<${Host} />`); void session.connect()
    await waitFor(() => expect(session.snapshot.connection).toBe('connected'))
  }
  return { authority, get session() { return session }, workspace, target, pending, message, select, remoteInsert, remount }
}

it('edits selected Markdown source in the rendered document while preserving a concurrent insertion and surrounding syntax',async()=>{
  const source='# 제목 😀\r\n\r\n**alpha** &amp; 친구\r\n',f=await fixture('markdown',source)
  f.select(1)
  expect((await screen.findByLabelText('선택한 문장') as HTMLTextAreaElement).value).toBe('alpha')
  fireEvent.input(screen.getByLabelText('선택한 문장'),{target:{value:'[수정한 글](https://example.test)'}})
  f.remoteInsert(0,'사람이 추가\r\n\r\n')
  fireEvent.click(screen.getByRole('button',{name:'문장 반영'}))
  await waitFor(()=>expect(sharedSource(f.authority)).toBe('사람이 추가\r\n\r\n# 제목 😀\r\n\r\n**[수정한 글](https://example.test)** &amp; 친구\r\n'))
  expect(new DOMParser().parseFromString(f.message().iframe.srcdoc,'text/html').querySelector('strong')?.textContent).toBe('수정한 글')
  expect(new DOMParser().parseFromString(f.message().iframe.srcdoc,'text/html').querySelector('a[href]')).toBeNull()
})
it('opens and edits a BOM-prefixed Markdown document containing emoji at its correct source boundary',async()=>{
  const f=await fixture('markdown','\uFEFF# 한글 😀\r\n\r\n본문 &amp; 끝')
  f.select()
  expect((await screen.findByLabelText('선택한 문장') as HTMLTextAreaElement).value).toBe('한글 😀')
  fireEvent.input(screen.getByLabelText('선택한 문장'),{target:{value:'바꾼 제목 😀'}})
  fireEvent.click(screen.getByRole('button',{name:'문장 반영'}))
  await waitFor(()=>expect(sharedSource(f.authority)).toBe('\uFEFF# 바꾼 제목 😀\r\n\r\n본문 &amp; 끝'))
})
it('restores Markdown input explicitly and offers it only for download under a different document format',async()=>{
  const f=await fixture('markdown','**alpha**\r\n');f.select()
  fireEvent.input(await screen.findByLabelText('선택한 문장'),{target:{value:'이어 쓰는 글'}})
  await f.remount()
  expect(screen.queryByLabelText('선택한 문장')).toBeNull()
  expect(sendArtifactDraftCommand).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button',{name:'선택 원고와 문장 입력 복구'}))
  expect((await screen.findByLabelText('선택한 문장') as HTMLTextAreaElement).value).toBe('이어 쓰는 글')
  await f.remount(f.workspace,'html')
  expect((screen.getByRole('button',{name:'선택 원고와 문장 입력 복구'}) as HTMLButtonElement).disabled).toBe(true)
  expect(screen.getByText('문서 형식이 달라 문장을 다운로드할 수만 있습니다.')).toBeTruthy()
  expect(sharedSource(f.authority)).toBe('**alpha**\r\n')
})

it('requires both the actual iframe window and its current capability before opening an editable sentence', async () => {
  const f = await fixture(), original = f.message()
  fireEvent(window,new MessageEvent('message',{source:window,data:original.data}))
  fireEvent(window,new MessageEvent('message',{source:original.iframe.contentWindow,data:{...original.data,token:'forged'}}))
  expect(screen.queryByLabelText('선택한 문장')).toBeNull()
  f.remoteInsert(0,'<!-- Keeper -->')
  await waitFor(() => expect(f.message().data.token).not.toBe(original.data.token))
  fireEvent(window,new MessageEvent('message',{source:original.iframe.contentWindow,data:original.data}))
  expect(screen.queryByLabelText('선택한 문장')).toBeNull()
  f.select()
  expect((await screen.findByLabelText('선택한 문장') as HTMLTextAreaElement).value).toBe('alpha & 친구 😀')
})
it('preserves a concurrent Keeper insertion, formatting and escaped literal text when applying a selected sentence', async () => {
  const f = await fixture(); f.select()
  const input = await screen.findByLabelText('선택한 문장')
  fireEvent.input(input,{target:{value:'함께 <script> & 친구 😀'}})
  await waitFor(() => expect(f.pending).toHaveBeenLastCalledWith(true))
  f.remoteInsert(0,'<!-- Keeper가 추가 -->\r\n')
  fireEvent.click(screen.getByRole('button',{name:'문장 반영'}))
  await waitFor(() => expect(sharedSource(f.authority)).toBe('<!-- Keeper가 추가 -->\r\n<style>p{color:red}</style>\r\n<p>함께 &lt;script&gt; &amp; 친구 😀</p>'))
  await waitFor(() => expect(f.pending).toHaveBeenLastCalledWith(false))
  expect(screen.queryByLabelText('선택한 문장')).toBeNull()
})
it('keeps the entered sentence and current source when the Keeper has changed that same text', async () => {
  const f = await fixture(); f.select()
  fireEvent.input(await screen.findByLabelText('선택한 문장'),{target:{value:'내 문장'}})
  f.remoteInsert(f.session.content.indexOf('alpha')+1,'!')
  fireEvent.click(screen.getByRole('button',{name:'문장 반영'}))
  await screen.findByText('선택한 내용이 바뀌었습니다. 현재 내용을 읽고 다시 편집해 주세요.')
  expect((screen.getByLabelText('선택한 문장') as HTMLTextAreaElement).value).toBe('내 문장')
  expect(sharedSource(f.authority)).toContain('a!lpha')
  expect(sendArtifactDraftCommand).not.toHaveBeenCalled()
})
it('protects an unapplied input from tab closure and a refused discard', async () => {
  const f = await fixture(); f.select()
  fireEvent.input(await screen.findByLabelText('선택한 문장'),{target:{value:'입력 중'}})
  await waitFor(() => expect(f.pending).toHaveBeenLastCalledWith(true))
  const unload = new Event('beforeunload',{cancelable:true}); window.dispatchEvent(unload)
  expect(unload.defaultPrevented).toBe(true)
  vi.stubGlobal('confirm',vi.fn(() => false))
  fireEvent.click(screen.getByRole('button',{name:'선택 닫기'}))
  expect((screen.getByLabelText('선택한 문장') as HTMLTextAreaElement).value).toBe('입력 중')
  expect(sharedSource(f.authority)).not.toContain('입력 중')
})
it('keeps the last input across an immediate owner remount and waits for explicit recovery before applying', async () => {
  const f = await fixture(); f.select()
  fireEvent.input(await screen.findByLabelText('선택한 문장'),{target:{value:'복구할 문장'}})
  expect(artifactSentenceRecoveries(f.workspace,f.target.artifact_id)[0]!.input).toBe('복구할 문장')
  await f.remount()
  expect(screen.queryByLabelText('선택한 문장')).toBeNull()
  expect(sendArtifactDraftCommand).not.toHaveBeenCalled()
  f.remoteInsert(0,'<!-- Keeper -->\r\n')
  fireEvent.click(screen.getByRole('button',{name:'선택 원고와 문장 입력 복구'}))
  expect((await screen.findByLabelText('선택한 문장') as HTMLTextAreaElement).value).toBe('복구할 문장')
  expect(sharedSource(f.authority)).not.toContain('복구할 문장')
  fireEvent.click(screen.getByRole('button',{name:'문장 반영'}))
  await waitFor(() => expect(sharedSource(f.authority)).toBe('<!-- Keeper -->\r\n<style>p{color:red}</style>\r\n<p>복구할 문장</p>'))
  await waitFor(() => expect(artifactSentenceRecoveries(f.workspace,f.target.artifact_id)).toHaveLength(0))
})
it('preserves the original guarded selection when a restored sentence has been changed remotely', async () => {
  const f = await fixture(); f.select()
  fireEvent.input(await screen.findByLabelText('선택한 문장'),{target:{value:'내 입력'}})
  await f.remount(); f.remoteInsert(f.session.content.indexOf('alpha')+1,'!')
  fireEvent.click(screen.getByRole('button',{name:'선택 원고와 문장 입력 복구'}))
  fireEvent.click(screen.getByRole('button',{name:'문장 반영'}))
  await screen.findByText('선택한 내용이 바뀌었습니다. 현재 내용을 읽고 다시 편집해 주세요.')
  expect((screen.getByLabelText('선택한 문장') as HTMLTextAreaElement).value).toBe('내 입력')
  expect(artifactSentenceRecoveries(f.workspace,f.target.artifact_id).some(record => record.input==='내 입력')).toBe(true)
  expect(sharedSource(f.authority)).toContain('a!lpha')
})
it('separates workspace roots and offers an old generation only for download', async () => {
  const f = await fixture(); f.select()
  fireEvent.input(await screen.findByLabelText('선택한 문장'),{target:{value:'이전 원고'}})
  await f.remount({...f.workspace,mascRoot:'/different-root'})
  expect(screen.queryByRole('button',{name:'선택 원고와 문장 입력 복구'})).toBeNull()
  f.target.generation='019f0000-0000-7000-8000-000000000001'
  await f.remount()
  expect((screen.getByRole('button',{name:'선택 원고와 문장 입력 복구'}) as HTMLButtonElement).disabled).toBe(true)
  expect(screen.getByRole('button',{name:'복구 문장 다운로드'})).toBeTruthy()
  expect(sendArtifactDraftCommand).not.toHaveBeenCalled()
})
it('retains a durable sentence while quota blocks transfer to a pending CRDT update', async () => {
  const f = await fixture(); f.select()
  fireEvent.input(await screen.findByLabelText('선택한 문장'),{target:{value:'저장 전 문장'}})
  const old = artifactSentenceRecoveries(f.workspace,f.target.artifact_id)[0]!
  const storage=localStorage, key=Array.from({length:storage.length},(_,index)=>storage.key(index)!).find(key=>JSON.parse(storage.getItem(key)??'null')?.id===old.id)!
  const durable=storage.getItem(key)
  await f.remount()
  vi.stubGlobal('localStorage',{get length(){return storage.length},key:storage.key.bind(storage),getItem:storage.getItem.bind(storage),removeItem:storage.removeItem.bind(storage),setItem(){throw new Error('quota')}})
  let acknowledge!:()=>void
  vi.mocked(sendArtifactDraftCommand).mockImplementation(command => new Promise(resolve=>{acknowledge=()=>{
    if(command.action==='merge') command.updates.forEach(update=>Y.applyUpdate(f.authority,draftBytes(update)))
    resolve({ ...f.session.snapshot.view, content:sharedSource(f.authority), draft:{...f.session.snapshot.view.draft,state:draftBase64(sharedState(f.authority))} })
  }}))
  fireEvent.click(screen.getByRole('button',{name:'선택 원고와 문장 입력 복구'}))
  vi.stubGlobal('confirm',vi.fn(()=>true))
  fireEvent.click(screen.getByRole('button',{name:'선택 원고와 문장 입력 복구'}))
  expect(storage.getItem(key)).toBe(durable)
  fireEvent.click(screen.getByRole('button',{name:'문장 반영'}))
  await waitFor(()=>expect(f.session.snapshot.pending).toBe(true))
  expect(storage.getItem(key)).toBe(durable)
  f.select()
  fireEvent.input(await screen.findByLabelText('선택한 문장'),{target:{value:'다음 입력'}})
  const external={...JSON.parse(durable!),revision:crypto.randomUUID(),input:'다른 탭의 새 문장'}
  const externalKey=`masc.artifact-sentence-recovery.v1:${external.id}:${external.revision}`
  storage.setItem(externalKey,JSON.stringify(external));window.dispatchEvent(new Event('storage'))
  await screen.findByText('다른 탭의 새 문장')
  acknowledge()
  await waitFor(()=>expect(f.session.snapshot.pending).toBe(false))
  await waitFor(()=>expect(storage.getItem(key)).toBeNull())
  expect(sharedSource(f.authority)).toContain('저장 전 문장')
  expect(artifactSentenceRecoveries(f.workspace,f.target.artifact_id).some(record=>record.input==='다음 입력')).toBe(true)
  expect(storage.getItem(externalKey)).not.toBeNull()
  expect((screen.getByLabelText('선택한 문장') as HTMLTextAreaElement).value).toBe('다음 입력')
})
it('recovers anchors that refer to an unacknowledged local source insertion', async () => {
  const f = await fixture()
  let merges=0
  vi.mocked(sendArtifactDraftCommand).mockImplementation(async command=>{
    if(command.action==='merge'&&++merges===1)return new Promise(()=>{})
    if(command.action==='merge')command.updates.forEach(update=>Y.applyUpdate(f.authority,draftBytes(update)))
    return {...f.session.snapshot.view,content:sharedSource(f.authority),draft:{...f.session.snapshot.view.draft,state:draftBase64(sharedState(f.authority))}}
  })
  f.session.doc.getText('content').insert(f.session.content.indexOf('alpha'),'local ')
  await waitFor(()=>expect(f.message().iframe.srcdoc).toContain('local alpha'))
  f.select();fireEvent.input(await screen.findByLabelText('선택한 문장'),{target:{value:'새 문장'}})
  await f.remount()
  expect(sharedSource(f.authority)).not.toContain('local ')
  fireEvent.click(screen.getByRole('button',{name:'선택 원고와 문장 입력 복구'}))
  await waitFor(()=>expect(sharedSource(f.authority)).toContain('local alpha'))
  fireEvent.click(screen.getByRole('button',{name:'문장 반영'}))
  await waitFor(()=>expect(sharedSource(f.authority)).toContain('<p>새 문장</p>'))
})
