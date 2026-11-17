import { parse,defaultTreeAdapter as tree,html,type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { fromMarkdown } from 'mdast-util-from-markdown'
import { gfmFromMarkdown } from 'mdast-util-gfm'
import { gfm } from 'micromark-extension-gfm'
import { toHast } from 'mdast-util-to-hast'
import { raw } from 'hast-util-raw'
import { toHtml } from 'hast-util-to-html'
import { officeImageDimensions } from './artifact-office-image'
import { Document,Paragraph,TextRun,ExternalHyperlink,ImageRun,Table,TableRow,TableCell,Footer,PageNumber,
  HeadingLevel,LevelFormat,WidthType,ShadingType,TableLayoutType,Packer,type ParagraphChild,type IRunOptions,type IParagraphOptions,type INumberingOptions,type ITableWidthProperties } from 'docx'
import { ChartRun } from 'docx/charts'
import { officeChartFromFigure, type OfficeChart } from './artifact-office-chart'
import { formatOfficeChartSeries } from './artifact-office-chart-format'
import { officeXmlCharacter } from './artifact-office-text'
import { parseOfficeTableWidth, resolveOfficeTableWidths, type OfficeTableWidth } from './artifact-office-table-width'
import { officeTableTwips, type PreparedOfficeBlock, type PreparedOfficeTable } from './artifact-office-prepared'
import { hwpxTableLimits } from './artifact-hwpx-template'
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
type Context={quote?:boolean;list?:{reference:string;depth:number;used:boolean};availableWidth?:number}
type Block=Paragraph|Table
export type ArtifactWordFile={data:ArrayBuffer;notices:readonly string[];blocks:readonly PreparedOfficeBlock[]}

export async function artifactWordFile(doc:ArtifactDocument,target:'docx'|'hwpx'='docx'):Promise<ArtifactWordFile> {
  const source=doc.artifact.format==='html'?doc.content:toHtml(raw(toHast(fromMarkdown(doc.content,{extensions:[gfm()],mdastExtensions:[gfmFromMarkdown()]}),{allowDangerousHtml:true})))
  const parsed=parse(source),notices=new Set<string>(),numbering:INumberingOptions['config'][number][]=[]
  const charts:OfficeChart[]=[]
  const tables=new Map<Table,PreparedOfficeTable>()
  const sourceWidths=new Map<Nodes.Element,OfficeTableWidth>()
  const tableSourceWidth=(node:Nodes.Element):OfficeTableWidth=>{
    const known=sourceWidths.get(node)
    if(known)return known
    const width=parseOfficeTableWidth(attr(node,'style'),attr(node,'width'))
    sourceWidths.set(node,width)
    return width
  }
  const columnSpan=(node:Nodes.Element,attribute:string)=>Math.min(hwpxTableLimits.columns,Math.max(1,integer(attr(node,attribute),1)))
  const prepared=(blocks:readonly Block[]):PreparedOfficeBlock[]=>blocks.map(block=>{
    if(block instanceof Paragraph)return {kind:'paragraph'}
    const table=tables.get(block)
    if(!table)throw new Error('생성한 표의 원본 너비 정보를 찾지 못했습니다.')
    return table
  })
  const widthOptions=(width:OfficeTableWidth):ITableWidthProperties|undefined=>{
    switch(width.kind){
      case 'absolute':return {size:Math.round(width.hwpUnits/5),type:WidthType.DXA}
      case 'percent':
        if(!Number.isSafeInteger(Math.round(width.value*50)))throw new Error('표의 백분율을 DOCX 너비 단위로 표현할 수 없습니다.')
        return {size:width.value,type:WidthType.PERCENTAGE}
      case 'auto':return {size:0,type:WidthType.AUTO}
      case 'absent':return undefined
      case 'unsupported':notices.add('표의 일부 너비 단위는 출력에서 자동 배치합니다.');return undefined
    }
  }
  function wordText(value:string):string {
    return Array.from(value,character=>{
      const code=character.codePointAt(0)!
      if(officeXmlCharacter(code))return character
      notices.add('Word에서 표현할 수 없는 문자는 대체 문자로 바꿨습니다.');return '\uFFFD'
    }).join('')
  }
  function image(node:Nodes.Element):ParagraphChild[] {
    const src=attr(node,'src')??'',alt=wordText(attr(node,'alt')||'그림')
    const match=/^data:image\/(png|jpeg|bmp);base64,([A-Za-z0-9+/]*={0,2})$/.exec(src)
    if(match){
      try{
        const data=Uint8Array.from(atob(match[2]!),character=>character.charCodeAt(0)),size=officeImageDimensions(data)
        if(!size||size.type!==match[1]||size.width<=0||size.height<=0)throw new Error('invalid image')
        // 96 CSS pixels per inch; fit the printable page without stretching.
        const scale=Math.min(1,bodyWidth/15/size.width,bodyHeight/15/size.height)
        return [new ImageRun({type:size.type==='jpeg'?'jpg':size.type,data,transformation:{width:size.width*scale,height:size.height*scale},altText:{name:alt,title:alt,description:alt}})]
      }catch{notices.add('읽을 수 없는 그림은 설명으로 바꿨습니다.')}
    }else notices.add('외부 그림과 PNG·JPEG·BMP 이외의 그림은 설명과 링크로 바꿨습니다.')
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
  function table(node:Nodes.Element,context:Context):Block[] {
    const columnLimit=target==='hwpx'?hwpxTableLimits.columns:bodyWidth
    const requireColumns=(columns:number)=>{
      if(!Number.isSafeInteger(columns)||columns>columnLimit)throw new Error(target==='hwpx'
        ?'표의 행 또는 열 수를 HWPX와 HTML 양쪽에 옮길 수 없습니다.':'표의 열을 인쇄 영역에 배치할 수 없습니다.')
    }
    // HTML table parsing places rows in explicit or implicit row groups.
    // A rowspan cannot continue beyond its thead/tbody/tfoot group.
    const groups=node.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&['thead','tbody','tfoot'].includes(child.tagName))
      .map(group=>group.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='tr'))
    const rows=groups.flat(),groupEnds:number[]=[]
    if(target==='hwpx'&&rows.length>hwpxTableLimits.rows)throw new Error('표의 행 또는 열 수를 HWPX와 HTML 양쪽에 옮길 수 없습니다.')
    let end=0
    for(const group of groups){end+=group.length;groupEnds.push(...group.map(()=>end))}
    const cells=rows.map(row=>row.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&(child.tagName==='td'||child.tagName==='th')))
    const occupied=new Map<number,number>()
    let columns=0
    const layout=cells.map((row,rowIndex)=>{
      let column=0
      return row.map(cell=>{
        while((occupied.get(column)??0)>rowIndex)column++
        const count=columnSpan(cell,'colspan')
        requireColumns(column+count)
        const requested=integer(attr(cell,'rowspan'),1),rowSpan=requested===0?groupEnds[rowIndex]!-rowIndex:Math.min(Math.max(1,requested),groupEnds[rowIndex]!-rowIndex)
        for(let offset=0;offset<count;offset++){
          if((occupied.get(column+offset)??0)>rowIndex)throw new Error('서로 겹치는 표 셀을 Word로 옮길 수 없습니다.')
          occupied.set(column+offset,rowIndex+rowSpan)
        }
        const start=column;column+=count;columns=Math.max(columns,column)
        return {cell,start,count,rowSpan}
      })
    })
    const sourceWidth=tableSourceWidth(node),sourceColumns:OfficeTableWidth[]=[]
    for(const group of node.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='colgroup')){
      const children=group.childNodes.filter((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='col')
      const groupWidth=tableSourceWidth(group)
      if(children.length===0){
        const count=columnSpan(group,'span')
        requireColumns(sourceColumns.length+count)
        sourceColumns.push(...Array.from({length:count},()=>groupWidth))
      }
      for(const column of children){
        const width=tableSourceWidth(column),count=columnSpan(column,'span')
        requireColumns(sourceColumns.length+count)
        sourceColumns.push(...Array.from({length:count},()=>width.kind==='absent'||width.kind==='auto'?groupWidth:width))
      }
    }
    columns=Math.max(columns,sourceColumns.length)
    if(columns===0)return []
    // Column declarations and ragged rows may leave real empty cells. Include
    // them in both the Word producer and its nested geometry projection.
    const spans=new Map<number,{start:number;end:number;until:number}>()
    const complete=layout.map((row,rowIndex)=>{
      for(const [start,span] of spans)if(span.until<=rowIndex)spans.delete(start)
      const intervals=[...Array.from(spans.values(),span=>({start:span.start,end:span.end,cell:null})),
        ...row.map(cell=>({start:cell.start,end:cell.start+cell.count,cell}))].sort((a,b)=>a.start-b.start)
      const filled:typeof row=[]
      let at=0
      const gap=(end:number)=>{
        while(at<end){
          const count=Math.min(hwpxTableLimits.columns,end-at)
          filled.push({cell:tree.createElement(row.length>0&&row.every(({cell})=>cell.tagName==='th')?'th':'td',html.NS.HTML,[]),start:at,count,rowSpan:1})
          at+=count
        }
      }
      for(const interval of intervals){
        if(interval.start<at)throw new Error('서로 겹치는 표 셀을 Word로 옮길 수 없습니다.')
        gap(interval.start)
        if(interval.cell){
          filled.push(interval.cell)
          if(interval.cell.rowSpan>1)spans.set(interval.start,{start:interval.start,end:interval.end,until:rowIndex+interval.cell.rowSpan})
        }
        at=interval.end
      }
      gap(columns)
      return filled
    })
    const sourceCells=complete.flatMap(row=>row.map(cell=>({column:cell.start,columns:cell.count,width:tableSourceWidth(cell.cell)})))
    const geometry=resolveOfficeTableWidths(columns,sourceCells,{...(sourceColumns.length?{columns:[...sourceColumns,...Array.from({length:columns-sourceColumns.length},():OfficeTableWidth=>({kind:'absent'}))]}:{}),table:sourceWidth})
    const hasWidths=sourceWidth.kind!=='absent'||sourceColumns.some(width=>width.kind!=='absent')||sourceCells.some(cell=>cell.width.kind!=='absent')
    const relative=(width:OfficeTableWidth)=>width.kind==='percent'||width.kind==='auto'
    const relativeWidths=relative(sourceWidth)||sourceColumns.some(relative)||sourceCells.some(cell=>relative(cell.width))
    const unsupportedWidths=[sourceWidth,...sourceColumns,...sourceCells.map(cell=>cell.width)].some(width=>width.kind==='unsupported')
    if(unsupportedWidths)notices.add('표의 일부 너비 단위는 출력에서 자동 배치합니다.')
    if(relativeWidths)notices.add('표의 백분율·자동 너비는 출력 앱에서 배치합니다. HWPX는 열·셀의 절대 너비로 다시 배치합니다.')
    const widths=geometry.kind==='unique'?officeTableTwips(geometry.widths):hasWidths?undefined:
      Array.from({length:columns},(_,index)=>Math.floor((context.availableWidth??bodyWidth)*(index+1)/columns)-Math.floor((context.availableWidth??bodyWidth)*index/columns))
    if(widths?.some(width=>width<=0))throw new Error('표의 열 너비가 DOCX에서 표현할 수 있는 단위보다 작습니다.')
    if(hasWidths&&geometry.kind!=='unique')notices.add(geometry.kind==='conflicting'
      ?'표의 선호 너비가 서로 달라 DOCX는 자동 배치합니다. HWPX에는 명시적 셀 너비를 보존합니다.'
      :'표의 내부 열 너비를 모두 알 수 없어 DOCX는 명시적 셀 너비로 자동 배치합니다.')
    const tableWidth=relative(sourceWidth)?widthOptions(sourceWidth):widths?{size:widths.reduce((sum,width)=>sum+width,0),type:WidthType.DXA}:widthOptions(sourceWidth)
    const output:Block[]=[]
    const caption=node.childNodes.find((child):child is Nodes.Element=>tree.isElementNode(child)&&child.tagName==='caption')
    if(caption)output.push(paragraph(caption.childNodes))
    const preparedRows:PreparedOfficeTable['rows'][number][]=[]
    const wordRows=complete.map(row=>{
      const projected:PreparedOfficeTable['rows'][number][number][]=[]
      preparedRows.push(projected)
      return new TableRow({tableHeader:row.length>0&&row.every(({cell})=>cell.tagName==='th'),children:row.map(({cell,start,count,rowSpan})=>{
        const sourceCell=tableSourceWidth(cell),knownColumns=geometry.widths.slice(start,start+count)
        const knownWidth=geometry.kind!=='conflicting'&&knownColumns.every(width=>width!==null)?knownColumns.reduce<number>((sum,width)=>sum+width!,0):null
        const exactWidth=sourceCell.kind==='absolute'?sourceCell.hwpUnits:sourceCell.kind==='absent'?knownWidth:null
        const size=widths?.slice(start,start+count).reduce((a,b)=>a+b,0)
        const width=relative(sourceCell)||size===undefined?widthOptions(sourceCell.kind==='absent'&&exactWidth!==null?{kind:'absolute',hwpUnits:exactWidth}:sourceCell):{size,type:WidthType.DXA}
        const children=blocks(cell.childNodes,{availableWidth:size??(exactWidth===null?context.availableWidth:Math.round(exactWidth/5))})
        if(!(children.at(-1) instanceof Paragraph))children.push(new Paragraph({}))
        projected.push({column:start,columns:count,rows:rowSpan,width:exactWidth,children:prepared(children)})
        return new TableCell({children,width,columnSpan:count,rowSpan,
          ...(cell.tagName==='th'?{shading:{type:ShadingType.CLEAR,fill:'E5E7EB'}}:{})})
      })})
    })
    const wordTable=new Table({width:tableWidth,columnWidths:widths,...(geometry.kind==='unique'&&!relativeWidths&&!unsupportedWidths?{layout:TableLayoutType.FIXED}:{}),rows:wordRows})
    tables.set(wordTable,{kind:'table',columns,width:sourceWidth.kind==='absolute'?sourceWidth.hwpUnits:sourceWidth.kind==='absent'&&geometry.kind==='unique'?geometry.widths.reduce((sum,width)=>sum+width,0):null,rows:preparedRows})
    output.push(wordTable)
    return output
  }
  function blocks(nodes:readonly Nodes.ChildNode[],context:Context={}):Block[] {
    const result:Block[]=[],pending:Nodes.ChildNode[]=[]
    const flush=()=>{if(pending.some(node=>!tree.isTextNode(node)||node.value.trim()))result.push(paragraph(pending,context));pending.length=0}
    for(const node of nodes){
      if(!tree.isElementNode(node)){if(tree.isTextNode(node))pending.push(node);continue}
      if(omitted.has(node.tagName))continue
      if(node.namespaceURI!==html.NS.HTML||dynamic.has(node.tagName)){flush();notices.add('앱·영상·도형의 실행 화면은 포함하지 않았습니다.');continue}
      const chart=officeChartFromFigure(node)
      if(chart){
        flush()
        charts.push(chart)
        const common={...(chart.title===''?{}:{title:wordText(chart.title)}),categories:chart.categories.map(wordText),
          series:chart.series.map(series=>({name:wordText(series.name),values:series.values})),transformation:{width:bodyWidth/15,height:320}}
        const options=chart.type==='pie'?{...common,type:chart.type}:{...common,type:chart.type,emptyValues:chart.emptyValues,
          ...(chart.valueFormat===undefined?{}:{valueAxis:{numberFormat:chart.valueFormat}})}
        result.push(new Paragraph({children:[new ChartRun(options)]}))
        continue
      }
      if(Object.hasOwn(headings,node.tagName)){flush();result.push(paragraph(node.childNodes,context,{heading:headings[node.tagName as keyof typeof headings],keepNext:true}))}
      else if(node.tagName==='ul'||node.tagName==='ol'){flush();result.push(...list(node,context))}
      else if(node.tagName==='table'){flush();result.push(...table(node,context))}
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
  const data=await Packer.toArrayBuffer(document)
  // Derived grids are resolved against the real page/parent during packing.
  // Check the public result as well as explicit preferences before download.
  for(const table of tables.keys())if(table.ColumnWidths.some(width=>!Number.isSafeInteger(width)||width<0))throw new Error('표의 배치 결과를 DOCX 너비 단위로 표현할 수 없습니다.')
  return {data:await formatOfficeChartSeries(data,charts),notices:[...notices],blocks:prepared(children.length?children:[new Paragraph({})])}
}
