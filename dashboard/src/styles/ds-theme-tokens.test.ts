// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const cssPath = resolve(__dirname, 'ds-theme-tokens.css')
const css = readFileSync(cssPath, 'utf-8')

/**
 * Parse a CSS block for a given selector and return its declared custom
 * properties as a record. This is intentionally simple: the design-system
 * token file declares one property per line.
 */
function parseBlock(selector: string | RegExp): Record<string, string> {
  let start = 0
  if (typeof selector === 'string') {
    start = css.indexOf(selector)
  } else {
    const match = selector.exec(css)
    start = match ? match.index : -1
  }
  if (start === -1) {
    throw new Error(`Selector not found: ${selector.toString()}`)
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

describe('ds-theme-tokens.css', () => {
  it('declares dark-fantasy as the default palette', () => {
    const root = parseBlock(':root,')
    expect(root['--accent-blood']).toBe('#a01818')
    expect(root['--accent-viscera']).toBe('#c94a3a')
    expect(root['--accent-brass']).toBe('#8a6a28')
    expect(root['--bg-deep']).toBe('#0a0706')
  })

  it('cyberpunk theme overrides token values', () => {
    const theme = parseBlock('[data-theme="cyberpunk"]')
    expect(theme['--accent-blood']).toBe('#ff2266')
    expect(theme['--accent-brass']).toBe('#00ffcc')
    expect(theme['--bg-deep']).toBe('#05000f')
  })

  it('terminal theme overrides token values', () => {
    const theme = parseBlock('[data-theme="terminal"]')
    expect(theme['--accent-blood']).toBe('#ffcc00')
    expect(theme['--accent-brass']).toBe('#00ff00')
    expect(theme['--bg-deep']).toBe('#000800')
  })

  it('parchment theme overrides token values', () => {
    const theme = parseBlock('[data-theme="parchment"]')
    expect(theme['--accent-blood']).toBe('#8b4513')
    expect(theme['--accent-brass']).toBe('#c4a050')
    expect(theme['--bg-deep']).toBe('#1a1610')
  })

  it('paper theme resolves accent-blood to brick', () => {
    const theme = parseBlock('[data-theme="paper"]')
    expect(theme['--accent-blood']).toBe('var(--brick)')
    expect(theme['--accent-brass']).toBe('var(--brass)')
    expect(theme['--bg-deep']).toBe('var(--paper)')
    expect(theme['--brick']).toBe('#8B3A3A')
  })

  it('contains only the small local display @font-face on the hot path', () => {
    // The 9.9MB local Noto Sans KR TTF is intentionally not declared here;
    // index.html loads subsetted WOFF2 via the single Google Fonts request.
    expect(css).toContain("src: url('/dashboard/assets/fonts/Cinzel-Regular.ttf') format('truetype')")
    expect(css).not.toContain('NotoSansKR-Regular.ttf')
  })
})
