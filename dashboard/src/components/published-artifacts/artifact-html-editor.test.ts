import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { ArtifactHtmlEditor } from './artifact-html-editor'
import { ArtifactLiveSession, draftBase64, draftBytes, type ArtifactLiveState } from '../../lib/artifact-live-session'
import { seedSharedDocument, sharedSource, sharedState } from '../../lib/artifact-shared-document'
import { sendArtifactDraftCommand, type ArtifactDraftView } from '../../api/artifact-drafts'
import { sendArtifactPresence, streamArtifactDraft, type ArtifactDraftLiveFrame } from '../../api/artifact-draft-live'

vi.mock('../../api/artifact-drafts', async original => ({ ...await original<typeof import('../../api/artifact-drafts')>(), sendArtifactDraftCommand: vi.fn() }))
vi.mock('../../api/artifact-draft-live', async original => ({ ...await original<typeof import('../../api/artifact-draft-live')>(), streamArtifactDraft: vi.fn(), sendArtifactPresence: vi.fn() }))
const owned: (() => void)[] = []
beforeEach(() => { vi.mocked(sendArtifactDraftCommand).mockReset(); vi.mocked(streamArtifactDraft).mockReset(); vi.mocked(sendArtifactPresence).mockReset().mockResolvedValue() })
afterEach(() => { cleanup(); owned.splice(0).forEach(dispose => dispose()); vi.restoreAllMocks(); vi.unstubAllGlobals() })

async function fixture() {
  const authority = seedSharedDocument('<style>p{color:red}</style>\r\n<p>alpha &amp; 친구 😀</p>')
  const target = { artifact_id: `artifact-${'e'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
  let sequence = 0, receive!: (frame: ArtifactDraftLiveFrame) => void, changed: (state: ArtifactLiveState) => void = () => {}
  const snapshot = (): ArtifactDraftView => ({ content: sharedSource(authority), selection: null, draft: { schema: 'masc.artifact_draft.v1', target,
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
  const session = new ArtifactLiveSession(snapshot(), { basePath: '/fixture', mascRoot: '/fixture/.masc' }, state => changed(state))
  owned.push(() => { session.dispose(); authority.destroy() })
  const pending = vi.fn()
  function Host() {
    const [state, setState] = useState(session.snapshot); changed = setState
    return html`<${ArtifactHtmlEditor} session=${session} state=${state} onPending=${pending} />`
  }
  render(html`<${Host} />`); void session.connect()
  await waitFor(() => expect(session.snapshot.connection).toBe('connected'))
  const message = () => {
    const iframe = screen.getByTitle('문장을 눌러 편집하는 미리보기') as HTMLIFrameElement
    const document = new DOMParser().parseFromString(iframe.srcdoc, 'text/html')
    const token = document.querySelector('script')!.getAttribute('nonce')!
    return { iframe, data: { type: 'masc.artifact.text.selected.v1', token, id: 0 } }
  }
  const select = () => { const {iframe,data} = message(); fireEvent(window, new MessageEvent('message', {source:iframe.contentWindow, data})) }
  const remoteInsert = (index: number, text: string) => { authority.getText('content').insert(index,text); sequence++; receive(frame()) }
  return { authority, session, pending, message, select, remoteInsert }
}

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
