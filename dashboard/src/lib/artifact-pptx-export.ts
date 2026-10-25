import pptxgen from 'pptxgenjs'
import JSZip from 'jszip'
import { DOMParser,XMLSerializer } from '@xmldom/xmldom'
import { parse,defaultTreeAdapter as tree,html,type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { fromMarkdown } from 'mdast-util-from-markdown'
import { gfmFromMarkdown } from 'mdast-util-gfm'
import { gfm } from 'micromark-extension-gfm'
import { toHast } from 'mdast-util-to-hast'
import { raw } from 'hast-util-raw'
import { toHtml } from 'hast-util-to-html'
import { imageDimensionsFromData } from 'image-dimensions'
import type { ArtifactDocument } from '../api/published-artifacts'
import { pptxFonts,wrapPptxRuns,type PptxMeasure,type PptxRun } from './artifact-pptx-text'

const palette={dk1:'212121',lt1:'FFFFFF',dk2:'36454F',lt2:'F2F4F7',accent1:'187B68',accent2:'526D82',accent3:'AE5E36',accent4:'74658C',accent5:'537D45',accent6:'9C5764',hlink:'187B68',folHlink:'74658C'}
const omitted=new Set(['head','script','style','template','noscript','meta','link','base','title'])
const dynamic=new Set(['iframe','object','embed','canvas','svg','math','video','audio','button','select','textarea'])
const containers=new Set(['html','body','main','article','section','header','footer','nav','aside','div','figure','figcaption','details','summary','form','address','blockquote'])
const headings=new Set(['h1','h2','h3','h4','h5','h6'])
const cellBlocks=new Set([...headings,...containers,'p','li','pre','table','thead','tbody','tfoot','tr','td','th','dl','dt','dd'])
const attr=(node:Nodes.Element,name:string)=>node.attrs.find(item=>item.name===name)?.value
const drawing='http://schemas.openxmlformats.org/drawingml/2006/main'
type Run=PptxRun
type Cell={text:string;header:boolean}
type Part={kind:'heading';text:string}|{kind:'text';runs:Run[];bullet?:pptxgen.TextPropsOptions['bullet'];depth?:number}|{kind:'table';rows:Cell[][];headers:number}|{kind:'image';data:string;width:number;height:number;alt:string}
export type ArtifactPptxFile={data:ArrayBuffer;notices:readonly string[];slides:number}
function integer(value:string|undefined,fallback:number):number {if(value===undefined||!/^[-+]?\d+$/.test(value.trim()))return fallback;const number=Number(value);return Number.isSafeInteger(number)?number:fallback}
function safeLink(value:string|undefined):string|null {if(!value)return null;try{const url=new URL(value);return ['http:','https:','mailto:','tel:'].includes(url.protocol)?url.href:null}catch{return null}}

// Like the skill's apply_theme.js, update the generated theme after packing.
// Use a structured XML parser here so the converter also runs in the browser.
async function packed(data:ArrayBuffer):Promise<ArrayBuffer> {
  const zip=await JSZip.loadAsync(data),part=zip.file('ppt/theme/theme1.xml')
  if(!part)throw new Error('PPT 테마를 찾지 못했습니다.')
  const xml=new DOMParser().parseFromString(await part.async('string'),'application/xml')
  const scheme=xml.getElementsByTagNameNS(drawing,'clrScheme')[0]
  if(!xml.documentElement||!scheme)throw new Error('PPT 색상 테마를 읽지 못했습니다.')
  for(const [slot,color] of Object.entries(palette)){
    const node=xml.getElementsByTagNameNS(drawing,slot)[0]
    if(!node)throw new Error('PPT 색상 테마가 올바르지 않습니다.')
    while(node.firstChild)node.removeChild(node.firstChild)
    const replacement=xml.createElementNS(drawing,'a:srgbClr');replacement.setAttribute('val',color);node.appendChild(replacement)
  }
  xml.documentElement.setAttribute('name','MASC report')
  scheme.setAttribute('name','MASC report')
  xml.getElementsByTagNameNS(drawing,'fontScheme')[0]!.setAttribute('name','MASC report')
  const serializer=new XMLSerializer()
  zip.file('ppt/theme/theme1.xml',serializer.serializeToString(xml))
  // PptxGenJS writes paragraph properties again for rich runs. In DrawingML
  // the first run defines this paragraph; subsequent inline styles must not reset its bullet.
  for(const path of Object.keys(zip.files).filter(path=>path.startsWith('ppt/slides/')&&path.endsWith('.xml'))){
    const part=new DOMParser().parseFromString(await zip.file(path)!.async('string'),'application/xml')
    for(const paragraph of Array.from(part.getElementsByTagNameNS(drawing,'p'))){
      const properties=Array.from(paragraph.childNodes).filter(node=>node.nodeType===1&&node.namespaceURI===drawing&&node.localName==='pPr')
      const first=properties[0]
      if(!first)continue
      for(const duplicate of properties.slice(1)){
        paragraph.removeChild(duplicate)
      }
      if(paragraph.firstChild!==first)paragraph.insertBefore(first,paragraph.firstChild)
    }
    zip.file(path,serializer.serializeToString(part))
  }
  return zip.generateAsync({type:'arraybuffer',compression:'DEFLATE'})
}
export async function artifactPptxFile(doc:ArtifactDocument,measure:PptxMeasure):Promise<ArtifactPptxFile> {
  const notices=new Set<string>(),parts:Part[]=[]
  function clean(value:string):string {
    return Array.from(value,character=>{
      const code=character.codePointAt(0)!
      if(code===9||code===10||code===13||(code>=32&&code<=0xD7FF)||(code>=0xE000&&code<=0xFFFD)||(code>=0x10000&&code<=0x10FFFF))return character
      notices.add('PPT에서 표현할 수 없는 문자는 대체 문자로 바꿨습니다.');return '\uFFFD'
    }).join('')
  }
  function picture(node:Nodes.Element):void {
    const src=attr(node,'src')??'',alt=clean(attr(node,'alt')||'그림'),match=/^data:image\/(png|jpeg);base64,([A-Za-z0-9+/]*={0,2})$/.exec(src)
    if(match){try{
      const size=imageDimensionsFromData(Uint8Array.from(atob(match[2]!),character=>character.charCodeAt(0)))
      if(size&&size.type===match[1]&&size.width>0&&size.height>0){parts.push({kind:'image',data:src,width:size.width,height:size.height,alt});return}
    }catch{/* Preserve the description instead of passing unreadable media. */}}
    notices.add('외부 그림과 읽을 수 없는 그림은 설명과 링크로 바꿨습니다.')
    const link=safeLink(src);parts.push({kind:'text',runs:[{text:`[그림: ${alt}]`,options:link?{hyperlink:{url:link}}:{}}]})
  }
  function runs(nodes:readonly Nodes.ChildNode[],style:pptxgen.TextPropsOptions={},pre=false):Run[] {
    const result:Run[]=[]
    for(const node of nodes){
      if(tree.isTextNode(node))result.push({text:pre?clean(node.value):clean(node.value).replace(/[\t\n\f\r ]+/g,' '),options:{...style}})
      else if(tree.isElementNode(node)){
        if(omitted.has(node.tagName))continue
        if(dynamic.has(node.tagName)||node.namespaceURI!==html.NS.HTML){notices.add('앱·영상·도형의 실행 화면은 포함하지 않았습니다.');continue}
        if(node.tagName==='br'){result.push({text:'\n',options:{...style}});continue}
        if(node.tagName==='input'){
          if(attr(node,'type')==='checkbox')result.push({text:attr(node,'checked')!==undefined?'☑ ':'☐ ',options:{...style}})
          else notices.add('앱 입력칸의 현재 값은 포함하지 않았습니다.')
          continue
        }
        const next={...style}
        if(node.tagName==='strong'||node.tagName==='b')next.bold=true
        if(node.tagName==='em'||node.tagName==='i')next.italic=true
        if(node.tagName==='s'||node.tagName==='del')next.strike=true
        if(node.tagName==='u')next.underline={}
        if(node.tagName==='sup'){delete next.subscript;next.superscript=true}
        if(node.tagName==='sub'){delete next.superscript;next.subscript=true}
        if(node.tagName==='a'){const link=safeLink(attr(node,'href'));if(link)next.hyperlink={url:link}}
        if(node.tagName==='img'){const link=safeLink(attr(node,'src'));result.push({text:`[그림: ${clean(attr(node,'alt')||'그림')}]`,options:link?{...next,hyperlink:{url:link}}:next});notices.add('표 안의 그림은 설명으로 바꿨습니다.');continue}
        const block=cellBlocks.has(node.tagName)
        if(block&&result.length&&result.at(-1)?.text!=='\n')result.push({text:'\n'})
        result.push(...runs(node.childNodes,next,pre||node.tagName==='pre'))
        if(block)result.push({text:'\n'})
      }
    }
    return result
  }
  function table(node:Nodes.Element):void {
    const groups=node.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&['thead','tbody','tfoot'].includes(child.tagName))
      .map(group=>group.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='tr'))
    const rows:Cell[][]=[],caption=node.childNodes.find((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='caption')
    if(caption)parts.push({kind:'text',runs:runs(caption.childNodes)})
    let headers=0
    for(const group of groups){
      const grid:Cell[][]=group.map(()=>[])
      for(const [index,row] of group.entries()){
        const cells=row.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&(child.tagName==='th'||child.tagName==='td'))
        if(rows.length+index===headers&&cells.length&&cells.every(cell=>cell.tagName==='th'))headers++
        let column=0
        for(const cell of cells){
          while(grid[index]![column])column++
          // WHATWG table processing: colspan <=1000, rowspan <=65534; zero reaches the row-group end.
          const width=Math.min(1000,Math.max(1,integer(attr(cell,'colspan'),1))),span=integer(attr(cell,'rowspan'),1)
          const height=span===0?group.length-index:Math.min(group.length-index,65534,Math.max(1,span))
          const content=runs(cell.childNodes),links=[...new Set(content.flatMap(run=>run.options?.hyperlink?.url?[run.options.hyperlink.url]:[]))]
          const value={text:content.map(run=>run.text).join('').trimEnd()+links.map(link=>`\n${link}`).join(''),header:cell.tagName==='th'}
          for(let y=index;y<index+height;y++)for(let x=column;x<column+width;x++)grid[y]![x]=value
          column+=width
          if(width>1||height>1)notices.add('병합 표는 각 행·열에 값을 반복해 풀어 썼습니다.')
        }
      }
      rows.push(...grid)
    }
    const width=Math.max(0,...rows.map(row=>row.length))
    if(width){
      notices.add('표 셀은 일반 글자와 줄바꿈으로 옮겼습니다. 셀 안의 링크는 주소도 함께 표시했습니다.')
      parts.push({kind:'table',rows:rows.map(row=>Array.from({length:width},(_,column)=>row[column]??{text:'',header:false})),headers})
    }
  }

  type List={bullet:pptxgen.TextPropsOptions['bullet'];depth:number;used:boolean;prefix?:string}
  function blocks(nodes:readonly Nodes.ChildNode[],list?:List,pre=false):void {
    const pending:Nodes.ChildNode[]=[]
    const flush=()=>{const text=runs(pending,{},pre);if(text.some(run=>run.text.trim())){
      if(list&&!list.used&&list.prefix)text[0]!.text=list.prefix+text[0]!.text
      parts.push({kind:'text',runs:text,bullet:list&&!list.used?list.bullet:undefined,depth:list?.depth});if(list)list.used=true
    }pending.length=0}
    for(const node of nodes){
      if(!tree.isElementNode(node)){if(tree.isTextNode(node))pending.push(node);continue}
      if(omitted.has(node.tagName))continue
      if(dynamic.has(node.tagName)||node.namespaceURI!==html.NS.HTML){flush();notices.add('앱·영상·도형의 실행 화면은 포함하지 않았습니다.');continue}
      if(headings.has(node.tagName)){flush();parts.push({kind:'heading',text:runs(node.childNodes).map(run=>run.text).join('')})}
      else if(node.tagName==='ul'||node.tagName==='ol'){
        flush();const items=node.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='li'),reversed=attr(node,'reversed')!==undefined
        let ordinal=integer(attr(node,'start'),reversed?items.length:1)
        for(const item of items){
          ordinal=integer(attr(item,'value'),ordinal)
          // DrawingML ST_TextBulletStartAtNum is restricted to 1..32767.
          const manual=node.tagName==='ol'&&(ordinal<1||ordinal>32767)
          if(manual)notices.add('PPT 번호 범위를 벗어난 목록은 번호를 글자로 표시했습니다.')
          const entry:List={depth:list?list.depth+1:0,used:false,prefix:manual?`${ordinal}. `:undefined,
            bullet:manual?undefined:node.tagName==='ol'?{type:'number',numberStartAt:ordinal,indent:18}:{indent:18}}
          blocks(item.childNodes,entry)
          if(!entry.used)parts.push({kind:'text',runs:[{text:entry.prefix??' '}],bullet:entry.bullet,depth:entry.depth})
          ordinal+=reversed?-1:1
        }
      }else if(node.tagName==='table'){flush();table(node)}
      else if(node.tagName==='img'){flush();picture(node)}
      else if(node.tagName==='pre'){flush();blocks(node.childNodes,list,true)}
      else if(node.tagName==='p'||containers.has(node.tagName)){flush();blocks(node.childNodes,list,pre)}
      else if(node.tagName==='hr'){flush()}
      else{
        // Keep images in source order even when nested in inline wrappers.
        const containsImage=(parent:Nodes.ParentNode):boolean=>parent.childNodes.some(child=>tree.isElementNode(child)&&(child.tagName==='img'||containsImage(child)))
        if(containsImage(node)){flush();blocks(node.childNodes,list,pre)}else pending.push(node)
      }
    }
    flush()
  }
  const source=doc.artifact.format==='html'?doc.content:toHtml(raw(toHast(fromMarkdown(doc.content,{extensions:[gfm()],mdastExtensions:[gfmFromMarkdown()]}),{allowDangerousHtml:true})))
  blocks(parse(source).childNodes)
  const pres=new pptxgen();pres.layout='LAYOUT_WIDE';pres.title=clean(doc.artifact.title);pres.author=clean(doc.artifact.author);pres.company='MASC'
  pres.subject=`${doc.artifact.id} v${doc.artifact.revision} ${doc.artifact.body._blob.sha256}`
  pres.theme={headFontFace:pptxFonts.heading,bodyFontFace:pptxFonts.body}
  const C=pres.SchemeColor,content={x:0.75,y:1.6,w:11.8,h:4.9},footer=`${doc.artifact.id} · v${doc.artifact.revision}`
  for(const name of ['TITLE','TEXT','TABLE','IMAGE'] as const){
    const dark=name==='TITLE'
    pres.defineSlideMaster({title:`MASC_${name}`,background:{color:dark?C.text2:C.background1},margin:[content.y,0.75,1.0,0.75],
      slideNumber:{x:12.0,y:6.85,w:0.6,h:0.3,fontSize:10,color:dark?C.background1:C.text2,margin:0},objects:[
        {placeholder:{options:{name:'title',type:'title',x:0.75,y:0.55,w:11.8,h:0.75,fontSize:36,bold:true,color:dark?C.background1:C.text1,margin:0},text:''}},
        ...(dark?[]:[{rect:{x:0.55,y:1.4,w:12.2,h:5.25,fill:{color:C.background2},line:{color:C.background2}}}]),
        {text:{text:footer,options:{x:0.75,y:6.85,w:10.9,h:0.3,fontSize:10,color:dark?C.background1:C.text2,margin:0,isTextBox:true,objectName:'publication'}}},
      ]})
  }
  let section=0,slides=0,sectionTitle=''
  let textSlide:pptxgen.Slide|undefined,textY=content.y
  const newSection=(title:string)=>{section++;sectionTitle=`${section}. ${title}`;pres.addSection({title:sectionTitle});textSlide=undefined}
  function page(kind:'TITLE'|'TEXT'|'TABLE'|'IMAGE',header:string):pptxgen.Slide {
    const slide=pres.addSlide({masterName:`MASC_${kind}`,sectionTitle});slides++
    slide.addText(header,{placeholder:'title'})
    slide.addNotes(`${pres.title}\n${sectionTitle}\n${pres.subject}`)
    return slide
  }
  function paragraph(value:Run[],kind:'TITLE'|'TEXT',bullet?:pptxgen.TextPropsOptions['bullet'],depth=0):void {
    const size=kind==='TITLE'?36:16,face=kind==='TITLE'?'heading':'body',lineHeight=size*1.3/72
    // Indentation derives from available geometry even for deeply nested source lists.
    const indent=Math.min(depth*0.2,content.w/2),bulletSpace=bullet?0.35:0
    const lines=wrapPptxRuns(value,(content.w-indent-bulletSpace)*72,size,face,measure)
    let offset=0
    while(offset<lines.length){
      if(!textSlide||textY+lineHeight>content.y+content.h){textSlide=page(kind,kind==='TITLE'?'주제':'본문');textY=content.y}
      const count=Math.min(lines.length-offset,Math.floor((content.y+content.h-textY)/lineHeight))
      for(const [index,line] of lines.slice(offset,offset+count).entries()){
        const rich=line.length?line.map((run,runIndex)=>({text:run.text,options:{...structuredClone(run.options??{}),bullet:offset+index===0&&runIndex===0?structuredClone(bullet??false):false}})):[{text:'',options:{}}]
        textSlide.addText(rich,{x:content.x+indent+bulletSpace,y:textY+index*lineHeight,w:content.w-indent-bulletSpace,h:lineHeight,
          fontSize:size,fontFace:face==='heading'?'+mj-lt':'+mn-lt',color:kind==='TITLE'?C.background1:C.text1,
          margin:0,paraSpaceAfter:0,lineSpacingMultiple:1.3,wrap:false,valign:'top',
          isTextBox:true,objectName:'source-text'})
      }
      offset+=count;textY+=count*lineHeight+0.15
    }
    if(kind==='TITLE')textSlide=undefined
  }
  function sourceTable(part:Extract<Part,{kind:'table'}>):void {
    textSlide=undefined
    const size=14,padding=0.12,lineHeight=size*1.3/72,columns=part.rows[0]!.length
    const graphemes=new Intl.Segmenter(undefined,{granularity:'grapheme'})
    let minWidth=padding*2
    for(const row of part.rows)for(const cell of row)for(const {segment}of graphemes.segment(cell.text)){
      if(segment==='\n')continue
      minWidth=Math.max(minWidth,measure(segment,size,'body',{bold:cell.header})/72+padding*2)
    }
    const perPage=Math.max(1,Math.floor(content.w/minWidth))
    if(columns>perPage)notices.add('넓은 표는 열을 나눠 여러 슬라이드에 표시했습니다.')
    for(let start=0;start<columns;start+=perPage){
      const count=Math.min(perPage,columns-start),colWidth=content.w/count
      const wrapped=part.rows.map(row=>row.slice(start,start+count).map(cell=>({header:cell.header,
        lines:wrapPptxRuns([{text:cell.text}],(colWidth-padding*2)*72,size,'body',(text,pt,face)=>measure(text,pt,face,{bold:cell.header})).map(line=>line.map(run=>run.text).join(''))})))
      const rowLines=(index:number)=>Math.max(1,...wrapped[index]!.map(cell=>cell.lines.length))
      // Repeat headers only if the entire header group leaves room for a body line.
      const headerHeight=wrapped.slice(0,part.headers).reduce((sum,_,index)=>sum+rowLines(index)*lineHeight+padding*2,0)
      const repeat=headerHeight+lineHeight+padding*2<=content.h?part.headers:0
      let slide:pptxgen.Slide|undefined,y=content.y
      const draw=(index:number,offset:number,take:number)=>{
        const cells=wrapped[index]!.map(cell=>({text:cell.lines.slice(offset,offset+take).join('\n'),options:{bold:cell.header,fill:{color:cell.header?C.background1:C.background2}}}))
        const height=take*lineHeight+padding*2
        slide!.addTable([cells],{x:content.x,y,w:content.w,h:height,colW:Array.from({length:count},()=>colWidth),rowH:height,margin:padding,fontSize:size,fontFace:'+mn-lt',
          color:C.text1,border:{type:'none'},valign:'top',autoPage:false,objectName:'source-table'})
        y+=height
      }
      for(let row=0;row<wrapped.length;row++){
        let offset=0
        while(offset<rowLines(row)){
          if(!slide||y+lineHeight+padding*2>content.y+content.h){
            slide=page('TABLE',columns>perPage?`표 · ${start+1}–${start+count}열`:'표');y=content.y
            if(row>=part.headers)for(let header=0;header<repeat;header++)draw(header,0,rowLines(header))
          }
          const take=Math.min(rowLines(row)-offset,Math.floor((content.y+content.h-y-padding*2)/lineHeight))
          draw(row,offset,take);offset+=take
        }
      }
    }
  }
  newSection('문서 정보');paragraph([{text:pres.title}],'TITLE')
  newSection('본문')
  for(const part of parts){
    if(part.kind==='heading'){newSection(part.text);paragraph([{text:part.text}],'TITLE')}
    else if(part.kind==='text')paragraph(part.runs,'TEXT',part.bullet,part.depth)
    else if(part.kind==='table')sourceTable(part)
    else{
      textSlide=undefined;const slide=page('IMAGE','그림')
      const scale=Math.min(content.w/part.width,content.h/part.height),w=part.width*scale,h=part.height*scale
      slide.addImage({data:part.data,x:content.x+(content.w-w)/2,y:content.y+(content.h-h)/2,w,h,altText:part.alt,objectName:'source-image'})
    }
  }
  const data=await pres.write({outputType:'arraybuffer',compression:true})
  if(!(data instanceof ArrayBuffer))throw new Error('PPT 파일을 만들지 못했습니다.')
  return {data:await packed(data),notices:[...notices],slides}
}
