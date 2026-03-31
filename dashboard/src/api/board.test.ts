import { describe, expect, it } from 'vitest'
import { derivePostTitle, sanitizeBoardTitle } from './board'

describe('board title helpers', () => {
  it('strips markdown headings from derived titles', () => {
    expect(derivePostTitle('## Deploy Plan\n\nBody')).toBe('Deploy Plan')
  })

  it('skips fenced code when deriving fallback titles', () => {
    expect(derivePostTitle('```md\n# sample\n```\n\n## Real Title\ncontent')).toBe('Real Title')
  })

  it('sanitizes explicit board titles before display', () => {
    expect(sanitizeBoardTitle('## Incident Review')).toBe('Incident Review')
  })
})
