// @vitest-environment node
import { readFileSync } from 'node:fs'
import { afterEach,expect,it,vi } from 'vitest'
import { PDFDocument,PDFName,PDFDict,PDFArray,PDFRawStream,decodePDFRawStream } from 'pdf-lib'
import { artifactPdfFile } from './artifact-pdf-export'
import type { ArtifactDocument } from '../api/published-artifacts'
const fonts={regular:new Uint8Array(readFileSync(new URL('../assets/pdf-fonts/NotoSansKR-Regular.otf',import.meta.url))),bold:new Uint8Array(readFileSync(new URL('../assets/pdf-fonts/NotoSansKR-Bold.otf',import.meta.url))),emoji:new Uint8Array(readFileSync(new URL('../assets/pdf-fonts/NotoEmoji.ttf',import.meta.url)))}
function doc(content:string,format:'html'|'markdown'='markdown'):ArtifactDocument {return {content,revisions:[],artifact:{id:`artifact-${'d'.repeat(32)}`,revision:4,title:'한글 보고서',summary:'요약',format,author:'keeper',created_at:'now',task_id:null,goal_id:null,url:'/',body:{_blob:{sha256:'e'.repeat(64)}}}}}
async function pdf(source:ArtifactDocument){const before=JSON.stringify(source),file=await artifactPdfFile(source,fonts);expect(JSON.stringify(source)).toBe(before);return {file,pdf:await PDFDocument.load(file.data)}}
function resources(document:PDFDocument){return document.getPages().map(page=>page.node.Resources()!)}
afterEach(()=>vi.unstubAllGlobals())
it('creates a Korean PDF with embedded fonts, metadata, native text, links and tables',async()=>{
 const {pdf:document}=await pdf(doc('# 검토 보고서\n\n**중요한 결정**과 설명입니다. 😀 👩‍💻\n\n[원문](https://example.com/?a=1&b=2)\n\n| 담당 | 내용 |\n| --- | --- |\n| Keeper | 공동 편집 |'))
 expect(document.getTitle()).toBe('한글 보고서');expect(document.getAuthor()).toBe('keeper');expect(document.getSubject()).toContain('v4')
 const fontNames=resources(document).flatMap(resource=>resource.lookup(PDFName.of('Font'),PDFDict).values().map(ref=>document.context.lookup(ref,PDFDict).lookup(PDFName.of('BaseFont'),PDFName).decodeText()))
 expect(fontNames.some(name=>name.includes('NotoSansKR'))).toBe(true);expect(fontNames.some(name=>name.includes('NotoEmoji'))).toBe(true)
 for(const resource of resources(document))for(const ref of resource.lookup(PDFName.of('Font'),PDFDict).values()){
  const font=document.context.lookup(ref,PDFDict)
  expect(font.lookup(PDFName.of('ToUnicode'))).toBeInstanceOf(PDFRawStream)
  const descendant=font.lookup(PDFName.of('DescendantFonts'),PDFArray).lookup(0,PDFDict),descriptor=descendant.lookup(PDFName.of('FontDescriptor'),PDFDict)
  expect(descriptor.has(PDFName.of('FontFile2'))||descriptor.has(PDFName.of('FontFile3'))).toBe(true)
 }
 const links=document.getPages().flatMap(page=>page.node.Annots()?.asArray()??[]).map(ref=>document.context.lookup(ref,PDFDict)).filter(annotation=>annotation.has(PDFName.of('A')))
 expect(links.length).toBeGreaterThan(0)
 for(const link of links)expect(link.lookup(PDFName.of('A'),PDFDict).lookup(PDFName.of('URI'))!.toString()).toContain('https://example.com/')
})
it('paginates unbroken Korean, long ASCII words and long merged table cells',async()=>{
 const {pdf:document}=await pdf(doc('<h1>긴 한글</h1><p>'+('사람과Keeper가함께문서를편집합니다'.repeat(150))+'</p><p>'+('LONG_TOKEN'.repeat(80))+'</p><table><thead><tr><th>검토</th></tr></thead><tbody><tr><td rowspan="2">'+('병합한글셀의본문입니다'.repeat(100))+'</td></tr><tr></tr></tbody></table>','html'))
 expect(document.getPageCount()).toBeGreaterThan(1)
 for(const page of document.getPages())expect(page.getSize()).toEqual({width:595.28,height:841.89})
})
it('does not execute active source, fetch resources or embed unsafe link actions',async()=>{
 const fetch=vi.fn();vi.stubGlobal('fetch',fetch)
 const {file,pdf:document}=await pdf(doc('<script>globalThis.pdfLeak=true;fetch("https://bad.example")</script><p>보존 <a href="javascript:alert(1)">링크 글</a></p><img src="https://bad.example/a.png" alt="외부 그림"><p>미지원 \u{10FFFF}</p>','html'))
 expect(fetch).not.toHaveBeenCalled();expect(Reflect.get(globalThis,'pdfLeak')).toBeUndefined();expect(file.notices.join(' ')).toContain('외부 그림');expect(file.notices.join(' ')).toContain('유니코드 번호')
 expect(document.catalog.has(PDFName.of('OpenAction'))).toBe(false);expect(document.catalog.has(PDFName.of('AA'))).toBe(false)
 const streams=document.context.enumerateIndirectObjects().flatMap(([,object])=>object instanceof PDFRawStream?[new TextDecoder().decode(decodePDFRawStream(object).decode())]:[]).join('')
 expect(streams).not.toContain('javascript:');expect(streams).not.toContain('pdfLeak')
})

it('keeps an oversized table header instead of losing its unbreakable repeated block',async()=>{
 const {file,pdf:document}=await pdf(doc('<table><thead><tr><th>HEADER_START'+('헤더한글문장'.repeat(600))+'HEADER_END</th></tr></thead><tbody><tr><td>BODY_END</td></tr></tbody></table>','html'))
 expect(document.getPageCount()).toBeGreaterThan(1)
 expect(file.notices.join(' ')).toContain('표 머리글은 반복하지 않고')
 const maps=resources(document).flatMap(resource=>resource.lookup(PDFName.of('Font'),PDFDict).values().map(ref=>{
  const font=document.context.lookup(ref,PDFDict),stream=font.lookup(PDFName.of('ToUnicode'))
  return stream instanceof PDFRawStream?new TextDecoder().decode(decodePDFRawStream(stream).decode()).toLowerCase():''
 })).join('')
 for(const character of '헤더한글문장')expect(maps).toContain(character.codePointAt(0)!.toString(16))
})

it.each(['<h1>WWWW0END</h1>','<h1>한글</h1>','<ul><li><h1>한글</h1></li></ul>','<table><tr><td><h1>한글</h1></td></tr></table>'])('partitions wide tables using actual heading, indentation and nested-table geometry: %s',async cell=>{
 const {file,pdf:document}=await pdf(doc('<table><tr>'+Array.from({length:15},()=>`<td>${cell}</td>`).join('')+'</tr></table>','html'))
 expect(file.notices.join(' ')).toContain('넓은 표는 열을 나눴으며');expect(document.getPageCount()).toBeGreaterThanOrEqual(1)
})

it('discloses unsupported joiners instead of passing a missing glyph into the PDF text layer',async()=>{
 const {file}=await pdf(doc('<p>A\u200DB ❤️ 👩‍💻</p>','html'))
 expect(file.notices.join(' ')).toContain('유니코드 번호')
})
