import { describe, expect, it } from 'vitest'
import { parse, defaultTreeAdapter as tree, type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { selectedArtifactText } from './artifact-text-frame'
import { artifactHtmlTextEditor, escapeArtifactHtmlText } from './artifact-html-text'
import { replaceSharedSelection, seedSharedDocument, selectSharedSource, sharedSource } from './artifact-shared-document'

function elements(source: string): Nodes.Element[] {
  const result: Nodes.Element[] = []
  function visit(node: Nodes.ParentNode) {
    for (const child of node.childNodes) if (tree.isElementNode(child)) { result.push(child); visit(child) }
  }
  visit(parse(source)); return result
}
describe('HTML sentence editing source spans', () => {
  it('locates repeated text, entities, CRLF and emoji without normalizing the source', () => {
    const source = '<!doctype html>\r\n<p>한글 😀 &amp; 친구</p>\r\n<p>한글 😀 &amp; 친구</p>'
    const editor = artifactHtmlTextEditor(source)
    expect(editor.parts).toHaveLength(2)
    expect(editor.parts[0]!.text).toBe('한글 😀 & 친구')
    expect(editor.parts[0]!.raw).toBe('한글 😀 &amp; 친구')
    expect(editor.parts[1]!.start).toBeGreaterThan(editor.parts[0]!.end)
    for (const part of editor.parts) expect(source.slice(part.start, part.end)).toBe(part.raw)
  })
  it('retains nested formatting and edits only the chosen text through shared anchors', () => {
    const source = '<style>p{color:red}</style>\r\n<p>alpha <strong>bold</strong> tail</p>'
    const editor = artifactHtmlTextEditor(source), part = editor.parts.find(part => part.text === 'bold')!
    const doc = seedSharedDocument(source)
    try {
      const selection = selectSharedSource(doc, { anchor: part.start, head: part.end })
      doc.getText('content').insert(0, '<!-- 사람이 추가 -->\r\n')
      replaceSharedSelection(doc, selection, part.raw, escapeArtifactHtmlText('새 문장 <안전> & 친구'))
      expect(sharedSource(doc)).toBe('<!-- 사람이 추가 -->\r\n'+source.replace('>bold<', '>새 문장 &lt;안전&gt; &amp; 친구<'))
    } finally { doc.destroy() }
  })
  it('refuses a stale sentence after another editor changes the same text', () => {
    const source = '<p>alpha</p>', part = artifactHtmlTextEditor(source).parts[0]!, doc = seedSharedDocument(source)
    try {
      const selection = selectSharedSource(doc, { anchor: part.start, head: part.end })
      doc.getText('content').insert(part.start+1, '!')
      expect(() => replaceSharedSelection(doc, selection, part.raw, 'new')).toThrow('선택한 내용이 바뀌었습니다')
      expect(sharedSource(doc)).toBe('<p>a!lpha</p>')
    } finally { doc.destroy() }
  })
  it('keeps special text and foreign nodes out of editable spans', () => {
    const editor = artifactHtmlTextEditor('<title>title</title><style>css</style><p>body</p><textarea>input</textarea><select><option>option</option></select><svg><text>svg</text></svg><template>template</template>')
    expect(editor.parts.map(part => part.text)).toEqual(['body'])
  })
  it('handles corrected table trees and escaped markup using parser source locations', () => {
    const source = '<table><tr><td>cell &lt;b&gt;</table><p>tail'
    const editor = artifactHtmlTextEditor(source)
    expect(editor.parts.map(part => part.raw)).toEqual(['cell &lt;b&gt;', 'tail'])
    expect(editor.parts.map(part => source.slice(part.start, part.end))).toEqual(editor.parts.map(part => part.raw))
  })
  it('never turns a repaired discontiguous text location into a replacement of table markup', () => {
    const source = 'foo<table>bar<tr><td>cell</td></tr>baz</table>tail'
    const editor = artifactHtmlTextEditor(source)
    expect(editor.parts.map(part => part.raw)).toEqual(['cell', 'tail'])
    expect(artifactHtmlTextEditor('<p>a</bad>b</p>').parts).toHaveLength(0)
    expect(artifactHtmlTextEditor('<p>2 < 3 &amp; 4</p>').parts[0]!.text).toBe('2 < 3 & 4')
    expect(artifactHtmlTextEditor('<p>one\r\ntwo &#13; three</p>').parts[0]!.text).toBe('one\ntwo \r three')
  })
})
describe('HTML editing frame authority', () => {
  it('removes original scripts, nested frames and original nonces; only the generated script can run', () => {
    const editor = artifactHtmlTextEditor('<meta http-equiv="Content-Security-Policy" content="script-src *"><base href="https://bad.test"><script nonce="forged">parent.postMessage(1,"*")</script><iframe srcdoc="bad"></iframe><p onclick="evil()" nonce="forged" data-masc-artifact-text="400">safe</p>')
    const nodes = elements(editor.document), scripts = nodes.filter(node => node.tagName === 'script')
    expect(scripts).toHaveLength(1)
    expect(scripts[0]!.attrs).toEqual([{ name: 'nonce', value: editor.token }])
    expect(nodes.some(node => ['base','iframe'].includes(node.tagName))).toBe(false)
    const csp = nodes.find(node => node.tagName === 'meta' && node.attrs.some(attr => attr.name === 'http-equiv'))!.attrs.find(attr => attr.name === 'content')!.value
    expect(csp).toContain(`script-src 'nonce-${editor.token}'`)
    expect(csp.split(';').find(directive => directive.trim().startsWith('script-src'))?.trim()).toBe(`script-src 'nonce-${editor.token}'`)
    expect(csp).toContain("connect-src 'none'")
    expect(nodes.filter(node => node.attrs.some(attr => attr.name === 'nonce'))).toEqual(scripts)
    expect(nodes.filter(node => node.attrs.some(attr => attr.name === 'data-masc-artifact-text'))).toHaveLength(1)
  })
  it('disables navigation, form controls and document contenteditable in the editing projection', () => {
    const nodes = elements(artifactHtmlTextEditor('<a href="https://bad.test">link</a><form action="https://bad.test"><input autofocus><button formaction="https://bad.test">send</button></form><p contenteditable>text</p>').document)
    expect(nodes.some(node => node.attrs.some(attr => ['href','action','formaction','contenteditable','autofocus'].includes(attr.name)))).toBe(false)
    expect(nodes.filter(node => ['input','button'].includes(node.tagName)).every(node => node.attrs.some(attr => attr.name === 'disabled'))).toBe(true)
  })
  it('places the resource policy before original root styles or attributes', () => {
    const editor = artifactHtmlTextEditor('<html style="background:url(https://bad.test/pixel)"><head></head><body>text</body></html>')
    expect(editor.document.indexOf('Content-Security-Policy')).toBeLessThan(editor.document.indexOf('<html style='))
  })
  it('accepts only an existing sentence with the current frame capability', () => {
    const editor = artifactHtmlTextEditor('<p>alpha</p>')
    const message = { type: 'masc.artifact.text.selected.v1', token: editor.token, id: 0 }
    expect(selectedArtifactText(editor, message)).toBe(editor.parts[0])
    for (const bad of [null, {}, {...message, token:'other'}, {...message, id:99}, {...message, id:-1}, {...message, id:0.2}, {...message, id:'0'}, {...message, type:'edit'}]) expect(selectedArtifactText(editor,bad)).toBeNull()
    expect(selectedArtifactText(artifactHtmlTextEditor('<p>alpha</p>'),message)).toBeNull()
  })
  it('makes legacy frameset documents inert and sanitizes template contents too', () => {
    expect(elements(artifactHtmlTextEditor('<html><head></head><frameset><frame src="https://bad.test"></frameset></html>').document).some(node => node.tagName === 'body')).toBe(true)
    const editor = artifactHtmlTextEditor('<template><script nonce="forged">bad()</script><p nonce="forged">inert</p></template><p>body</p>')
    expect(editor.document).not.toContain('forged')
    expect(editor.document).not.toContain('bad()')
  })
})
