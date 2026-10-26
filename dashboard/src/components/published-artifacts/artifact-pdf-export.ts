import { html } from 'htm/preact'
import { useLayoutEffect,useRef,useState } from 'preact/hooks'
import { currentStoredTokenRevision } from '../../api/core'
import type { ArtifactDocument } from '../../api/published-artifacts'

type State={kind:'idle'}|{kind:'working'}|{kind:'error'}|{kind:'done';notices:readonly string[]}
export function ArtifactPdfExport({doc,authRevision,isCurrent,disabled}:{doc:ArtifactDocument;authRevision:number;isCurrent:()=>boolean;disabled:boolean}) {
  const active=useRef(true),working=useRef(false)
  const [state,setState]=useState<State>({kind:'idle'})
  useLayoutEffect(()=>()=>{active.current=false},[])
  const current=()=>active.current&&currentStoredTokenRevision()===authRevision&&isCurrent()
  const save=async()=>{
    if(disabled||working.current||!current())return
    working.current=true;setState({kind:'working'})
    try{
      const {artifactPdfFile}=await import('../../lib/artifact-pdf-export')
      if(!current())return
      const {loadArtifactPdfFonts}=await import('../../lib/artifact-pdf-fonts')
      if(!current())return
      const fonts=await loadArtifactPdfFonts()
      if(!current())return
      const file=await artifactPdfFile(doc,fonts)
      if(!current())return
      const url=URL.createObjectURL(new Blob([file.data],{type:'application/pdf'}))
      try{
        const link=document.createElement('a');link.href=url;link.download=`${doc.artifact.id}-v${doc.artifact.revision}.pdf`;link.click()
      }finally{URL.revokeObjectURL(url)}
      setState({kind:'done',notices:file.notices})
    }catch{if(current())setState({kind:'error'})}
    finally{working.current=false}
  }
  return html`<details class="text-xs"><summary>PDF로 내보내기</summary>
    <p>현재 게시 버전의 본문을 .pdf로 만듭니다. 제목·목록·표·링크·문서에 포함된 PNG·JPEG 그림을 옮깁니다.
      원본의 CSS 배치, 앱의 실행 화면과 현재 입력은 포함하지 않습니다. 외부 그림은 설명과 링크로 바꿉니다. 한글·굵은 글씨·단색 이모지 글꼴을 파일에 포함합니다. 넓은 표는 열을 나눠 표시합니다. 기울임은 일반 글꼴로 옮기며, 글꼴에 없는 문자는 유니코드 번호로 표시합니다.</p>
    <button type="button" disabled=${disabled||state.kind==='working'} onClick=${()=>void save()}>${state.kind==='working'?'PDF 파일을 만들고 있습니다.':'PDF 파일 다운로드'}</button>
    ${state.kind==='error'?html`<p role="alert">PDF 파일을 만들지 못했습니다. 문서를 유지했습니다. 다시 시도하거나 원본을 내려받아 주세요.</p>`:null}
    ${state.kind==='done'?html`<p role="status">PDF 파일 다운로드를 요청했습니다. ${state.notices.join(' ')}</p>`:null}
  </details>`
}
