import { describe, expect, it } from 'vitest'
import { escapeHtml } from './html-escape'

describe('escapeHtml', () => {
  it('escapes text and attribute delimiters', () => {
    expect(escapeHtml(`&<>"'`)).toBe('&amp;&lt;&gt;&quot;&#39;')
  })

  it('leaves ordinary text unchanged', () => {
    expect(escapeHtml('plain text 123')).toBe('plain text 123')
  })
})
