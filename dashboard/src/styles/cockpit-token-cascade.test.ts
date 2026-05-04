/// <reference types="node" />

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const here = dirname(fileURLToPath(import.meta.url))
const generatedCss = readFileSync(join(here, 'tokens.generated.css'), 'utf8')
const variablesCss = readFileSync(join(here, 'variables.css'), 'utf8')
const baseCss = readFileSync(join(here, 'base.css'), 'utf8')
const appTs = readFileSync(join(here, '..', 'app.ts'), 'utf8')

function expectDeclaration(css: string, name: string, value: string) {
  expect(css).toMatch(new RegExp(`${name}:\\s*${escapeRegExp(value)}\\s*;`))
}

function expectDeclarationExists(css: string, name: string) {
  expect(css).toMatch(new RegExp(`${escapeRegExp(name)}:\\s*[^;]+;`))
}

function expectNoDeclaration(css: string, name: string, value: string) {
  expect(css).not.toMatch(new RegExp(`${name}:\\s*${escapeRegExp(value)}\\s*;`))
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

describe('Cockpit token cascade', () => {
  it('emits runtime aliases for Tailwind-prefixed component color slots', () => {
    expectDeclarationExists(generatedCss, '--color-button-primary-bg')
    expectDeclaration(generatedCss, '--button-primary-bg', 'var(--color-button-primary-bg)')
    expectDeclarationExists(generatedCss, '--color-input-bg')
    expectDeclaration(generatedCss, '--input-bg', 'var(--color-input-bg)')
    expectDeclarationExists(generatedCss, '--color-dialog-panel-bg')
    expectDeclaration(generatedCss, '--dialog-panel-bg', 'var(--color-dialog-panel-bg)')
    expectDeclarationExists(generatedCss, '--color-state-idle')
    expectDeclaration(generatedCss, '--state-idle', 'var(--color-state-idle)')
  })

  it('does not emit raw aliases for palette color tokens', () => {
    expectDeclarationExists(generatedCss, '--color-bg-0')
    expectDeclarationExists(generatedCss, '--color-ok')
    expectNoDeclaration(generatedCss, '--bg-0', 'var(--color-bg-0)')
    expectNoDeclaration(generatedCss, '--ok', 'var(--color-ok)')
  })

  it('bridges legacy dashboard aliases to generated cockpit tokens', () => {
    expectDeclaration(variablesCss, '--bg-0', 'var(--color-bg-0)')
    expectDeclaration(variablesCss, '--text-body', 'var(--color-fg-2)')
    expectDeclaration(variablesCss, '--accent', 'var(--color-brass-1)')
    expectDeclaration(variablesCss, '--color-accent-fg', 'var(--brass-1)')

    expectNoDeclaration(variablesCss, '--bg-0', 'var(--bg-root)')
    expectNoDeclaration(variablesCss, '--color-accent-fg', 'var(--accent)')
  })

  it('keeps the app shell on semantic cockpit backgrounds', () => {
    expect(baseCss).toContain('rgb(var(--brass-glow) / 0.05)')
    expect(baseCss).toContain('var(--color-bg-page)')
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
