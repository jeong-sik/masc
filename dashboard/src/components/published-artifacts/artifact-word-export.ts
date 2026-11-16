import { html } from 'htm/preact'
import { useLayoutEffect,useRef,useState } from 'preact/hooks'
import { currentStoredTokenRevision } from '../../api/core'
import type { ArtifactDocument } from '../../api/published-artifacts'

type Format='docx'|'hwpx'
type State={kind:'idle'}|{kind:'working';format:Format}|{kind:'error';format:Format;message:string}|{kind:'done';format:Format;notices:readonly string[]}
export function ArtifactWordExport({doc,authRevision,isCurrent,disabled}:{doc:ArtifactDocument;authRevision:number;isCurrent:()=>boolean;disabled:boolean}) {
  const active=useRef(true),working=useRef(false)
  const [state,setState]=useState<State>({kind:'idle'})
  useLayoutEffect(()=>()=>{active.current=false},[])
  const current=()=>active.current&&currentStoredTokenRevision()===authRevision&&isCurrent()
  const save=async(format:Format)=>{
    if(disabled||working.current||!current())return
    working.current=true;setState({kind:'working',format})
    try{
      const generate=format==='docx'?(await import('../../lib/artifact-word-export')).artifactWordFile
        :(await import('../../lib/artifact-hwpx-export')).artifactHwpxFile
      if(!current())return
      const file=await generate(doc)
      if(!current())return
      const mime=format==='docx'?'application/vnd.openxmlformats-officedocument.wordprocessingml.document':'application/hwp+zip'
      const url=URL.createObjectURL(new Blob([file.data],{type:mime}))
      try{
        const link=document.createElement('a');link.href=url;link.download=`${doc.artifact.id}-v${doc.artifact.revision}.${format}`;link.click()
      }finally{URL.revokeObjectURL(url)}
      setState({kind:'done',format,notices:file.notices})
    }catch(error){if(current())setState({kind:'error',format,message:error instanceof Error?error.message:'문서 변환에 실패했습니다.'})}
    finally{working.current=false}
  }
  return html`<details class="text-xs"><summary>Word·HWPX로 내보내기</summary>
    <p>현재 게시 버전의 본문을 .docx 또는 .hwpx로 만듭니다. 제목·문단·병합 표·차트 데이터를 옮깁니다.
      원본의 CSS 배치, 앱의 실행 화면과 현재 입력은 포함하지 않습니다. 외부 그림은 설명과 링크로 바꿉니다.</p>
    <button type="button" disabled=${disabled||state.kind==='working'} onClick=${()=>void save('docx')}>${state.kind==='working'&&state.format==='docx'?'Word 파일을 만들고 있습니다.':'Word 파일 다운로드'}</button>
    <button type="button" disabled=${disabled||state.kind==='working'} onClick=${()=>void save('hwpx')}>${state.kind==='working'&&state.format==='hwpx'?'HWPX 파일을 만들고 있습니다.':'HWPX 파일 다운로드'}</button>
    ${state.kind==='error'?html`<p role="alert">${state.format==='docx'?'Word':'HWPX'} 파일을 만들지 못했습니다. 문서를 유지했습니다. ${state.message}</p>`:null}
    ${state.kind==='done'?html`<p role="status">${state.format==='docx'?'Word':'HWPX'} 파일 다운로드를 요청했습니다. ${state.notices.join(' ')}</p>`:null}
  </details>`
}
