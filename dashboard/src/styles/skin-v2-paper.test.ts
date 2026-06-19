// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const cssPath = resolve(__dirname, 'skin-v2.css')
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

describe('skin-v2.css paper bridge', () => {
  it('uses the paper-theme palette instead of the old gray v2 paper spine', () => {
    const theme = parseBlock('html[data-skin="v2"][data-theme="paper"]')
    expect(theme['--bg-deep']).toBe('var(--paper)')
    expect(theme['--bg-panel']).toBe('var(--paper-2)')
    expect(theme['--border-main']).toBe('var(--border-3-paper)')
    expect(theme['--text-bright']).toBe('var(--ink)')
    expect(theme['--info']).toBe('var(--slate-accent)')
    expect(theme['--volt']).toBe('var(--brass)')
  })
})
