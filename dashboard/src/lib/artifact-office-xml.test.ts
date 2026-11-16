import { expect, it } from 'vitest'
import { parseOfficeXml } from './artifact-office-xml'
import { artifactAppFrame } from './artifact-app-frame'

it('rejects duplicate expanded attribute names even when their prefixes differ', () => {
  for (const value of ['', '�']) expect(() => parseOfficeXml(`<r xmlns:a="urn:x" xmlns:b="urn:x" a:k="one" b:k="two">${value}</r>`, 'duplicate.xml')).toThrow()
  const root = parseOfficeXml('<r xmlns:a="urn:x" xmlns:b="urn:y" a:k="one" b:k="two"/>', 'distinct.xml').documentElement!
  expect(root.getAttributeNS('urn:x', 'k')).toBe('one')
  expect(root.getAttributeNS('urn:y', 'k')).toBe('two')
})

it('accepts XML 1.0 or an absent declaration and refuses other declared versions', () => {
  expect(parseOfficeXml('<?xml version="1.0"?><r/>', 'version.xml').documentElement!.localName).toBe('r')
  for (const version of ['1.1', '1.00', '1.2']) expect(() => parseOfficeXml(`<?xml version="${version}"?><r/>`, 'version.xml')).toThrow()
})

it('refuses lone surrogates before SAX can combine them with non-surrogate characters', () => {
  for (const source of ['<r>\uD800A</r>', '<r a="\uD800A"/>', '<r><!--\uD800A--></r>', '<r><![CDATA[\uD800A]]></r>', '<r><?p \uD800A?></r>']) {
    expect(() => parseOfficeXml(source, 'surrogate.xml')).toThrow()
  }
})

it('normalizes XML 1.0 CR and CRLF while preserving NEL and Unicode separators', () => {
  const separators = '\u0085\u2028\u2029'
  const root = parseOfficeXml(`<r a="${separators}">A\r\nB\rC${separators}</r>`, 'unicode.xml').documentElement!
  expect(root.textContent).toBe(`A\nB\nC${separators}`)
  expect(root.getAttribute('a')).toBe(separators)
})

it('shows a malformed chart error without refusing the rest of an HTML preview', () => {
  const frame = artifactAppFrame('<p>보존할 본문</p><figure data-masc-chart="bad&#1;&lt;script&gt;"><table></table></figure>')
  expect(frame.document).toContain('<p>보존할 본문</p>')
  expect(frame.document).toContain('role="alert"')
  expect(frame.document).toContain('&lt;script&gt;')
})
