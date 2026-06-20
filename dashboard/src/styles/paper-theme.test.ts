// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const cssPath = resolve(__dirname, 'paper-theme.css')
const css = readFileSync(cssPath, 'utf-8')

function parseBlock(selector: string): Record<string, string> {
  const start = css.indexOf(selector)
  if (start === -1) {
    throw new Error(`Selector not found: ${selector}`)
  }

  const open = css.indexOf('{', start)
  let depth = 0
  let close = open
  for (let i = open; i < css.length; i++) {
    if (css[i] === '{') depth++
    if (css[i] === '}') {
      depth--
      if (depth === 0) {
        close = i
        break
      }
    }
  }

  const block = css.slice(open + 1, close)
  const vars: Record<string, string> = {}
  for (const line of block.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('/*')) continue
    const match = /^(--[\w-]+):\s*([^;]+);/.exec(trimmed)
    if (match && match[1] && match[2]) {
      vars[match[1]] = match[2].trim()
    }
  }
  return vars
}

describe('paper-theme.css', () => {
  it('uses html[data-theme="paper"] so later :root v2 tokens cannot override it', () => {
    expect(css).toContain('html[data-theme="paper"] {')
  })

  it('bridges paper values into migrated StyleSeed shell tokens', () => {
    const theme = parseBlock('html[data-theme="paper"]')
    expect(theme['--ss-page']).toBe('var(--paper)')
    expect(theme['--ss-card']).toBe('var(--paper-2)')
    expect(theme['--ss-brand']).toBe('var(--brass)')
    expect(theme['--color-bg-page']).toBe('var(--paper)')
    expect(theme['--color-fg-primary']).toBe('var(--ink)')
  })

  it('assigns distinct paper colors to operator, keeper, and tool chat surfaces', () => {
    const theme = parseBlock('html[data-theme="paper"]')
    expect(theme['--chat-operator-bg']).toBe('var(--brass-fill)')
    expect(theme['--chat-keeper-bg']).toBe('var(--teal-fill)')
    expect(theme['--chat-tool-bg']).toBe('var(--slate-accent-fill)')
    expect(theme['--accent']).toBe('var(--slate-accent)')
  })
})
