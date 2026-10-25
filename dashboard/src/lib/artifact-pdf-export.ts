import pdfMake from 'pdfmake/build/pdfmake'
import { PDFDocument } from 'pdf-lib'
import fontkit,{type Font} from '@pdf-lib/fontkit'
import { fromByteArray } from 'base64-js'
import type { Content,ContentText,ContentTable,Style,TableCell,TDocumentDefinitions } from 'pdfmake/interfaces'
import { parse,defaultTreeAdapter as tree,html,type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { fromMarkdown } from 'mdast-util-from-markdown'
import { gfmFromMarkdown } from 'mdast-util-gfm'
import { gfm } from 'micromark-extension-gfm'
import { toHast } from 'mdast-util-to-hast'
import { raw } from 'hast-util-raw'
import { toHtml } from 'hast-util-to-html'
import { imageDimensionsFromData } from 'image-dimensions'
import type { ArtifactDocument } from '../api/published-artifacts'
import type { ArtifactPdfFonts } from './artifact-pdf-fonts'

const tablePadding=8,tableLine=0.5
const page={width:595.28,height:841.89},margin=54,bodyWidth=page.width-margin*2,bodyHeight=page.height-margin*2
const omitted=new Set(['head','script','style','template','noscript','meta','link','base','title'])
const dynamic=new Set(['iframe','object','embed','canvas','svg','math','video','audio','button','select','textarea'])
const containers=new Set(['html','body','main','article','section','header','footer','nav','aside','div','figure','figcaption','details','summary','form','address','blockquote','dl','dt','dd'])
const headingSizes=new Map([['h1',20],['h2',17],['h3',15],['h4',13],['h5',12],['h6',11]])
const attr=(node:Nodes.Element,name:string)=>node.attrs.find(item=>item.name===name)?.value
const integer=(value:string|undefined,fallback:number)=>{if(value===undefined||!/^[-+]?\d+$/.test(value.trim()))return fallback;const parsed=Number(value);return Number.isSafeInteger(parsed)?parsed:fallback}
function safeLink(value:string|undefined):string|null {if(!value)return null;try{const url=new URL(value);return ['http:','https:','mailto:','tel:'].includes(url.protocol)?url.href:null}catch{return null}}
export type ArtifactPdfFile={data:ArrayBuffer;notices:readonly string[]}
type Context={width:number;size:number;list?:{prefix:string;depth:number;used:boolean};pre?:boolean;bold?:boolean}

export async function artifactPdfFile(doc:ArtifactDocument,bytes:ArtifactPdfFonts):Promise<ArtifactPdfFile> {
  const fonts={regular:fontkit.create(bytes.regular),bold:fontkit.create(bytes.bold),emoji:fontkit.create(bytes.emoji)},notices=new Set<string>(),tables:ContentTable[]=[]
  const graphemes=new Intl.Segmenter(undefined,{granularity:'grapheme'}),words=new Intl.Segmenter(undefined,{granularity:'word'})
  function clean(value:string):string {
    return Array.from(value,character=>{
      const code=character.codePointAt(0)!
      if(code===9||code===10||code===13||(code>=32&&code<=0xD7FF)||(code>=0xE000&&code<=0xFFFD)||(code>=0x10000&&code<=0x10FFFF))return character
      notices.add('표현할 수 없는 제어 문자는 대체 문자로 바꿨습니다.');return '\uFFFD'
    }).join('')
  }
  function supports(font:Font,value:string):boolean {return Array.from(value).every(character=>{const point=character.codePointAt(0)!;return point===10||point===13||font.hasGlyphForCodePoint(point)})}
  function text(value:string,style:Style,context:Context):ContentText[] {
    const output:ContentText[]=[],primary=style.bold?fonts.bold:fonts.regular
    for(const {segment} of graphemes.segment(clean(value).replaceAll('\r\n','\n').replaceAll('\r','\n').replaceAll('\t','    '))){
      const normal=supports(primary,segment),symbol=!normal&&supports(fonts.emoji,segment),font=symbol?'ArtifactEmoji':'ArtifactBody'
      let literal=segment
      if(!normal&&!symbol){literal=Array.from(segment,character=>`[U+${character.codePointAt(0)!.toString(16).toUpperCase()}]`).join('');notices.add('포함된 글꼴에 없는 문자는 유니코드 번호로 표시했습니다.')}
      const previous=output.at(-1)
      if(previous?.font===font)previous.text=String(previous.text)+literal
      else output.push({...style,font,text:literal})
    }
    // Split oversized words at measured grapheme boundaries. Explicit line breaks preserve
    // the text layer: the fonts lack U+200B, and native break-all splits UTF-16 surrogates.
    for(const run of output){
      const font=run.font==='ArtifactEmoji'?fonts.emoji:primary,size=style.fontSize??context.size
      run.text=Array.from(words.segment(String(run.text)),({segment})=>{
        if(font.layout(segment).advanceWidth/font.unitsPerEm*size<=context.width)return segment
        const lines:string[]=[];let line=''
        for(const {segment:cluster} of graphemes.segment(segment)){
          if(font.layout(cluster).advanceWidth/font.unitsPerEm*size>context.width)throw new Error('글자를 PDF 인쇄 영역에 배치할 수 없습니다.')
          if(line&&font.layout(line+cluster).advanceWidth/font.unitsPerEm*size>context.width){lines.push(line);line=cluster}else line+=cluster
        }
        if(line)lines.push(line)
        return lines.join('\n')
      }).join('')
    }
    return output
  }
  function runs(nodes:readonly Nodes.ChildNode[],context:Context,style:Style={}):ContentText[] {
    const result:ContentText[]=[]
    for(const node of nodes){
      if(tree.isTextNode(node)){result.push(...text(context.pre?node.value:node.value.replace(/[\t\n\f\r ]+/g,' '),style,context));continue}
      if(!tree.isElementNode(node)||omitted.has(node.tagName))continue
      if(dynamic.has(node.tagName)||node.namespaceURI!==html.NS.HTML){notices.add('앱·영상·도형의 실행 화면은 포함하지 않았습니다.');continue}
      if(node.tagName==='br'){result.push(...text('\n',style,context));continue}
      if(node.tagName==='input'){
        if(attr(node,'type')==='checkbox')result.push(...text(attr(node,'checked')!==undefined?'☑ ':'☐ ',style,context))
        else notices.add('앱 입력칸의 현재 값은 포함하지 않았습니다.')
        continue
      }
      const next={...style}
      if(node.tagName==='strong'||node.tagName==='b')next.bold=true
      if(node.tagName==='em'||node.tagName==='i'){notices.add('기울임 글꼴은 일반 글꼴로 옮겼습니다.')}
      if(node.tagName==='u')next.decoration='underline'
      if(node.tagName==='s'||node.tagName==='del')next.decoration='lineThrough'
      if(node.tagName==='sup'){delete next.sub;next.sup=true}
      if(node.tagName==='sub'){delete next.sup;next.sub=true}
      if(node.tagName==='a'){const link=safeLink(attr(node,'href'));if(link)result.push(...runs(node.childNodes,context,next).map(run=>({...run,link,color:'#187B68',decoration:'underline' as const})));else result.push(...runs(node.childNodes,context,next));continue}
      if(node.tagName==='img'){result.push(...text(`[그림: ${attr(node,'alt')||'그림'}]`,next,context));const link=safeLink(attr(node,'src'));if(link)result.push(...text(` ${link}`,next,context));notices.add('표 안의 그림은 설명과 링크로 바꿨습니다.');continue}
      result.push(...runs(node.childNodes,{...context,pre:context.pre||node.tagName==='pre'},next))
    }
    return result
  }
  function paragraph(nodes:readonly Nodes.ChildNode[],context:Context,options:Partial<ContentText>={}):ContentText {
    const list=context.list,indent=Math.min((list?.depth??0)*14,context.width/2),lineContext={...context,width:context.width-indent},prefix=list&&!list.used?text(list.prefix,{},lineContext):[]
    if(list)list.used=true
    return {text:[...prefix,...runs(nodes,lineContext,{bold:options.bold??context.bold,fontSize:options.fontSize})],margin:[indent,0,0,8],preserveLeadingSpaces:true,...options}
  }
  function picture(node:Nodes.Element,context:Context):Content {
    const src=attr(node,'src')??'',alt=clean(attr(node,'alt')||'그림'),match=/^data:image\/(png|jpeg);base64,([A-Za-z0-9+/]*={0,2})$/.exec(src)
    if(match)try{
      const size=imageDimensionsFromData(Uint8Array.from(atob(match[2]!),character=>character.charCodeAt(0)))
      if(size&&size.type===match[1]&&size.width>0&&size.height>0){const scale=Math.min(0.75,context.width/size.width,bodyHeight/size.height);return {image:src,width:size.width*scale,height:size.height*scale,margin:[0,0,0,8]}}
    }catch{/* Preserve a readable description for malformed media. */}
    notices.add('외부 그림과 읽을 수 없는 그림은 설명과 링크로 바꿨습니다.')
    const link=safeLink(src)
    return {text:text(`[그림: ${alt}]${link?' '+link:''}`,{},context),...(link?{link}:{}),margin:[0,0,0,8]}
  }
  function table(node:Nodes.Element,context:Context):Content[] {
    const groups=node.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&['thead','tbody','tfoot'].includes(child.tagName)).map(group=>group.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='tr'))
    type Cell={node:Nodes.Element;row:number;column:number;width:number;height:number}
    const grid:Cell[][]=[];let columns=0,headers=0
    for(const group of groups){const offset=grid.length;grid.push(...group.map(()=>[]))
      for(const [index,row] of group.entries()){
        const cells=row.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&(child.tagName==='td'||child.tagName==='th'))
        if(offset+index===headers&&cells.length&&cells.every(cell=>cell.tagName==='th'))headers++
        let column=0
        for(const cell of cells){
          while(grid[offset+index]![column])column++
          const width=Math.min(1000,Math.max(1,integer(attr(cell,'colspan'),1))),requested=integer(attr(cell,'rowspan'),1),height=requested===0?group.length-index:Math.min(65534,group.length-index,Math.max(1,requested))
          const value={node:cell,row:offset+index,column,width,height}
          for(let y=offset+index;y<offset+index+height;y++)for(let x=column;x<column+width;x++)grid[y]![x]=value
          column+=width;columns=Math.max(columns,column)
        }
      }
    }
    if(!columns)return []
    function minimumWidth(nodes:readonly Nodes.ChildNode[],size:number,bold=false,depth=0):number {
      let required=0
      for(const child of nodes){
        if(tree.isElementNode(child)){
          if(omitted.has(child.tagName)||dynamic.has(child.tagName)||child.namespaceURI!==html.NS.HTML)continue
          if(child.tagName==='table'){
            required=Math.max(required,minimumWidth(child.childNodes,9,bold)+tablePadding*2+tableLine*2);continue
          }
          if(child.tagName!=='img'&&child.tagName!=='input'){
            required=Math.max(required,minimumWidth(child.childNodes,headingSizes.get(child.tagName)??size,
              bold||headingSizes.has(child.tagName)||['b','strong','th'].includes(child.tagName),depth+(['ul','ol'].includes(child.tagName)?1:0)));continue
          }
        }
        const style={fontSize:size,bold}
        for(const run of runs([child],{...context,size},style))for(const {segment} of graphemes.segment(String(run.text))){
          if(segment==='\n')continue
          const font=run.font==='ArtifactEmoji'?fonts.emoji:bold?fonts.bold:fonts.regular
          const width=font.layout(segment).advanceWidth/font.unitsPerEm*size
          // Solve width - min(depth*14,width/2) >= one grapheme for list indentation.
          required=Math.max(required,width+Math.min(width,depth*14))
        }
      }
      return required
    }
    let minContentWidth=fonts.regular.glyphForCodePoint(0xFFFD).advanceWidth/fonts.regular.unitsPerEm*9
    const measured=new Set<Cell>()
    for(const row of grid)for(const cell of row)if(cell&&!measured.has(cell)){measured.add(cell);minContentWidth=Math.max(minContentWidth,minimumWidth(cell.node.childNodes,9,cell.node.tagName==='th'))}
    const perPage=Math.max(1,Math.floor((context.width-tableLine)/(minContentWidth+tablePadding*2+tableLine))),result:Content[]=[]
    const caption=node.childNodes.find((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='caption')
    if(caption)result.push(paragraph(caption.childNodes,context))
    if(columns>perPage)notices.add('넓은 표는 열을 나눴으며 경계를 지나는 병합 값은 각 표에 반복했습니다.')
    for(let start=0;start<columns;start+=perPage){
      const count=Math.min(perPage,columns-start),cellWidth=(context.width-(count+1)*tableLine-count*tablePadding*2)/count
      const body:TableCell[][]=grid.map((row,y)=>Array.from({length:count},(_,x):TableCell=>{
        const cell=row[start+x]
        if(!cell)return {text:''}
        const left=Math.max(start,cell.column)
        if(y!==cell.row||start+x!==left)return {}
        const colSpan=Math.min(start+count,cell.column+cell.width)-left
        return {stack:blocks(cell.node.childNodes,{width:cellWidth*colSpan+(tablePadding*2+tableLine)*(colSpan-1),size:9,bold:cell.node.tagName==='th'}),colSpan,rowSpan:cell.height,
          ...(cell.node.tagName==='th'?{bold:true,fillColor:'#F2F4F7'}:{})}
      }))
      const crossesHeader=grid.some((row,y)=>y<headers&&row.some(cell=>cell.row+cell.height>headers))
      if(crossesHeader)notices.add('본문과 행 병합으로 이어지는 표 머리글은 반복하지 않았습니다.')
      const converted:ContentTable={table:{widths:Array.from({length:count},()=>cellWidth),headerRows:crossesHeader?0:headers,body},fontSize:9,margin:[0,0,0,10],layout:'artifactTable'}
      tables.push(converted);result.push(converted)
    }
    return result
  }
  function blocks(nodes:readonly Nodes.ChildNode[],context:Context):Content[] {
    const result:Content[]=[],pending:Nodes.ChildNode[]=[]
    const flush=()=>{if(pending.some(node=>!tree.isTextNode(node)||node.value.trim())){result.push(paragraph(pending,context))}pending.length=0}
    for(const node of nodes){
      if(!tree.isElementNode(node)){if(tree.isTextNode(node))pending.push(node);continue}
      if(omitted.has(node.tagName))continue
      if(dynamic.has(node.tagName)||node.namespaceURI!==html.NS.HTML){flush();notices.add('앱·영상·도형의 실행 화면은 포함하지 않았습니다.');continue}
      if(headingSizes.has(node.tagName)){flush();const size=headingSizes.get(node.tagName)!;result.push(paragraph(node.childNodes,{...context,size},{fontSize:size,bold:true,headlineLevel:1,margin:[0,8,0,8]}))}
      else if(node.tagName==='ul'||node.tagName==='ol'){
        flush();const items=node.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='li'),reversed=attr(node,'reversed')!==undefined
        let ordinal=integer(attr(node,'start'),reversed?items.length:1)
        for(const item of items){ordinal=integer(attr(item,'value'),ordinal);const list={depth:(context.list?.depth??0)+1,prefix:node.tagName==='ol'?`${ordinal}. `:'• ',used:false};const children=blocks(item.childNodes,{...context,list});result.push(...(children.length?children:[paragraph([],{...context,list})]));ordinal+=reversed?-1:1}
      }else if(node.tagName==='table'){flush();result.push(...table(node,context))}
      else if(node.tagName==='img'){flush();result.push(picture(node,context))}
      else if(node.tagName==='pre'){flush();result.push(...blocks(node.childNodes,{...context,pre:true}))}
      else if(node.tagName==='p'||containers.has(node.tagName)){flush();result.push(...blocks(node.childNodes,context))}
      else if(node.tagName==='hr'){flush();result.push({canvas:[{type:'line',x1:0,y1:0,x2:context.width,y2:0,lineWidth:0.5,lineColor:'#D1D5DB'}],margin:[0,4,0,12]})}
      else{
        const containsImage=(parent:Nodes.ParentNode):boolean=>parent.childNodes.some(child=>tree.isElementNode(child)&&(child.tagName==='img'||containsImage(child)))
        if(containsImage(node)){flush();result.push(...blocks(node.childNodes,context))}else pending.push(node)
      }
    }
    flush();return result
  }
  const source=doc.artifact.format==='html'?doc.content:toHtml(raw(toHast(fromMarkdown(doc.content,{extensions:[gfm()],mdastExtensions:[gfmFromMarkdown()]}),{allowDangerousHtml:true})))
  const content=blocks(parse(source).childNodes,{width:bodyWidth,size:11})
  const definition:TDocumentDefinitions={pageSize:page,pageMargins:[margin,margin,margin,margin],defaultStyle:{font:'ArtifactBody',fontSize:11,lineHeight:1.3},
    info:{title:clean(doc.artifact.title),author:clean(doc.artifact.author),creator:'MASC',subject:`${doc.artifact.id} v${doc.artifact.revision} ${doc.artifact.body._blob.sha256}`},
    content:content.length?content:[{text:''}],footer:pageNumber=>({text:`${doc.artifact.id} · v${doc.artifact.revision} · ${pageNumber}`,fontSize:8,color:'#6B7280',margin:[margin,18,margin,0]}),
    pageBreakBefore:(node,queries)=>Boolean(node.headlineLevel&&queries.getFollowingNodesOnPage().length===0&&queries.getPreviousNodesOnPage().length>0&&queries.getNodesOnNextPage().length>0)}
  pdfMake.addVirtualFileSystem({'Artifact-Regular.otf':fromByteArray(bytes.regular),'Artifact-Bold.otf':fromByteArray(bytes.bold),'Artifact-Emoji.ttf':fromByteArray(bytes.emoji)})
  pdfMake.addFonts({ArtifactBody:{normal:'Artifact-Regular.otf',bold:'Artifact-Bold.otf',italics:'Artifact-Regular.otf',bolditalics:'Artifact-Bold.otf'},ArtifactEmoji:{normal:'Artifact-Emoji.ttf',bold:'Artifact-Emoji.ttf',italics:'Artifact-Emoji.ttf',bolditalics:'Artifact-Emoji.ttf'}})
  pdfMake.addTableLayouts({artifactTable:{hLineWidth:()=>tableLine,vLineWidth:()=>tableLine,hLineColor:()=> '#D1D5DB',vLineColor:()=> '#D1D5DB',paddingLeft:()=>tablePadding,paddingRight:()=>tablePadding,paddingTop:()=>5,paddingBottom:()=>5}})
  pdfMake.setUrlAccessPolicy(()=>false)
  // pdfmake repeats headers as an unbreakable block and can silently discard an oversized one.
  // Use the same public layout engine to check actual page fit with a minimal body line.
  for(const table of tables){
    const count=table.table.headerRows??0
    if(!count)continue
    const header=structuredClone(table)
    header.table.headerRows=0
    header.table.body=header.table.body.slice(0,count)
    header.table.body.push(header.table.body[0]!.map(()=>({text:' ',margin:[0,0,0,8]})))
    const probe=await pdfMake.createPdf({pageSize:page,pageMargins:[margin,margin,margin,margin],defaultStyle:{font:'ArtifactBody',fontSize:11,lineHeight:1.3},content:[header]}).getBuffer()
    if((await PDFDocument.load(Uint8Array.from(probe))).getPageCount()>1){table.table.headerRows=0;notices.add('한 페이지에 들어가지 않는 표 머리글은 반복하지 않고 본문처럼 나눴습니다.')}
  }
  const buffer=await pdfMake.createPdf(definition).getBuffer()
  return {data:Uint8Array.from(buffer).buffer,notices:[...notices]}
}
