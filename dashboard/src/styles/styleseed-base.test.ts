// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const cssPath = resolve(__dirname, 'styleseed-base.css')
const css = readFileSync(cssPath, 'utf-8')

describe('styleseed-base.css', () => {
  it('registers StyleSeed semantic tokens in @theme', () => {
    expect(css).toContain('@theme {')
    expect(css).toMatch(/--color-surface-page:\s*var\(--surface-page\b/)
    expect(css).toMatch(/--color-card:\s*var\(--card\b/)
    expect(css).toMatch(/--color-text-primary:\s*var\(--text-primary\b/)
    expect(css).toMatch(/--color-text-secondary:\s*var\(--text-secondary\b/)
    expect(css).toMatch(/--color-text-tertiary:\s*var\(--text-tertiary\b/)
    expect(css).toMatch(/--color-border:\s*var\(--border\b/)
    expect(css).toMatch(/--shadow-card:\s*var\(--shadow-card\b/)
    expect(css).not.toContain('--radius: var(--radius)')
  })

  it('declares an .ss-surface page wrapper', () => {
    expect(css).toContain('.ss-surface')
    expect(css).toContain('background-color: var(--surface-page)')
    expect(css).toContain('color: var(--text-primary)')
  })

  it('declares an .ss-card component class scoped to StyleSeed theme', () => {
    expect(css).toContain('[data-theme="styleseed"] .ss-card')
    expect(css).toContain('background-color: var(--card)')
    expect(css).toContain('border-radius: 1rem')
    expect(css).toContain('box-shadow: var(--shadow-card)')
  })
})
