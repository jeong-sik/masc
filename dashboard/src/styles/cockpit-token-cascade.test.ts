// @ts-nocheck
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const here = dirname(fileURLToPath(import.meta.url))
const variablesCss = readFileSync(join(here, 'variables.css'), 'utf8')
const baseCss = readFileSync(join(here, 'base.css'), 'utf8')
const appTs = readFileSync(join(here, '..', 'app.ts'), 'utf8')

describe('Cockpit token cascade', () => {
  it('bridges legacy dashboard aliases to generated cockpit tokens', () => {
    expect(variablesCss).toContain('--bg-0: var(--color-bg-0);')
    expect(variablesCss).toContain('--text-body: var(--color-fg-2);')
    expect(variablesCss).toContain('--accent: var(--color-brass-1);')
    expect(variablesCss).toContain('--color-accent-fg: var(--brass-1);')

    expect(variablesCss).not.toContain('--bg-0: var(--bg-root);')
    expect(variablesCss).not.toContain('--color-accent-fg: var(--accent);')
  })

  it('keeps the app shell on semantic cockpit backgrounds', () => {
    expect(baseCss).toContain('rgb(var(--brass-glow) / 0.08)')
    expect(baseCss).toContain('linear-gradient(180deg, var(--bg-root-deep) 0%, var(--color-bg-page) 48%, var(--bg-root-dim) 100%)')
    expect(appTs).toContain('bg-[var(--color-bg-page)]')
    expect(appTs).toContain('bg-[var(--shell-header-bg)]')
    expect(appTs).toContain('bg-[var(--shell-rail-bg)]')
    expect(appTs).toContain('bg-[var(--shell-main-bg)]')

    expect(baseCss).not.toContain('rgba(71, 184, 255')
    expect(appTs).not.toContain('rgba(25,40,70')
    expect(appTs).not.toContain('rgba(11,18,32')
    expect(appTs).not.toContain('rgba(8,14,26')
    expect(appTs).not.toContain('rgba(15,22,36')
    expect(appTs).not.toContain('rgba(10,15,26')
  })
})
