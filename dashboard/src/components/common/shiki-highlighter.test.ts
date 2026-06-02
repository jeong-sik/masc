import { describe, expect, it } from 'vitest'
import { highlightCodeHtml, highlightCodeLines } from './shiki-highlighter'

describe('shiki-highlighter', () => {
  it('returns sanitized shiki block html', async () => {
    const html = await highlightCodeHtml('const x = 1', 'typescript')

    expect(html).toContain('<pre')
    expect(html).toContain('const')
    expect(html).toContain('x')
    expect(html).not.toContain('<script>')
  })

  it('extracts sanitized line html for editor rows', async () => {
    const lines = await highlightCodeLines('const x = 1\n\nreturn x', 'ts', 3)
    const firstLine = document.createElement('span')
    firstLine.innerHTML = lines[0] ?? ''

    expect(lines).toHaveLength(3)
    expect(firstLine.textContent).toContain('const x = 1')
    expect(lines[1]).toBe('')
  })

  it('keeps dangerous-looking code as text, not DOM', async () => {
    const lines = await highlightCodeLines('<script>alert("xss")</script>', 'html', 1)
    const line = document.createElement('span')
    line.innerHTML = lines[0] ?? ''

    expect(line.querySelector('script')).toBeNull()
    expect(line.textContent).toContain('<script>alert("xss")</script>')
  })
})
