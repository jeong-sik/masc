// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const cssPath = resolve(__dirname, 'styleseed-theme.css')
const css = readFileSync(cssPath, 'utf-8')
const v2ThemeCss = readFileSync(resolve(__dirname, 'v2-theme.css'), 'utf-8')
// skin-v2.css is the single SSOT for the dark v2 token block (the former
// v2-skin-tokens.css duplicate was removed). It carries the same guard.
const skinV2Css = readFileSync(resolve(__dirname, 'skin-v2.css'), 'utf-8')

/**
 * Parse a CSS block for a given selector and return its declared custom
 * properties as a record.
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

describe('styleseed-theme.css', () => {
  it('uses [data-theme="styleseed"] as the opt-in selector', () => {
    expect(css).toContain('[data-theme="styleseed"]')
  })

  it('declares all required light-mode tokens', () => {
    const light = parseBlock('[data-theme="styleseed"]')
    expect(light['--background']).toBe('#FAFAFA')
    expect(light['--card']).toBe('#FFFFFF')
    expect(light['--surface-page']).toBe('#FAFAFA')
    expect(light['--brand']).toBe('#721FE5')
    expect(light['--text-primary']).toBe('#3C3C3C')
    expect(light['--text-secondary']).toBe('#6B6B6B')
    expect(light['--text-tertiary']).toBe('#9B9B9B')
    expect(light['--text-disabled']).toBe('#BDBDBD')
    expect(light['--success']).toBe('#6B9B7A')
    expect(light['--destructive']).toBe('#D4183D')
    expect(light['--warning']).toBe('#D97706')
    expect(light['--info']).toBe('#3B82F6')
    expect(light['--border']).toBe('#E8E6E1')
    expect(light['--surface-muted']).toBe('#E8E6E1')
    expect(light['--surface-subtle']).toBe('#FAFAF9')
    expect(light['--shadow-card']).toBe('0 1px 3px rgba(0, 0, 0, 0.04)')
    expect(light['--shadow-elevated']).toBe('0 4px 12px rgba(0, 0, 0, 0.08)')
    expect(light['--shadow-modal']).toBe('0 8px 24px rgba(0, 0, 0, 0.12)')
    expect(light['--radius']).toBe('0.625rem')
  })

  it('switches token values for dark mode', () => {
    const dark = parseBlock(/\[data-theme="styleseed"\]\.dark/)
    expect(dark['--surface-page']).toBe('#121212')
    expect(dark['--card']).toBe('#1E1E1E')
    expect(dark['--surface-subtle']).toBe('#252525')
    expect(dark['--text-primary']).toBe('#E0E0E0')
    expect(dark['--text-secondary']).toBe('#A0A0A0')
    expect(dark['--text-tertiary']).toBe('#808080')
    expect(dark['--text-disabled']).toBe('#555555')
    expect(dark['--brand']).toBe('#9B5FFF')
    expect(dark['--success']).toBe('#8FBF9A')
    expect(dark['--destructive']).toBe('#FF5C5C')
    expect(dark['--warning']).toBe('#FFB347')
    expect(dark['--info']).toBe('#64B5F6')
    expect(dark['--shadow-card']).toBe('none')
    expect(dark['--card-border']).toBe('1px solid rgba(255, 255, 255, 0.06)')
  })

  it('never uses pure black (#000) for text or surfaces', () => {
    const blackHex = /#[0]{3,6}\b/
    expect(blackHex.test(css)).toBe(false)
  })

  it('keeps card brighter than page background in both modes', () => {
    const light = parseBlock('[data-theme="styleseed"]')
    expect(light['--card']).toBe('#FFFFFF')
    expect(light['--surface-page']).toBe('#FAFAFA')

    const dark = parseBlock(/\[data-theme="styleseed"\]\.dark/)
    expect(dark['--card']).toBe('#1E1E1E')
    expect(dark['--surface-page']).toBe('#121212')

    // Hex brightness check: higher numeric value = brighter.
    const darkCard = dark['--card'] ?? ''
    const darkPage = dark['--surface-page'] ?? ''
    const hexValue = (hex: string) => parseInt(hex.replace('#', ''), 16)
    expect(hexValue(darkCard)).toBeGreaterThan(hexValue(darkPage))
  })

  it('keeps later-loading dark v2 token sources out of StyleSeed', () => {
    expect(v2ThemeCss).toContain(':root:not([data-theme="paper"]):not([data-theme="styleseed"])')
    expect(v2ThemeCss).toContain('[data-theme="dark-fantasy"]')
    expect(skinV2Css).toContain(
      '[data-skin="v2"]:not([data-theme="paper"]):not([data-theme="styleseed"])'
    )
    expect(skinV2Css).toContain(
      '[data-skin="v2"][data-volt="blood"]:not([data-theme="paper"]):not([data-theme="styleseed"])'
    )
    expect(skinV2Css).toContain(
      '[data-skin="v2"][data-volt="ice"]:not([data-theme="paper"]):not([data-theme="styleseed"])'
    )
  })
})
