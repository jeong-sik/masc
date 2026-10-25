import { html } from 'htm/preact'
import { useLayoutEffect,useMemo,useRef,useState } from 'preact/hooks'
import { currentStoredTokenRevision,subscribeStoredTokenChanges } from '../../api/core'
import { captureArtifactWorkspace,type ArtifactDocument } from '../../api/published-artifacts'
import { readAppState } from '../../api/artifact-app-data'
import { artifactAppFrame,appFrameMessage,frameInputs } from '../../lib/artifact-app-frame'
import { ArtifactAppSession,type AppSessionSnapshot } from '../../lib/artifact-app-session'
import type { AppRecovery } from '../../lib/artifact-app-recovery'

function download(copy:AppRecovery):void {
  const url=URL.createObjectURL(new Blob([JSON.stringify(copy,null,2)],{type:'application/json;charset=utf-8'}))
  const link=document.createElement('a');link.href=url;link.download=`${copy.target.artifact_id}-v${copy.target.revision}-inputs.json`;link.click();URL.revokeObjectURL(url)
}
export function ArtifactAppView({doc,workspaceRoot,authRevision,isCurrent,onPending}:{doc:ArtifactDocument;workspaceRoot:string;authRevision:number;isCurrent:()=>boolean;onPending:(pending:boolean)=>void}) {
  const frame=useMemo(()=>artifactAppFrame(doc.content),[doc.content])
  const iframe=useRef<HTMLIFrameElement>(null),session=useRef<ArtifactAppSession|null>(null)
  const [state,setState]=useState<AppSessionSnapshot|null>(null),[error,setError]=useState(false),[attempt,setAttempt]=useState(0),[visible,setVisible]=useState(false)
  useLayoutEffect(()=>{
    let active=true,created:ArtifactAppSession|null=null
    const current=()=>active&&currentStoredTokenRevision()===authRevision&&isCurrent()
    const send=(type:string,fields:object)=>{if(current())iframe.current?.contentWindow?.postMessage({type,token:frame.token,...fields},'*')}
    const receive=(event:MessageEvent)=>{
      if(!current()||!created||event.source!==iframe.current?.contentWindow)return
      const message=appFrameMessage(frame,event.data);if(!message)return
      if(message.kind==='ready')send('masc.artifact.inputs.init.v1',{data:frameInputs(created.snapshot().data)})
      else if(message.kind==='initialized')setVisible(true)
      else created.input(message.data,message.change,message.commit)
    }
    const storage=()=>created?.refreshCopies()
    window.addEventListener('message',receive);window.addEventListener('storage',storage)
    const unsubscribe=subscribeStoredTokenChanges(()=>{if(!current()){created?.stop();setVisible(false)}})
    void (async()=>{
      try{
        const workspace=await captureArtifactWorkspace(workspaceRoot)
        if(!current())return
        const initial=await readAppState({artifact_id:doc.artifact.id,revision:doc.artifact.revision},workspace)
        if(!current())return
        created=new ArtifactAppSession({initial,workspace,current,changed:snapshot=>{onPending(snapshot.pending);setState(snapshot)},
          result:(change,status)=>send('masc.artifact.inputs.result.v1',{change,status,message:status==='error'?'저장 결과를 확인해 주세요. 입력은 보관했습니다.':undefined}),
          restore:data=>send('masc.artifact.inputs.restore.v1',{data})})
        session.current=created;setState(created.snapshot());setError(false)
      }catch{if(current())setError(true)}
    })()
    return ()=>{active=false;created?.stop();if(session.current===created)session.current=null;unsubscribe();window.removeEventListener('message',receive);window.removeEventListener('storage',storage);onPending(false)}
  },[frame,authRevision,workspaceRoot,doc.artifact.id,doc.artifact.revision,attempt])
  if(error&&!state)return html`<div class="p-4" role="alert">저장된 입력을 불러오지 못했습니다. 원본 탭에서 문서를 볼 수 있습니다. <button type="button" onClick=${()=>{setError(false);setAttempt(value=>value+1)}}>다시 불러오기</button></div>`
  if(!state)return html`<p role="status" class="p-4">저장된 입력을 불러오고 있습니다.</p>`
  const busy=state.mode==='saving'||state.mode==='checking'
  return html`<section aria-label="HTML 앱" class="flex min-h-0 flex-1 flex-col">
    <div class="shrink-0 border-b border-[var(--color-border-default)] px-4 py-2 text-xs space-y-2">
      <div class="flex flex-wrap items-center gap-3">
        <span role="status">${state.mode==='saving'?'입력을 저장하고 있습니다.':state.mode==='checking'?'저장 상태를 확인하고 있습니다.':state.mode==='unknown'?'저장 결과를 확인하지 못했습니다.':state.mode==='retry'?'앞선 요청은 아직 저장되지 않았습니다.':state.mode==='conflict'?'서버 입력과 이 창의 입력을 확인해 주세요.':state.pending?'아직 저장하지 않은 입력이 있습니다.':state.server.version>0?'입력이 저장됐습니다.':'입력 저장 준비가 됐습니다.'}</span>
        <button type="button" disabled=${state.mode!=='ready'||!state.pending} onClick=${()=>void session.current?.save()}>입력 저장</button>
        <button type="button" disabled=${busy} onClick=${()=>void session.current?.check()}>저장 상태 확인</button>
        ${state.mode==='retry'?html`<button type="button" onClick=${()=>void session.current?.retry()}>같은 요청 다시 저장</button>`:null}
        ${state.mode==='conflict'?html`<button type="button" onClick=${()=>{if(window.confirm('서버 입력을 이 창의 입력으로 바꿀까요?'))void session.current?.overwrite()}}>내 입력으로 저장</button>
          <button type="button" onClick=${()=>{if(window.confirm('이 창의 입력을 버리고 서버 입력을 불러올까요?'))session.current?.useServer()}}>서버 입력 사용</button>
          <details><summary>서버에 저장된 입력 보기</summary><pre class="whitespace-pre-wrap">${JSON.stringify(state.server.data,null,2)}</pre></details>`:null}
        ${state.recovery?html`<span>${state.recovery.persisted?'저장 전 입력을 이 브라우저에 보관했습니다.':'저장 전 입력이 이 창에만 있습니다.'}</span><button type="button" onClick=${()=>download(state.recovery!)}>입력 사본 내려받기</button>`:null}
      </div>
      ${state.copies.length?html`<details><summary>이전에 저장하지 못한 입력 ${state.copies.length}개</summary>${state.copies.map(copy=>html`<div key=${copy.revision} class="flex flex-wrap gap-3">
        <span>${new Date(copy.at).toLocaleString()}</span><button type="button" disabled=${state.pending||state.mode!=='ready'} onClick=${()=>session.current?.restore(copy)}>이전 입력 복원</button>
        <button type="button" onClick=${()=>download(copy)}>사본 내려받기</button><button type="button" onClick=${()=>{if(window.confirm('이 입력 사본을 삭제할까요?'))session.current?.discard(copy)}}>사본 삭제</button>
      </div>`)}</details>`:null}
    </div>
    <iframe ref=${iframe} title=${doc.artifact.title} sandbox="allow-scripts" referrerPolicy="no-referrer"
      class="min-h-0 w-full flex-1 border-0 bg-white" style=${{visibility:visible?'visible':'hidden'}} srcDoc=${frame.document} />
  </section>`
}
