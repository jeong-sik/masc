// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { declarationsForSelector } from './css-test-utils'

const paperCssPath = resolve(__dirname, 'paper-theme.css')
const paperCss = readFileSync(paperCssPath, 'utf-8')
const appShellCssPath = resolve(__dirname, 'app-shell-v2.css')
const appShellCss = readFileSync(appShellCssPath, 'utf-8')

describe('paper-theme.css', () => {
  it('uses cascade layers rather than selector specificity to override v2 defaults', () => {
    expect(appShellCss).toContain('@layer theme-defaults, theme-overrides;')
    expect(paperCss).toContain('[data-theme="paper"] {')
    expect(paperCss).not.toContain('html[data-theme="paper"] {')
  })

  it('keeps the StyleSeed alias bridge centralized in app-shell-v2.css', () => {
    const root = declarationsForSelector(appShellCss, ':root')
    expect(root['--ss-page']).toBe('var(--theme-surface-page)')
    expect(root['--ss-card']).toBe('var(--theme-card)')
    expect(root['--ss-brand']).toBe('var(--theme-brand)')
    expect(root['--background']).toBe('var(--theme-background)')
  })

  it('bridges paper values into migrated shell role tokens', () => {
    const theme = declarationsForSelector(paperCss, '[data-theme="paper"]')
    expect(theme['--theme-surface-page']).toBe('var(--paper)')
    expect(theme['--theme-card']).toBe('var(--paper-2)')
    expect(theme['--theme-brand']).toBe('var(--brass)')
    expect(Object.keys(theme).some((name) => name.startsWith('--ss-'))).toBe(false)
    expect(theme['--color-bg-page']).toBe('var(--paper)')
    expect(theme['--color-fg-primary']).toBe('var(--ink)')
  })

  it('assigns distinct paper colors to operator, keeper, and tool chat surfaces', () => {
    const theme = declarationsForSelector(paperCss, '[data-theme="paper"]')
    expect(theme['--chat-operator-bg']).toBe('var(--brass-fill)')
    expect(theme['--chat-keeper-bg']).toBe('var(--teal-fill)')
    expect(theme['--chat-tool-bg']).toBe('var(--slate-accent-fill)')
    expect(theme['--accent']).toBe('var(--slate-accent)')
  })
})
