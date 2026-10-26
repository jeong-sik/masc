import { parse,defaultTreeAdapter as tree,html,type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { fromMarkdown } from 'mdast-util-from-markdown'
import { gfmFromMarkdown } from 'mdast-util-gfm'
import { gfm } from 'micromark-extension-gfm'
import { toHast } from 'mdast-util-to-hast'
import { raw } from 'hast-util-raw'
import { toHtml } from 'hast-util-to-html'
import { imageDimensionsFromData } from 'image-dimensions'
import { Document,Paragraph,TextRun,ExternalHyperlink,ImageRun,Table,TableRow,TableCell,Footer,PageNumber,
  HeadingLevel,LevelFormat,WidthType,ShadingType,Packer,type ParagraphChild,type IRunOptions,type IParagraphOptions,type INumberingOptions } from 'docx'
import type { ArtifactDocument } from '../api/published-artifacts'

// A4 portrait, 1 inch margins. OOXML uses twentieths of a point (twips).
const page={width:11906,height:16838},margin=1440,bodyWidth=page.width-2*margin,bodyHeight=page.height-2*margin
const headings={h1:HeadingLevel.HEADING_1,h2:HeadingLevel.HEADING_2,h3:HeadingLevel.HEADING_3,h4:HeadingLevel.HEADING_4,h5:HeadingLevel.HEADING_5,h6:HeadingLevel.HEADING_6}
const containers=new Set(['html','body','main','article','section','header','footer','nav','aside','div','figure','figcaption','details','summary','form','address','dl','dt','dd'])
const omitted=new Set(['head','script','style','template','noscript','meta','link','base','title'])
const dynamic=new Set(['iframe','object','embed','canvas','svg','math','video','audio','button','select','textarea'])
const attr=(node:Nodes.Element,name:string)=>node.attrs.find(attribute=>attribute.name===name)?.value
function integer(value:string|undefined,fallback:number):number {
  if(value===undefined||!/^[-+]?\d+$/.test(value.trim()))return fallback
  const number=Number(value);return Number.isSafeInteger(number)?number:fallback
}
function safeLink(value:string|undefined):string|null {
  if(!value)return null
  try{const url=new URL(value);return ['https:','http:','mailto:','tel:'].includes(url.protocol)?url.href:null}catch{return null}
}
type Context={quote?:boolean;list?:{reference:string;depth:number;used:boolean}}
type Block=Paragraph|Table
export type ArtifactWordFile={data:ArrayBuffer;notices:readonly string[]}

export async function artifactWordFile(doc:ArtifactDocument):Promise<ArtifactWordFile> {
  const source=doc.artifact.format==='html'?doc.content:toHtml(raw(toHast(fromMarkdown(doc.content,{extensions:[gfm()],mdastExtensions:[gfmFromMarkdown()]}),{allowDangerousHtml:true})))
  const parsed=parse(source),notices=new Set<string>(),numbering:INumberingOptions['config'][number][]=[]
  function wordText(value:string):string {
    return Array.from(value,character=>{
      const code=character.codePointAt(0)!
      if(code===9||code===10||code===13||(code>=32&&code<=0xD7FF)||(code>=0xE000&&code<=0xFFFD)||(code>=0x10000&&code<=0x10FFFF))return character
      notices.add('Word에서 표현할 수 없는 문자는 대체 문자로 바꿨습니다.');return '\uFFFD'
    }).join('')
  }
  function image(node:Nodes.Element):ParagraphChild[] {
    const src=attr(node,'src')??'',alt=wordText(attr(node,'alt')||'그림')
    const match=/^data:image\/(png|jpeg);base64,([A-Za-z0-9+/]*={0,2})$/.exec(src)
    if(match){
      try{
        const data=Uint8Array.from(atob(match[2]!),character=>character.charCodeAt(0)),size=imageDimensionsFromData(data)
        if(!size||size.type!==match[1]||size.width<=0||size.height<=0)throw new Error('invalid image')
        // 96 CSS pixels per inch; fit the printable page without stretching.
        const scale=Math.min(1,bodyWidth/15/size.width,bodyHeight/15/size.height)
        return [new ImageRun({type:size.type==='jpeg'?'jpg':'png',data,transformation:{width:size.width*scale,height:size.height*scale},altText:{name:alt,title:alt,description:alt}})]
      }catch{notices.add('읽을 수 없는 그림은 설명으로 바꿨습니다.')}
    }else notices.add('외부 그림과 PNG·JPEG 이외의 그림은 설명과 링크로 바꿨습니다.')
    const text=new TextRun({text:`[그림: ${alt}]`}),link=safeLink(src)
    return [link?new ExternalHyperlink({link,children:[text]}):text]
  }
  function runs(nodes:readonly Nodes.ChildNode[],style:IRunOptions={},pre=false):ParagraphChild[] {
    const result:ParagraphChild[]=[]
    for(const node of nodes){
      if(tree.isTextNode(node)){
        const value=pre?wordText(node.value):wordText(node.value).replace(/[\t\n\f\r ]+/g,' ')
        value.replaceAll('\r\n','\n').replaceAll('\r','\n').split('\n').forEach((text,index)=>result.push(new TextRun({...style,text,...(index?{break:1}:{})})))
      }else if(tree.isElementNode(node)){
        if(omitted.has(node.tagName))continue
        if(dynamic.has(node.tagName)||node.namespaceURI!==html.NS.HTML){notices.add('앱·영상·도형의 실행 화면은 포함하지 않았습니다.');continue}
        if(node.tagName==='br')result.push(new TextRun({break:1}))
        else if(node.tagName==='img')result.push(...image(node))
        else if(node.tagName==='input'){
          if(attr(node,'type')==='checkbox')result.push(new TextRun({text:attr(node,'checked')!==undefined?'☑ ':'☐ '}))
          else notices.add('앱 입력칸의 현재 값은 포함하지 않았습니다.')
        }else if(node.tagName==='a'){
          const children=runs(node.childNodes,style,pre),link=safeLink(attr(node,'href'))
          // Nested hyperlink wrappers are invalid OOXML. Preserve their text.
          if(children.some(child=>child instanceof ExternalHyperlink))result.push(...children)
          else result.push(...(link?[new ExternalHyperlink({link,children})]:children))
        }else{
          const next={...style}
          if(node.tagName==='b'||node.tagName==='strong')next.bold=true
          if(node.tagName==='i'||node.tagName==='em')next.italics=true
          if(node.tagName==='s'||node.tagName==='del')next.strike=true
          if(node.tagName==='u')next.underline={}
          if(node.tagName==='sup'){delete next.subScript;next.superScript=true}
          if(node.tagName==='sub'){delete next.superScript;next.subScript=true}
          if(node.tagName==='code'||node.tagName==='kbd')next.font={ascii:'Consolas',hAnsi:'Consolas',eastAsia:'Malgun Gothic'}
          result.push(...runs(node.childNodes,next,pre))
        }
      }
    }
    return result
  }
  function paragraph(nodes:readonly Nodes.ChildNode[],context:Context={},options:IParagraphOptions={},pre=false):Paragraph {
    const list=context.list,number=list&&!list.used
    if(list)list.used=true
    return new Paragraph({children:runs(nodes,pre?{font:{ascii:'Consolas',hAnsi:'Consolas',eastAsia:'Malgun Gothic'}}:{},pre),spacing:{after:160},
      ...(context.quote?{indent:{left:720},shading:{type:ShadingType.CLEAR,fill:'F3F4F6'}}:{}),
      ...(list?{indent:{left:(list.depth+1)*720},...(number?{numbering:{reference:list.reference,level:0}}:{})}:{}),...options})
  }
  function list(node:Nodes.Element,context:Context):Block[] {
    const items=node.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='li')
    const ordered=node.tagName==='ol',reversed=attr(node,'reversed')!==undefined,depth=context.list?context.list.depth+1:0
    let ordinal=integer(attr(node,'start'),reversed?items.length:1)
    const reference=()=>{
      const name=`artifact-list-${numbering.length}`
      numbering.push({reference:name,levels:[{level:0,format:ordered?LevelFormat.DECIMAL:LevelFormat.BULLET,text:ordered?'%1.':'•',start:ordinal,
        style:{paragraph:{indent:{left:(depth+1)*720,hanging:360}}}}]})
      return name
    }
    let current=reference()
    return items.flatMap(item=>{
      if(ordered&&(reversed||attr(item,'value')!==undefined)){ordinal=integer(attr(item,'value'),ordinal);current=reference()}
      const itemContext={...context,list:{reference:current,depth,used:false}}
      const children=blocks(item.childNodes,itemContext)
      ordinal+=reversed?-1:1
      return children.length?children:[paragraph([],itemContext)]
    })
  }
  function table(node:Nodes.Element):Block[] {
    // HTML table parsing places rows in explicit or implicit row groups.
    // A rowspan cannot continue beyond its thead/tbody/tfoot group.
    const groups=node.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&['thead','tbody','tfoot'].includes(child.tagName))
      .map(group=>group.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='tr'))
    const rows=groups.flat(),groupEnds:number[]=[]
    let end=0
    for(const group of groups){end+=group.length;groupEnds.push(...group.map(()=>end))}
    const cells=rows.map(row=>row.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&(child.tagName==='td'||child.tagName==='th')))
    const occupied=new Map<number,number>()
    let columns=0
    const layout=cells.map((row,rowIndex)=>{
      let column=0
      return row.map(cell=>{
        while((occupied.get(column)??0)>rowIndex)column++
        const count=Math.max(1,integer(attr(cell,'colspan'),1))
        if(!Number.isSafeInteger(column+count)||column+count>bodyWidth)throw new Error('표의 열을 인쇄 영역에 배치할 수 없습니다.')
        const requested=integer(attr(cell,'rowspan'),1),rowSpan=requested===0?groupEnds[rowIndex]!-rowIndex:Math.min(Math.max(1,requested),groupEnds[rowIndex]!-rowIndex)
        for(let offset=0;offset<count;offset++){
          if((occupied.get(column+offset)??0)>rowIndex)throw new Error('서로 겹치는 표 셀을 Word로 옮길 수 없습니다.')
          occupied.set(column+offset,rowIndex+rowSpan)
        }
        const start=column;column+=count;columns=Math.max(columns,column)
        return {cell,start,count,rowSpan}
      })
    })
    if(columns===0)return []
    const widths=Array.from({length:columns},(_,index)=>Math.floor(bodyWidth*(index+1)/columns)-Math.floor(bodyWidth*index/columns))
    const output:Block[]=[]
    const caption=node.childNodes.find((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='caption')
    if(caption)output.push(paragraph(caption.childNodes))
    output.push(new Table({width:{size:bodyWidth,type:WidthType.DXA},columnWidths:widths,rows:layout.map(row=>new TableRow({tableHeader:row.length>0&&row.every(({cell})=>cell.tagName==='th'),children:row.map(({cell,start,count,rowSpan})=>{
        const size=widths.slice(start,start+count).reduce((a,b)=>a+b,0)
        const children=blocks(cell.childNodes)
        if(!(children.at(-1) instanceof Paragraph))children.push(new Paragraph({}))
        return new TableCell({children,width:{size,type:WidthType.DXA},columnSpan:count,rowSpan,
          ...(cell.tagName==='th'?{shading:{type:ShadingType.CLEAR,fill:'E5E7EB'}}:{})})
      })}))}))
    return output
  }
  function blocks(nodes:readonly Nodes.ChildNode[],context:Context={}):Block[] {
    const result:Block[]=[],pending:Nodes.ChildNode[]=[]
    const flush=()=>{if(pending.some(node=>!tree.isTextNode(node)||node.value.trim()))result.push(paragraph(pending,context));pending.length=0}
    for(const node of nodes){
      if(!tree.isElementNode(node)){if(tree.isTextNode(node))pending.push(node);continue}
      if(omitted.has(node.tagName))continue
      if(node.namespaceURI!==html.NS.HTML||dynamic.has(node.tagName)){flush();notices.add('앱·영상·도형의 실행 화면은 포함하지 않았습니다.');continue}
      if(Object.hasOwn(headings,node.tagName)){flush();result.push(paragraph(node.childNodes,context,{heading:headings[node.tagName as keyof typeof headings],keepNext:true}))}
      else if(node.tagName==='ul'||node.tagName==='ol'){flush();result.push(...list(node,context))}
      else if(node.tagName==='table'){flush();result.push(...table(node))}
      else if(node.tagName==='blockquote'){flush();result.push(...blocks(node.childNodes,{...context,quote:true}))}
      else if(node.tagName==='pre'){flush();result.push(paragraph(node.childNodes,context,{shading:{type:ShadingType.CLEAR,fill:'F3F4F6'}},true))}
      else if(node.tagName==='p'){flush();result.push(paragraph(node.childNodes,context))}
      else if(node.tagName==='hr'){flush();result.push(new Paragraph({text:'—'}))}
      else if(containers.has(node.tagName)){flush();result.push(...blocks(node.childNodes,context))}
      else pending.push(node)
    }
    flush();return result
  }
  const children=blocks(parsed.childNodes)
  const document=new Document({title:wordText(doc.artifact.title),creator:wordText(doc.artifact.author),description:`${doc.artifact.id} v${doc.artifact.revision} ${doc.artifact.body._blob.sha256}`,
    styles:{default:{document:{run:{font:{ascii:'Arial',hAnsi:'Arial',eastAsia:'Malgun Gothic'},size:22},paragraph:{spacing:{after:160}}}}},numbering:{config:numbering},
    sections:[{properties:{page:{size:page,margin:{top:margin,bottom:margin,left:margin,right:margin}}},
      footers:{default:new Footer({children:[new Paragraph({children:[new TextRun({text:`${doc.artifact.id} · v${doc.artifact.revision} · `,size:16,color:'6B7280'}),new TextRun({children:[PageNumber.CURRENT],size:16})]})]})},
      children:children.length?children:[new Paragraph({})]}]})
  return {data:await Packer.toArrayBuffer(document),notices:[...notices]}
}
