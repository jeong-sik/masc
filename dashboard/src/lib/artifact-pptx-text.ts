import type pptxgen from 'pptxgenjs'
export const pptxFonts={heading:'Noto Sans KR',body:'Noto Sans KR'} as const
export type PptxRun=pptxgen.TextProps&{text:string}
export type PptxMeasure=(text:string,size:number,face:keyof typeof pptxFonts,style?:pptxgen.TextPropsOptions)=>number
export function canvasPptxMeasure(context:Pick<CanvasRenderingContext2D,'font'|'measureText'>):PptxMeasure {
  return (text,size,face,style)=>{
    context.font=`${style?.italic?'italic ':''}${style?.bold?'bold ':''}${size}pt "${pptxFonts[face]}"`
    // Canvas reports CSS pixels (96/in); PowerPoint geometry uses points (72/in).
    return context.measureText(text).width*72/96
  }
}
export function wrapPptxRuns(runs:readonly PptxRun[],width:number,size:number,face:keyof typeof pptxFonts,measure:PptxMeasure):PptxRun[][] {
  const lines:PptxRun[][]=[]
  let line:PptxRun[]=[],used=0
  const flush=()=>{lines.push(line);line=[];used=0}
  const words=new Intl.Segmenter(undefined,{granularity:'word'}),graphemes=new Intl.Segmenter(undefined,{granularity:'grapheme'})
  const append=(value:string,options:pptxgen.TextPropsOptions|undefined)=>{
    const advance=measure(value,size,face,options)
    if(!Number.isFinite(advance)||advance<0||advance>width)throw new Error('글자를 슬라이드 너비에 배치할 수 없습니다.')
    if(used+advance>width&&line.length)flush()
    const previous=line.at(-1)
    if(previous&&previous.options===options)previous.text+=value
    else line.push({text:value,options})
    used+=advance
  }
  for(const run of runs){
    const pieces=run.text.replaceAll('\r\n','\n').replaceAll('\r','\n').split('\n')
    for(const [index,piece]of pieces.entries()){
      if(index)flush()
      for(const {segment}of words.segment(piece)){
        const advance=measure(segment,size,face,run.options)
        if(advance<=width)append(segment,run.options)
        else for(const {segment:character}of graphemes.segment(segment))append(character,run.options)
      }
    }
  }
  if(line.length||!lines.length)flush()
  return lines
}
