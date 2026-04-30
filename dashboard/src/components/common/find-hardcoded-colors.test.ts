import { describe, expect, it } from 'vitest'
import {
  findHardcodedColorsInContent,
  findHardcodedColorsInFiles,
} from './find-hardcoded-colors'

describe('findHardcodedColorsInContent', () => {
  it('finds hex colors in CSS', () => {
    const css = '.btn { color: #ff0000; background: #00f; }'
    const results = findHardcodedColorsInContent('test.css', css)
    expect(results).toHaveLength(2)
    expect(results[0].color).toBe('#ff0000')
    expect(results[1].color).toBe('#00f')
  })

  it('reports line numbers', () => {
    const css = 'line1\nline2\n.btn { color: #abc; }'
    const results = findHardcodedColorsInContent('test.css', css)
    expect(results[0].line).toBe(3)
  })

  it('ignores allowed keywords', () => {
    const css = '.btn { color: transparent; border: inherit; }'
    const results = findHardcodedColorsInContent('test.css', css)
    expect(results).toHaveLength(0)
  })

  it('finds 8-digit hex', () => {
    const css = '.btn { color: #ff000080; }'
    const results = findHardcodedColorsInContent('test.css', css)
    expect(results[0].color).toBe('#ff000080')
  })
})

describe('findHardcodedColorsInFiles', () => {
  it('aggregates across multiple files', () => {
    const files = [
      { path: 'a.css', content: '.a { color: #f00; }' },
      { path: 'b.css', content: '.b { color: #0f0; }' },
    ]
    const results = findHardcodedColorsInFiles(files)
    expect(results).toHaveLength(2)
    expect(results.some((r) => r.file === 'a.css')).toBe(true)
    expect(results.some((r) => r.file === 'b.css')).toBe(true)
  })
})
