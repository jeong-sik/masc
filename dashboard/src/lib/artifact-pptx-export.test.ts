import { afterEach,expect,it,vi } from 'vitest'
import JSZip from 'jszip'
import { createCanvas } from '@napi-rs/canvas'
import { canvasPptxMeasure } from './artifact-pptx-text'
import { DOMParser } from '@xmldom/xmldom'
import { artifactPptxFile } from './artifact-pptx-export'
import type { ArtifactDocument } from '../api/published-artifacts'
const A='http://schemas.openxmlformats.org/drawingml/2006/main',P='http://schemas.openxmlformats.org/presentationml/2006/main'
const pixel='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOQS9kCAAHaATfV0vUwAAAAAElFTkSuQmCC'
function document(content:string,format:'html'|'markdown'='markdown',title='한글 보고서'):ArtifactDocument {
 return {content,revisions:[],artifact:{id:`artifact-${'b'.repeat(32)}`,revision:3,title,summary:'요약',format,author:'keeper',created_at:'now',task_id:null,goal_id:null,url:'/',body:{_blob:{sha256:'c'.repeat(64)}}}}
}
const xml=(value:string)=>new DOMParser().parseFromString(value,'application/xml')
const text=(node:ReturnType<typeof xml>)=>Array.from(node.getElementsByTagNameNS(A,'t'),node=>node.textContent).join('')
async function unpack(doc:ArtifactDocument){
 const original=JSON.stringify(doc),file=await artifactPptxFile(doc,canvasPptxMeasure(createCanvas(1,1).getContext('2d')));expect(JSON.stringify(doc)).toBe(original)
 const zip=await JSZip.loadAsync(file.data),paths=Object.keys(zip.files).filter(path=>/^ppt\/slides\/slide\d+\.xml$/.test(path)).sort((a,b)=>Number(a.match(/\d+/)![0])-Number(b.match(/\d+/)![0]))
 const slides=await Promise.all(paths.map(async path=>xml(await zip.file(path)!.async('string'))))
 expect(slides).toHaveLength(file.slides)
 for(const slide of slides)for(const table of Array.from(slide.getElementsByTagNameNS(A,'tbl'))){
  const widths=Array.from(table.getElementsByTagNameNS(A,'gridCol'),column=>Number(column.getAttribute('w'))/12700)
  expect(widths.reduce((sum,width)=>sum+width,0)).toBeCloseTo(11.8*72,3)
 }

 return {file,zip,slides}
}
function tableText(slides:ReturnType<typeof xml>[],name:string):string {
 return slides.flatMap(slide=>Array.from([...Array.from(slide.getElementsByTagNameNS(P,'graphicFrame')),...Array.from(slide.getElementsByTagNameNS(P,'sp'))]).filter(frame=>frame.getElementsByTagNameNS(P,'cNvPr')[0]?.getAttribute('name')===name).map(frame=>Array.from(frame.getElementsByTagNameNS(A,'t'),node=>node.textContent).join(''))).join('')
}
afterEach(()=>vi.unstubAllGlobals())
it('creates editable Korean text, themed layouts, sections, links and a native table',async()=>{
 const {zip,slides}=await unpack(document('# 검토 보고서\n\n**중요한 결정**과 *설명*입니다.\n\n3. 첫 항목\n4. 다음 항목\n   - 하위 항목\n\n[원문](https://example.com/?a=1&b=2)\n\n| 담당 | 내용 |\n| --- | --- |\n| Keeper | 공동 편집 |'))
 expect(slides.map(slide=>text(slide)).join('')).toContain('공동 편집')
 expect(slides.some(slide=>slide.getElementsByTagNameNS(A,'tbl').length>0)).toBe(true)
 const theme=xml(await zip.file('ppt/theme/theme1.xml')!.async('string'))
 expect(theme.getElementsByTagNameNS(A,'accent1')[0]!.getElementsByTagNameNS(A,'srgbClr')[0]!.getAttribute('val')).toBe('187B68')
 const presentation=xml(await zip.file('ppt/presentation.xml')!.async('string'))
 expect(presentation.getElementsByTagName('p14:section').length).toBeGreaterThan(0)
 for(const path of Object.keys(zip.files).filter(path=>path.endsWith('.xml'))){
  const part=xml(await zip.file(path)!.async('string'))
  for(const paragraph of Array.from(part.getElementsByTagNameNS(A,'p')))expect(Array.from(paragraph.childNodes).filter(node=>node.nodeName==='a:pPr').length).toBeLessThanOrEqual(1)
  for(const color of Array.from(part.getElementsByTagNameNS(A,'srgbClr')))expect(color.getAttribute('val')).toMatch(/^[0-9A-Fa-f]{6}$/)
 }
 const rels=(await Promise.all(Object.keys(zip.files).filter(path=>path.startsWith('ppt/slides/_rels/')&&path.endsWith('.rels')).map(path=>zip.file(path)!.async('string')))).join('')
 expect(rels).toContain('https://example.com/?a=1&amp;b=2')
 expect(await zip.file('docProps/core.xml')!.async('string')).toContain('한글 보고서')
})
it('paginates long unbroken Korean text without dropping or duplicating content',async()=>{
 const body='시작'+('사람과Keeper가함께문서를편집합니다'.repeat(100))+'마지막'
 const {slides}=await unpack(document('<h1>긴 본문</h1><p>'+body+'</p>','html'))
 const output=tableText(slides,'source-text')
 expect(output).toContain('긴 본문')
 expect(output.replace('긴 본문','').replace('한글 보고서','')).toBe(body)
 expect(slides.length).toBeGreaterThan(3)
})
it('keeps every table record when rows flow across slides and repeats the table header',async()=>{
 const rows=Array.from({length:55},(_,i)=>`<tr><td>항목${i}끝</td><td>표의 내용을 빠짐없이 보관합니다. 한글 셀을 확인합니다.</td></tr>`).join('')
 const {slides}=await unpack(document('<table><thead><tr><th>식별자</th><th>검토 내용</th></tr></thead><tbody>'+rows+'</tbody></table>','html'))
 const output=tableText(slides,'source-table')
 for(let i=0;i<55;i++)expect(output.split(`항목${i}끝`)).toHaveLength(2)
 expect(output.split('식별자').length).toBeGreaterThan(2)
})
it('does not execute active source or fetch external images, and embeds only supported inline media',async()=>{
 const fetch=vi.fn();vi.stubGlobal('fetch',fetch)
 const {file,zip,slides}=await unpack(document(`<script>globalThis.pptLeak=true;fetch('https://bad.example')</script><p>보존하는 글\u0001 😀 <a href="javascript:alert(1)">링크 글</a></p><img src="data:image/png;base64,${pixel}" alt="포함 그림"><img src="https://images.example/a.png" alt="외부 그림"><svg><text>SKIP_SVG</text></svg>`,'html'))
 expect(fetch).not.toHaveBeenCalled();expect(Reflect.get(globalThis,'pptLeak')).toBeUndefined()
 const output=slides.map(slide=>text(slide)).join('')
 expect(output).toContain('보존하는 글� 😀');expect(output).toContain('[그림: 외부 그림]');expect(output).not.toContain('SKIP_SVG')
 const media=Object.keys(zip.files).filter(path=>path.startsWith('ppt/media/')&&!zip.files[path]!.dir)
 expect(media).toHaveLength(1);expect(await zip.file(media[0]!)!.async('base64')).toBe(pixel)
 expect(file.notices.length).toBeGreaterThan(0)
})
it('preserves numbers outside DrawingML limits as text instead of invalid automatic numbering',async()=>{
 const {slides}=await unpack(document('<ol start="-1"><li>음수 항목</li><li>영 항목</li><li>양수 항목</li></ol><ol start="32768"><li>큰 번호</li></ol>','html'))
 const output=tableText(slides,'source-text')
 expect(output).toContain('-1. 음수 항목');expect(output).toContain('0. 영 항목');expect(output).toContain('32768. 큰 번호')
 for(const slide of slides)for(const node of Array.from(slide.getElementsByTagNameNS(A,'buAutoNum'))){const value=Number(node.getAttribute('startAt'));expect(value).toBeGreaterThanOrEqual(1);expect(value).toBeLessThanOrEqual(32767)}
})

it('expands merged cells into a rectangular grid, preserves cell paragraphs and cleans all XML metadata',async()=>{
 const {file,zip,slides}=await unpack(document('<table><tbody><tr><td rowspan="2">A</td><td><p>NOT</p><p>ABLE</p></td></tr><tr><td>B</td></tr></tbody><tbody><tr><td rowspan="0" colspan="2">C</td></tr><tr></tr></tbody></table>','html','제목\u0001끝'))
 expect(file.notices.join(' ')).toContain('병합 표')
 const tables=slides.flatMap(slide=>Array.from(slide.getElementsByTagNameNS(A,'tbl')))
 expect(tables.map(table=>Array.from(table.getElementsByTagNameNS(A,'tc'),cell=>Array.from(cell.getElementsByTagNameNS(A,'t'),t=>t.textContent).join('|')))).toEqual([['A','NOT|ABLE'],['A','B'],['C','C'],['C','C']])
 for(const path of Object.keys(zip.files).filter(path=>path.endsWith('.xml'))){
  const value=await zip.file(path)!.async('string');expect(value).not.toContain('\u0001')
  const part=xml(value)
  for(const paragraph of Array.from(part.getElementsByTagNameNS(A,'p')))expect(Array.from(paragraph.childNodes).filter(node=>node.nodeName==='a:pPr').length).toBeLessThanOrEqual(1)
 }
})
it('splits long merged cells across slides with both start and end retained',async()=>{
 const body='MERGE_START'+('한글내용을잃지않고이어갑니다'.repeat(150))+'MERGE_END'
 const {slides}=await unpack(document(`<table><tr><td rowspan="2">${body}</td></tr><tr></tr></table>`,'html'))
 const output=tableText(slides,'source-table')
 expect(output).toBe(body+body);expect(slides.length).toBeGreaterThan(3)
})

it('shows one bullet for a long list item continued across measured lines',async()=>{
 const {slides}=await unpack(document('<ul><li><b>목록 시작</b>'+('항목의설명을함께확인합니다'.repeat(100))+'목록 끝</li></ul>','html'))
 expect(slides.flatMap(slide=>Array.from(slide.getElementsByTagNameNS(A,'p')).flatMap(paragraph=>Array.from(paragraph.getElementsByTagNameNS(A,'buChar'))))).toHaveLength(1)
 expect(tableText(slides,'source-text')).toContain('목록 끝')
})

it.each(['<h2>NOT</h2><h2>ABLE</h2>','<table><tr><td>NOT</td><td>ABLE</td></tr></table>','<dl><dt>NOT</dt><dd>ABLE</dd></dl>'])('preserves table cell block boundaries: %s',async content=>{
 const {slides}=await unpack(document(`<table><tr><td>${content}</td></tr></table>`,'html'))
 const paragraphs=slides.flatMap(slide=>Array.from(slide.getElementsByTagNameNS(A,'tc')).flatMap(cell=>Array.from(cell.getElementsByTagNameNS(A,'p'),paragraph=>Array.from(paragraph.getElementsByTagNameNS(A,'t'),node=>node.textContent).join(''))))
 expect(paragraphs).toContain('NOT');expect(paragraphs).toContain('ABLE');expect(paragraphs).not.toContain('NOTABLE')
})
