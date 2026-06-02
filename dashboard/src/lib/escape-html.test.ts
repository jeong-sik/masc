// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { escapeHtml, tooltipHtml } from './escape-html'

describe('escapeHtml', () => {
  it('escapes ampersand', () => {
    expect(escapeHtml('a & b')).toBe('a &amp; b')
  })

  it('escapes less-than', () => {
    expect(escapeHtml('1 < 2')).toBe('1 &lt; 2')
  })

  it('escapes greater-than', () => {
    expect(escapeHtml('2 > 1')).toBe('2 &gt; 1')
  })

  it('escapes double quote', () => {
    expect(escapeHtml('say "hi"')).toBe('say &quot;hi&quot;')
  })

  it('escapes single quote', () => {
    expect(escapeHtml("it's")).toBe('it&#39;s')
  })

  it('escapes all in one string', () => {
    expect(escapeHtml('<a href="x">\'y\' & z</a>')).toBe(
      '&lt;a href=&quot;x&quot;&gt;&#39;y&#39; &amp; z&lt;/a&gt;'
    )
  })

  it('returns empty string for empty input', () => {
    expect(escapeHtml('')).toBe('')
  })
})

describe('tooltipHtml', () => {
  it('joins lines with br', () => {
    expect(tooltipHtml(['a', 'b', 'c'])).toBe('a<br/>b<br/>c')
  })

  it('escapes each line', () => {
    expect(tooltipHtml(['a < b', 'x & y'])).toBe('a &lt; b<br/>x &amp; y')
  })

  it('returns empty string for empty array', () => {
    expect(tooltipHtml([])).toBe('')
  })
})
