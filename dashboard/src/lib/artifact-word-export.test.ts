import { expect,it,vi,afterEach } from 'vitest'
import JSZip from 'jszip'
import { DOMParser } from '@xmldom/xmldom'
import { artifactWordFile } from './artifact-word-export'
import type { ArtifactDocument } from '../api/published-artifacts'
const word='http://schemas.openxmlformats.org/wordprocessingml/2006/main'
const pixel='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOQS9kCAAHaATfV0vUwAAAAAElFTkSuQmCC'
function document(content:string,format:'html'|'markdown'='markdown'):ArtifactDocument {
  return {content,revisions:[],artifact:{id:`artifact-${'f'.repeat(32)}`,revision:4,title:'한국어 보고서',summary:'요약',format,author:'keeper-a',created_at:'2026-10-26T00:00:00Z',task_id:null,goal_id:null,url:'/',body:{_blob:{sha256:'a'.repeat(64)}}}}
}
async function unpack(content:string,format:'html'|'markdown'='markdown'){
  const input=document(content,format),original=JSON.stringify(input),file=await artifactWordFile(input)
  expect(JSON.stringify(input)).toBe(original)
  const zip=await JSZip.loadAsync(file.data),text=await zip.file('word/document.xml')!.async('string')
  const xml=new DOMParser().parseFromString(text,'application/xml')
  expect(xml.getElementsByTagName('parsererror')).toHaveLength(0)
  return {file,zip,xml,text}
}
afterEach(()=>vi.unstubAllGlobals())
it('produces editable Korean Word headings, lists, tables, links and preserved code line breaks from Markdown',async()=>{
  const {zip,xml,text}=await unpack('# 회의 보고서\n\n**중요한** 결정과 *설명* 및 ~~이전안~~입니다.\n\n3. 첫 항목\n4. 다음 항목\n   - 하위 항목\n\n| 담당 | 내용 |\n| --- | --- |\n| Keeper | 공동 편집 |\n\n[문서](https://example.com/?a=1&b=2)\n\n```text\n첫 줄 <원문>\n둘째 줄 & 기호\n```')
  const body=Array.from(xml.getElementsByTagNameNS(word,'t'),node=>node.textContent).join('')
  expect(body).toContain('회의 보고서');expect(body).toContain('공동 편집');expect(body).toContain('첫 줄 <원문>둘째 줄 & 기호')
  expect(xml.getElementsByTagNameNS(word,'tbl')).toHaveLength(1)
  expect(xml.getElementsByTagNameNS(word,'br').length).toBeGreaterThan(0)
  expect(text).toContain('w:val="Heading1"');expect(text).toContain('<w:b');expect(text).toContain('<w:i');expect(text).toContain('<w:strike')
  const numbering=await zip.file('word/numbering.xml')!.async('string')
  expect(numbering).toContain('w:start w:val="3"');expect(numbering).toContain('w:val="bullet"')
  const rels=new DOMParser().parseFromString(await zip.file('word/_rels/document.xml.rels')!.async('string'),'application/xml')
  expect(Array.from(rels.getElementsByTagName('Relationship')).some(node=>node.getAttribute('Target')==='https://example.com/?a=1&b=2')).toBe(true)
  expect(await zip.file('docProps/core.xml')!.async('string')).toContain('한국어 보고서')
  expect(await zip.file('word/footer1.xml')!.async('string')).toContain('v4')
})
it('embeds inline PNG bytes while turning external images into visible descriptions and safe links without fetching',async()=>{
  const fetch=vi.fn(()=>Promise.reject(new Error('no external fetch')));vi.stubGlobal('fetch',fetch)
  const {file,zip,xml}=await unpack(`<h1>그림과 표</h1><p><img src="data:image/png;base64,${pixel}" alt="작은 그림"></p><p><img src="https://images.example/a.png" alt="외부 그림"></p>`,'html')
  expect(fetch).not.toHaveBeenCalled()
  const media=Object.keys(zip.files).filter(path=>path.startsWith('word/media/')&&!zip.files[path]!.dir)
  expect(media).toHaveLength(1)
  expect(await zip.file(media[0]!)!.async('base64')).toBe(pixel)
  expect(xml.getElementsByTagNameNS(word,'drawing')).toHaveLength(1)
  expect(Array.from(xml.getElementsByTagNameNS(word,'t'),node=>node.textContent).join('')).toContain('[그림: 외부 그림]')
  expect(file.notices).toEqual(['외부 그림과 PNG·JPEG 이외의 그림은 설명과 링크로 바꿨습니다.'])
})
it('never executes active HTML or creates unsafe external relationships and replaces XML-forbidden controls',async()=>{
  const fetch=vi.fn();vi.stubGlobal('fetch',fetch)
  const {file,zip,text}=await unpack('<script>globalThis.wordExportLeak=true;fetch("https://bad.example")</script><style>secret</style><p>보존\u0001하는 글 😀 <a href="javascript:alert(1)">링크 글</a></p><svg><text>SVG_ONLY</text></svg><iframe src="https://bad.example">IFRAME_ONLY</iframe><constructor>생성자 태그의 글</constructor>','html')
  expect(fetch).not.toHaveBeenCalled();expect(Reflect.get(globalThis,'wordExportLeak')).toBeUndefined()
  expect(text).toContain('보존�하는 글 😀');expect(text).toContain('생성자 태그의 글')
  for(const skipped of ['wordExportLeak','SVG_ONLY','IFRAME_ONLY','secret','javascript:'])expect(text).not.toContain(skipped)
  expect(await zip.file('word/_rels/document.xml.rels')!.async('string')).not.toContain('javascript:')
  expect(file.notices).toContain('Word에서 표현할 수 없는 문자는 대체 문자로 바꿨습니다.')
})
it('retains table cell spans and allocates a grid including columns occupied by earlier row spans',async()=>{
  const {xml}=await unpack('<table><caption>병합 표</caption><tr><td rowspan="2">공통</td></tr><tr><td>하나</td><td colspan="2">둘과 셋</td></tr></table>','html')
  expect(xml.getElementsByTagNameNS(word,'gridCol')).toHaveLength(4)
  expect(xml.getElementsByTagNameNS(word,'gridSpan').length).toBeGreaterThan(0)
  expect(xml.getElementsByTagNameNS(word,'vMerge').length).toBeGreaterThan(0)
  expect(Array.from(xml.getElementsByTagNameNS(word,'t'),node=>node.textContent).join('')).toContain('공통하나둘과 셋')
})
it('keeps rowspan inside each table row group and applies only the innermost vertical alignment',async()=>{
  for(const span of ['0','99']){
    const {xml}=await unpack(`<table><thead><tr><th rowspan="${span}">제목</th><th>제목2</th></tr></thead><tbody><tr><td>본문A</td><td>본문B</td></tr></tbody></table>`,'html')
    expect(xml.getElementsByTagNameNS(word,'gridCol')).toHaveLength(2)
    expect(xml.getElementsByTagNameNS(word,'vMerge')).toHaveLength(0)
  }
  const {xml}=await unpack('<p>기본<sup>위<sub>아래</sub></sup><sub>아래<sup>다시 위</sup></sub></p>','html')
  const runs=Array.from(xml.getElementsByTagNameNS(word,'r'))
  for(const [text,expected] of [['아래','subscript'],['다시 위','superscript']]){
    const run=runs.find(run=>Array.from(run.getElementsByTagNameNS(word,'t')).some(node=>node.textContent===text))!
    const align=Array.from(run.getElementsByTagNameNS(word,'vertAlign'))
    expect(align).toHaveLength(1);expect(align[0]!.getAttribute('w:val')).toBe(expected)
  }
})

it('omits document metadata and comments without adding blank paragraphs before the body',async()=>{
  const {xml}=await unpack('<!doctype html><!-- comment --><html><head><title>메타 제목</title></head><body><h1>본문 제목</h1><!-- last comment --></body></html>','html')
  const paragraphs=xml.getElementsByTagNameNS(word,'p')
  expect(paragraphs).toHaveLength(1)
  expect(paragraphs[0]!.getElementsByTagNameNS(word,'t')[0]!.textContent).toBe('본문 제목')
})
it('keeps a heading with its next paragraph when Word paginates the document',async()=>{
  const {xml}=await unpack('# 첫 제목\n\n본문\n\n## 다음 제목\n\n다음 본문')
  const headings=Array.from(xml.getElementsByTagNameNS(word,'p')).filter(paragraph=>paragraph.getElementsByTagNameNS(word,'pStyle').length>0)
  expect(headings).toHaveLength(2)
  for(const heading of headings)expect(heading.getElementsByTagNameNS(word,'keepNext')).toHaveLength(1)
  for(const paragraph of Array.from(xml.getElementsByTagNameNS(word,'p')).filter(paragraph=>paragraph.getElementsByTagNameNS(word,'pStyle').length===0))expect(paragraph.getElementsByTagNameNS(word,'keepNext')).toHaveLength(0)
})
it('preserves definition list term and description block boundaries as separate paragraphs',async()=>{
  const {xml}=await unpack('<dl><dt>NOT</dt><dd>ABLE</dd></dl>','html')
  const paragraphs=Array.from(xml.getElementsByTagNameNS(word,'p'),paragraph=>
    Array.from(paragraph.getElementsByTagNameNS(word,'t'),node=>node.textContent).join(''))
  expect(paragraphs).toEqual(['NOT','ABLE'])
})
