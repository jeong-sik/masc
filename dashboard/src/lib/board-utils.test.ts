import { describe, it, expect } from 'vitest'
import { stripInlineMarkdown } from './board-utils'

describe('stripInlineMarkdown', () => {
  it('strips bold markers', () => {
    expect(stripInlineMarkdown('**Hello World**')).toBe('Hello World')
  })

  it('strips underscore bold markers', () => {
    expect(stripInlineMarkdown('__Hello World__')).toBe('Hello World')
  })

  it('strips italic markers', () => {
    expect(stripInlineMarkdown('*italic text*')).toBe('italic text')
  })

  it('strips underscore italic markers', () => {
    expect(stripInlineMarkdown('_italic text_')).toBe('italic text')
  })

  it('strips inline code markers', () => {
    expect(stripInlineMarkdown('`code`')).toBe('code')
  })

  it('strips mixed formatting', () => {
    expect(stripInlineMarkdown('**Bold** and *italic* and `code`'))
      .toBe('Bold and italic and code')
  })

  it('preserves plain text', () => {
    expect(stripInlineMarkdown('plain text')).toBe('plain text')
  })

  it('handles empty string', () => {
    expect(stripInlineMarkdown('')).toBe('')
  })
})
