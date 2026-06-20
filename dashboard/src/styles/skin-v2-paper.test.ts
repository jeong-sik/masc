// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { declarationsForSelector } from './css-test-utils'

const cssPath = resolve(__dirname, 'skin-v2.css')
const css = readFileSync(cssPath, 'utf-8')

describe('skin-v2.css paper bridge', () => {
  it('uses the paper-theme palette instead of the old gray v2 paper spine', () => {
    const theme = declarationsForSelector(css, 'html[data-skin="v2"][data-theme="paper"]')
    expect(theme['--bg-deep']).toBe('var(--paper)')
    expect(theme['--bg-panel']).toBe('var(--paper-2)')
    expect(theme['--border-main']).toBe('var(--border-3-paper)')
    expect(theme['--text-bright']).toBe('var(--ink)')
    expect(theme['--info']).toBe('var(--slate-accent)')
    expect(theme['--volt']).toBe('var(--brass)')
  })
})
