import { html } from 'htm/preact'
import { act,cleanup,render,screen,fireEvent,waitFor } from '@testing-library/preact'
import { beforeEach,afterEach,expect,it,vi } from 'vitest'
import { setStoredToken,clearStoredToken,currentStoredTokenRevision,get,getWithResponse,post } from '../../api/core'
import type { ArtifactDocument } from '../../api/published-artifacts'
import type { AppState,AppRequest } from '../../api/artifact-app-data'
import { artifactAppFrame,type AppFrame } from '../../lib/artifact-app-frame'
import { appInputRecoveries,discardAppInput } from '../../lib/artifact-app-recovery'
import { ArtifactAppView } from './artifact-app-view'
vi.mock('../../api/core',async original=>({...await original<typeof import('../../api/core')>(),get:vi.fn(),getWithResponse:vi.fn(),post:vi.fn()}))
vi.mock('../../lib/artifact-app-frame',async original=>{const module=await original<typeof import('../../lib/artifact-app-frame')>();return {...module,artifactAppFrame:vi.fn(module.artifactAppFrame)}})
const workspace={basePath:'/app-view',mascRoot:'/app-view/.masc'},target={artifact_id:`artifact-${'d'.repeat(32)}`,revision:1}
const initial:AppState={schema:'masc.artifact_app_data.v1',target,actor:'human',version:0,data:{},receipts:[]}
const doc:ArtifactDocument={artifact:{id:target.artifact_id,revision:1,title:'메모',summary:'개인 메모',format:'html',author:'keeper',created_at:'now',task_id:null,goal_id:null,url:'/',body:{_blob:{sha256:'a'.repeat(64)}}},content:'<textarea>기본값</textarea>',revisions:[]}
let server=initial
const confirmDescriptor=Object.getOwnPropertyDescriptor(window,'confirm')
beforeEach(()=>{
  server=initial;vi.mocked(get).mockReset();vi.mocked(getWithResponse).mockReset();vi.mocked(post).mockReset();vi.mocked(artifactAppFrame).mockClear();setStoredToken('app-view-credential')
  vi.mocked(get).mockImplementation(async path=>path==='/health?full=1'?{paths:{effective_base_path:workspace.basePath,effective_masc_root:workspace.mascRoot}}:server)
  vi.mocked(getWithResponse).mockImplementation(async (path,options)=>({data:await get(path,options),headers:new Headers({'x-masc-workspace-read':'matched-v1'})}))
  vi.mocked(post).mockImplementation(async(_path,body)=>{
    const request=body as AppRequest
    server={...server,data:request.data,version:request.expected_version+1,receipts:[...server.receipts,{id:request.id,expected_version:request.expected_version,data_sha256:'a'.repeat(64),at:'now'}]}
    return server
  })
})
afterEach(()=>{cleanup();clearStoredToken();for(const copy of appInputRecoveries(workspace,initial))discardAppInput(copy);localStorage.clear();vi.restoreAllMocks();if(confirmDescriptor)Object.defineProperty(window,'confirm',confirmDescriptor);else Reflect.deleteProperty(window,'confirm')})
async function open(){
  const onPending=vi.fn(),isCurrent=()=>true
  const result=render(html`<${ArtifactAppView} doc=${doc} capturedWorkspace=${workspace} authRevision=${currentStoredTokenRevision()} isCurrent=${isCurrent} onPending=${onPending} />`)
  const iframe=await screen.findByTitle('메모') as HTMLIFrameElement
  const frame=vi.mocked(artifactAppFrame).mock.results.at(-1)!.value as AppFrame
  const send=async(fields:object,source:MessageEventSource|null=iframe.contentWindow)=>{
    await act(async()=>{window.dispatchEvent(new MessageEvent('message',{source,data:{token:frame.token,instance:'first-document',...fields}}))})
  }
  await send({type:'masc.artifact.inputs.ready.v1'});await send({type:'masc.artifact.inputs.initialized.v1'})
  return {...result,iframe,frame,send,onPending}
}
it('accepts only its actual frame, saves committed input and restores unsent input explicitly after remount',async()=>{
  const first=await open(),data={forms:{'0':{kind:'value',type:'textarea',value:'다시 열 메모 😀'}},app:{}}
  await first.send({type:'masc.artifact.inputs.change.v1',change:1,commit:true,data},window)
  expect(post).not.toHaveBeenCalled()
  await first.send({type:'masc.artifact.inputs.change.v1',change:1,commit:true,data})
  await screen.findByText('입력이 저장됐습니다.');expect(post).toHaveBeenCalledTimes(1)
  expect(vi.mocked(post).mock.calls[0]![1]).toMatchObject({target,data,expected_version:0})
  const unsent={forms:{'0':{kind:'value',type:'textarea',value:'아직 보내지 않은 메모'}},app:{}}
  await first.send({type:'masc.artifact.inputs.change.v1',change:2,commit:false,data:unsent})
  expect(first.onPending).toHaveBeenLastCalledWith(true);first.unmount()
  const second=await open()
  await screen.findByRole('button',{name:'이전 입력 복원'})
  expect(post).toHaveBeenCalledTimes(1)
  fireEvent.click(screen.getByRole('button',{name:'이전 입력 복원'}))
  await screen.findByText('서버 입력과 이 창의 입력을 확인해 주세요.')
  expect(post).toHaveBeenCalledTimes(1)
  Object.defineProperty(window,'confirm',{configurable:true,value:vi.fn(()=>true)})
  fireEvent.click(screen.getByRole('button',{name:'내 입력으로 저장'}))
  await waitFor(()=>expect(post).toHaveBeenCalledTimes(2))
  expect(vi.mocked(post).mock.calls[1]![1]).toMatchObject({data:unsent,expected_version:1})
  expect(second.iframe.getAttribute('sandbox')).toBe('allow-scripts')
})
it('stops a cached handler immediately on credential replacement, preserving its pending input',async()=>{
  const {send,iframe}=await open()
  await send({type:'masc.artifact.inputs.change.v1',change:1,commit:false,data:{forms:{},app:{memo:'보관할 입력'}}})
  const reads=vi.mocked(get).mock.calls.length
  await act(async()=>setStoredToken('another-user'))
  await send({type:'masc.artifact.inputs.change.v1',change:2,commit:true,data:{forms:{},app:{memo:'must not send'}}})
  fireEvent.click(screen.getByRole('button',{name:'저장 상태 확인'}))
  expect(get).toHaveBeenCalledTimes(reads);expect(post).not.toHaveBeenCalled()
  expect(iframe.style.visibility).toBe('hidden')
  expect(appInputRecoveries(workspace,initial)[0]?.data).toEqual({forms:{},app:{memo:'보관할 입력'}})
})
it('accepts new input after the same iframe restarts its bootstrap counter',async()=>{
  const {send}=await open()
  await send({type:'masc.artifact.inputs.change.v1',instance:'first-document',change:1,commit:true,data:{forms:{},app:{memo:'first'}}})
  await screen.findByText('입력이 저장됐습니다.')
  await send({type:'masc.artifact.inputs.ready.v1',instance:'reloaded-document'})
  await send({type:'masc.artifact.inputs.initialized.v1',instance:'reloaded-document'})
  await send({type:'masc.artifact.inputs.change.v1',instance:'reloaded-document',change:1,commit:true,data:{forms:{},app:{memo:'after reload'}}})
  await waitFor(()=>expect(post).toHaveBeenCalledTimes(2))
  expect(server.data).toEqual({forms:{},app:{memo:'after reload'}})
  await send({type:'masc.artifact.inputs.change.v1',instance:'first-document',change:99,commit:true,data:{forms:{},app:{memo:'late old input'}}})
  expect(post).toHaveBeenCalledTimes(2);expect(server.data).toEqual({forms:{},app:{memo:'after reload'}})
})
it('applies confirmed connections without losing edits or accepting the retired frame',async()=>{
  const {iframe,send,frame}=await open()
  const reads=vi.mocked(get).mock.calls.length
  await send({type:'masc.artifact.inputs.change.v1',change:1,commit:false,data:{forms:{},app:{memo:'저장 전'}}})
  const field=screen.getByRole('textbox',{name:'허용할 외부 출처'})
  fireEvent.input(field,{target:{value:'https://example.com/path'}})
  fireEvent.click(screen.getByRole('button',{name:'연결 설정 저장'}))
  expect(post).not.toHaveBeenCalled();expect(screen.getByRole('alert')).toBeTruthy()
  let finish!:(state:AppState)=>void
  vi.mocked(post).mockImplementationOnce(()=>new Promise<AppState>(resolve=>{finish=resolve}))
  fireEvent.input(field,{target:{value:'https://API.example.com:443\nhttps://cdn.example.com\nhttps://api.example.com'}})
  fireEvent.click(screen.getByRole('button',{name:'연결 설정 저장'}))
  await waitFor(()=>expect(post).toHaveBeenCalledTimes(1))
  const request=vi.mocked(post).mock.calls[0]![1] as AppRequest
  expect(request.data).toEqual({forms:{},app:{memo:'저장 전'},resource_origins:['https://api.example.com','https://cdn.example.com']})
  expect(iframe.srcdoc).toBe(frame.document)
  await send({type:'masc.artifact.inputs.change.v1',change:2,commit:false,data:{forms:{},app:{memo:'응답 전 새 입력'}}})
  server={...initial,version:1,data:request.data,receipts:[{id:request.id,expected_version:0,data_sha256:'a'.repeat(64),at:'now'}]}
  const messages=vi.spyOn(iframe.contentWindow!,'postMessage')
  await act(async()=>finish(server))
  await waitFor(()=>expect(messages).toHaveBeenCalledWith(expect.objectContaining({type:'masc.artifact.inputs.suspend.v1'}),'*'))
  expect(iframe.srcdoc).toBe(frame.document)
  await send({type:'masc.artifact.inputs.change.v1',change:3,commit:false,data:{forms:{},app:{memo:'응답 뒤 전달된 입력'}}})
  await send({type:'masc.artifact.inputs.suspended.v1',change:2,data:{forms:{},app:{memo:'stale capture'}}})
  expect(iframe.srcdoc).toBe(frame.document)
  await send({type:'masc.artifact.inputs.suspended.v1',change:4,data:{forms:{},app:{memo:'응답 뒤 전달된 입력'}}})
  await waitFor(()=>expect(iframe.srcdoc).toContain('connect-src https://api.example.com https://cdn.example.com;'))
  const next=vi.mocked(artifactAppFrame).mock.results.at(-1)!.value as AppFrame
  expect(next.token).not.toBe(frame.token)
  expect(iframe.srcdoc).toContain('connect-src https://api.example.com https://cdn.example.com;')
  expect(iframe.style.visibility).toBe('hidden')
  const newMessages=vi.spyOn(iframe.contentWindow!,'postMessage')
  await act(async()=>{window.dispatchEvent(new MessageEvent('message',{source:iframe.contentWindow,data:{token:next.token,instance:'resources-document',type:'masc.artifact.inputs.ready.v1'}}))})
  expect(newMessages).toHaveBeenLastCalledWith(expect.objectContaining({data:{forms:{},app:{memo:'응답 뒤 전달된 입력'}}}),'*')
  await send({type:'masc.artifact.inputs.change.v1',change:99,commit:true,data:{forms:{},app:{memo:'retired'}}})
  expect(post).toHaveBeenCalledTimes(1)
  await act(async()=>{window.dispatchEvent(new MessageEvent('message',{source:iframe.contentWindow,data:{token:next.token,instance:'resources-document',type:'masc.artifact.inputs.change.v1',change:1,commit:true,data:{forms:{},app:{memo:'새 문서 입력'},resource_origins:['https://attacker.example']}}}))})
  await waitFor(()=>expect(post).toHaveBeenCalledTimes(2))
  expect((vi.mocked(post).mock.calls[1]![1] as AppRequest).data).toEqual({forms:{},app:{memo:'새 문서 입력'},resource_origins:['https://api.example.com','https://cdn.example.com']})
  expect(get).toHaveBeenCalledTimes(reads)
})
it('keeps connections closed after a lost response until GET confirms the exact saved request',async()=>{
  const {iframe,frame,send}=await open()
  vi.mocked(post).mockImplementationOnce(async(_path,body)=>{
    const request=body as AppRequest
    server={...initial,version:1,data:request.data,receipts:[{id:request.id,expected_version:0,data_sha256:'a'.repeat(64),at:'now'}]}
    throw new Error('ACK lost')
  })
  fireEvent.input(screen.getByRole('textbox',{name:'허용할 외부 출처'}),{target:{value:'https://api.example.com'}})
  fireEvent.click(screen.getByRole('button',{name:'연결 설정 저장'}))
  await screen.findByText('저장 결과를 확인하지 못했습니다.')
  expect(iframe.srcdoc).toBe(frame.document)
  fireEvent.click(screen.getByRole('button',{name:'저장 상태 확인'}))
  await screen.findByText('입력이 저장됐습니다.')
  expect(iframe.srcdoc).toBe(frame.document)
  await send({type:'masc.artifact.inputs.suspended.v1',change:1,data:{forms:{},app:{}}})
  await waitFor(()=>expect(iframe.srcdoc).toContain('connect-src https://api.example.com;'))
  expect(post).toHaveBeenCalledTimes(1)
})
it('refuses malformed stored resource authority instead of opening the frame',async()=>{
  server={...initial,data:{resource_origins:['https://good.example; connect-src *']}}
  render(html`<${ArtifactAppView} doc=${doc} capturedWorkspace=${workspace} authRevision=${currentStoredTokenRevision()} isCurrent=${()=>true} onPending=${()=>{}} />`)
  await screen.findByRole('alert')
  expect(screen.queryByTitle('메모')).toBeNull();expect(post).not.toHaveBeenCalled()
})

it('lets the host apply revocation explicitly when the child does not acknowledge suspension',async()=>{
  server={...initial,data:{resource_origins:['https://api.example.com']}}
  const {iframe,frame,send}=await open()
  await send({type:'masc.artifact.inputs.change.v1',change:1,commit:false,data:{forms:{},app:{memo:'부모에 보관한 입력'}}})
  fireEvent.input(screen.getByRole('textbox',{name:'허용할 외부 출처'}),{target:{value:''}})
  fireEvent.click(screen.getByRole('button',{name:'연결 설정 저장'}))
  await screen.findByText('연결 설정은 저장됐습니다. 적용하기 전에 문서의 마지막 입력을 기다리고 있습니다.')
  expect(iframe.srcdoc).toBe(frame.document)
  Object.defineProperty(window,'confirm',{configurable:true,value:vi.fn(()=>false)})
  const force=screen.getByRole('button',{name:'마지막 입력을 받지 않고 다시 열기'})
  fireEvent.click(force);expect(iframe.srcdoc).toBe(frame.document)
  Object.defineProperty(window,'confirm',{configurable:true,value:vi.fn(()=>true)})
  fireEvent.click(force)
  await waitFor(()=>expect(iframe.srcdoc).toContain("connect-src 'none';"))
  expect(server.data).toEqual({forms:{},app:{memo:'부모에 보관한 입력'},resource_origins:[]})
  expect(post).toHaveBeenCalledTimes(1)
  expect(screen.queryByRole('button',{name:'마지막 입력을 받지 않고 다시 열기'})).toBeNull()
})

it('withdraws force reopen authority when credentials change during confirmation',async()=>{
  server={...initial,data:{resource_origins:['https://api.example.com']}}
  const {iframe,frame}=await open()
  fireEvent.input(screen.getByRole('textbox',{name:'허용할 외부 출처'}),{target:{value:''}})
  fireEvent.click(screen.getByRole('button',{name:'연결 설정 저장'}))
  const force=await screen.findByRole('button',{name:'마지막 입력을 받지 않고 다시 열기'})
  Object.defineProperty(window,'confirm',{configurable:true,value:()=>{setStoredToken('new-user-during-confirm');return true}})
  fireEvent.click(force)
  expect(iframe.srcdoc).toBe(frame.document)
  expect(iframe.style.visibility).toBe('hidden');expect(post).toHaveBeenCalledTimes(1)
})
