import { html } from 'htm/preact'
import { useLayoutEffect,useRef,useState } from 'preact/hooks'
import { currentStoredTokenRevision } from '../../api/core'
import type { ArtifactDocument } from '../../api/published-artifacts'
import { canvasPptxMeasure } from '../../lib/artifact-pptx-text'

type State={kind:'idle'}|{kind:'working'}|{kind:'error'}|{kind:'done';notices:readonly string[]}
export function ArtifactPptxExport({doc,authRevision,isCurrent,disabled}:{doc:ArtifactDocument;authRevision:number;isCurrent:()=>boolean;disabled:boolean}) {
  const active=useRef(true),working=useRef(false)
  const [state,setState]=useState<State>({kind:'idle'})
  useLayoutEffect(()=>()=>{active.current=false},[])
  const current=()=>active.current&&currentStoredTokenRevision()===authRevision&&isCurrent()
  const save=async()=>{
    if(disabled||working.current||!current())return
    working.current=true;setState({kind:'working'})
    try{
      const {artifactPptxFile}=await import('../../lib/artifact-pptx-export')
      if(!current())return
      await document.fonts.ready
      if(!current())return
      const context=document.createElement('canvas').getContext('2d')
      if(!context)throw new Error('글자 크기를 측정할 수 없습니다.')
      const file=await artifactPptxFile(doc,canvasPptxMeasure(context))
      if(!current())return
      const url=URL.createObjectURL(new Blob([file.data],{type:'application/vnd.openxmlformats-officedocument.presentationml.presentation'}))
      try{
        const link=document.createElement('a');link.href=url;link.download=`${doc.artifact.id}-v${doc.artifact.revision}.pptx`;link.click()
      }finally{URL.revokeObjectURL(url)}
      setState({kind:'done',notices:file.notices})
    }catch{if(current())setState({kind:'error'})}
    finally{working.current=false}
  }
  return html`<details class="text-xs"><summary>PPT로 내보내기</summary>
    <p>현재 게시 버전의 본문을 .pptx로 만듭니다. 제목·본문·표·그림을 슬라이드에 나누며, 긴 본문과 표는 여러 슬라이드에 이어집니다.
      Noto Sans KR 글꼴이 없는 환경에서는 줄바꿈이 달라질 수 있습니다. 원본의 CSS 배치, 앱의 실행 화면과 현재 입력은 포함하지 않습니다. 외부 그림과 표 안의 그림은 설명과 링크로 바꿉니다. 병합 표는 각 행·열에 값을 반복해 풀어 씁니다. 표 안의 서식은 일반 글자와 줄바꿈으로 옮기며 링크 주소를 함께 표시합니다.</p>
    <button type="button" disabled=${disabled||state.kind==='working'} onClick=${()=>void save()}>${state.kind==='working'?'PPT 파일을 만들고 있습니다.':'PPT 파일 다운로드'}</button>
    ${state.kind==='error'?html`<p role="alert">PPT 파일을 만들지 못했습니다. 문서를 유지했습니다. 다시 시도하거나 원본을 내려받아 주세요.</p>`:null}
    ${state.kind==='done'?html`<p role="status">PPT 파일 다운로드를 요청했습니다. ${state.notices.join(' ')}</p>`:null}
  </details>`
}
