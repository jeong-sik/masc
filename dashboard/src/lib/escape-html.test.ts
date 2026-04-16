import { describe, it, expect } from 'vitest'
import { escapeHtml, tooltipHtml } from './escape-html'

describe('escapeHtml', () => {
  it('escapes ampersand', () => {
    expect(escapeHtml('a&b')).toBe('a&amp;b')
  })

  it('escapes angle brackets', () => {
    expect(escapeHtml('<div>')).toBe('&lt;div&gt;')
  })

  it('escapes double quotes', () => {
    expect(escapeHtml('"hello"')).toBe('&quot;hello&quot;')
  })

  it('escapes single quotes', () => {
    expect(escapeHtml("it's")).toBe('it&#39;s')
  })

  it('returns plain text unchanged', () => {
    expect(escapeHtml('hello world')).toBe('hello world')
  })

  it('escapes all special chars in one string', () => {
    expect(escapeHtml('<a href="x&y">z\'s')).toBe('&lt;a href=&quot;x&amp;y&quot;&gt;z&#39;s')
  })
})

describe('tooltipHtml', () => {
  it('joins lines with br', () => {
    expect(tooltipHtml(['a', 'b'])).toBe('a<br/>b')
  })

  it('escapes each line', () => {
    expect(tooltipHtml(['<b>', '&'])).toBe('&lt;b&gt;<br/>&amp;')
  })

  it('returns empty for empty array', () => {
    expect(tooltipHtml([])).toBe('')
  })
})
