import { expect, it } from 'vitest'
import { artifactMarkdownTextEditor } from './artifact-markdown-text'
import { selectedArtifactText } from './artifact-text-frame'
import { replaceSharedSelection, seedSharedDocument, selectSharedSource, sharedSource } from './artifact-shared-document'

it('maps GFM headings, inline formatting, repeated table cells and tasks to original UTF16 source spans',()=>{
  const source='# 한글 😀\r\n\r\n**굵은 글** &amp; \\*별\\*\r\n\r\n| 열 | 값 |\r\n| - | - |\r\n| 같은 글 | 같은 글 |\r\n\r\n- [x] 목록\r\n'
  const editor=artifactMarkdownTextEditor(source)
  expect(editor.parts.map(p=>p.text)).toEqual(['한글 😀','굵은 글',' & *별*','열','값','같은 글','같은 글','목록'])
  for(const part of editor.parts)expect(source.slice(part.start,part.end)).toBe(part.raw)
  const dom=new DOMParser().parseFromString(editor.document,'text/html')
  expect(dom.querySelector('h1')?.textContent).toBe('한글 😀');expect(dom.querySelector('strong')?.textContent).toBe('굵은 글')
  expect(dom.querySelectorAll('tbody td')).toHaveLength(2)
  expect(dom.querySelector('input')?.hasAttribute('disabled')).toBe(true)
})
it('translates parser offsets back across the initial BOM without cutting emoji or removing source markers',()=>{
  for(const source of ['\uFEFF# 한글 😀\r\n\r\n본문 &amp; 끝','\uFEFF\uFEFF한글 😀']) {
    const editor=artifactMarkdownTextEditor(source),doc=seedSharedDocument(source)
    try {
      for(const part of editor.parts) {
        const range=selectSharedSource(doc,{anchor:part.start,head:part.end})
        expect(range).toBeTruthy();expect(source.slice(part.start,part.end)).toBe(part.raw)
      }
      const first=editor.parts[0]!
      expect(first.raw).toBe(first.text)
      replaceSharedSelection(doc,selectSharedSource(doc,{anchor:first.start,head:first.end}),first.raw,'바꾼 글 😀')
      expect(sharedSource(doc)).toBe(source.slice(0,first.start)+'바꾼 글 😀'+source.slice(first.end))
      expect(sharedSource(doc).charCodeAt(0)).toBe(0xFEFF)
    } finally {doc.destroy()}
  }
})
it('changes only the chosen repeated cell after a concurrent insert, retaining table syntax, CRLF and emoji',()=>{
  const source='한글 😀\r\n\r\n| 제목 | 값 |\r\n| - | - |\r\n| 같은 글 | 같은 글 |\r\n'
  const part=artifactMarkdownTextEditor(source).parts.filter(p=>p.text==='같은 글')[1]!,doc=seedSharedDocument(source)
  try {
    const selection=selectSharedSource(doc,{anchor:part.start,head:part.end})
    doc.getText('content').insert(0,'사람이 추가\r\n\r\n')
    replaceSharedSelection(doc,selection,part.raw,'**새 값**')
    expect(sharedSource(doc)).toBe('사람이 추가\r\n\r\n'+source.slice(0,part.start)+'**새 값**'+source.slice(part.end))
    expect(new DOMParser().parseFromString(artifactMarkdownTextEditor(sharedSource(doc)).document,'text/html').querySelector('tbody strong')?.textContent).toBe('새 값')
  } finally {doc.destroy()}
})
it('refuses a changed original quote instead of matching another occurrence',()=>{
  const source='같은 글\r\n\r\n같은 글',part=artifactMarkdownTextEditor(source).parts[0]!,doc=seedSharedDocument(source)
  try {
    const selection=selectSharedSource(doc,{anchor:part.start,head:part.end})
    doc.getText('content').insert(part.start+1,'!')
    expect(()=>replaceSharedSelection(doc,selection,part.raw,'수정')).toThrow('선택한 내용이 바뀌었습니다')
    expect(sharedSource(doc)).toBe('같!은 글\r\n\r\n같은 글')
  } finally {doc.destroy()}
})
it('shows references, footnotes and soft breaks without inventing positions for generated labels',()=>{
  const source='[보이는 글][ref]\r\n다음 줄[^1]\r\n\r\n[ref]: https://example.test\r\n[^1]: 각주 본문\r\n'
  const editor=artifactMarkdownTextEditor(source),dom=new DOMParser().parseFromString(editor.document,'text/html')
  expect(editor.parts.some(p=>p.text==='보이는 글')).toBe(true)
  expect(editor.parts.some(p=>p.text==='각주 본문')).toBe(true)
  expect(dom.querySelector('br')).not.toBeNull()
  for(const part of editor.parts)expect(source.slice(part.start,part.end)).toBe(part.raw)
  expect(editor.parts.some(p=>p.text==='각주'||p.text==='↩')).toBe(false)
  expect(dom.querySelector('a[href]')).toBeNull()
})
it('keeps embedded HTML inert and strips forged editing markers before the only capability-bearing script is added',()=>{
  const source='<div data-masc-artifact-text="0" nonce="forged"><script nonce="forged">bad()</script><form action="https://bad.test"><input autofocus></form></div>\n\n**편집할 글**'
  const editor=artifactMarkdownTextEditor(source),dom=new DOMParser().parseFromString(editor.document,'text/html')
  expect(dom.querySelectorAll('script')).toHaveLength(1);expect(dom.querySelector('script')?.getAttribute('nonce')).toBe(editor.token)
  expect(editor.document).not.toContain('bad()');expect(editor.document).not.toContain('forged')
  expect(dom.querySelectorAll('[data-masc-artifact-text]')).toHaveLength(1)
  expect(dom.querySelector('[data-masc-artifact-text]')?.textContent).toBe('편집할 글')
  expect(dom.querySelector('[action],[href],[autofocus]')).toBeNull()
  expect(editor.document.indexOf('Content-Security-Policy')).toBeLessThan(editor.document.indexOf('<html'))
  expect(editor.document).toContain("connect-src 'none'")
})
it('binds selected Markdown text to the current frame capability and keeps raw Markdown separate from displayed entities',()=>{
  const editor=artifactMarkdownTextEditor('문장 &amp; \\*그대로\\*')
  const message={type:'masc.artifact.text.selected.v1',token:editor.token,id:0}
  expect(selectedArtifactText(editor,message)?.raw).toBe('문장 &amp; \\*그대로\\*')
  expect(selectedArtifactText(editor,message)?.text).toBe('문장 & *그대로*')
  expect(selectedArtifactText(artifactMarkdownTextEditor('다른 원고'),message)).toBeNull()
})
