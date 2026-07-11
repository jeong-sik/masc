import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'
import { describe, expect, it } from 'vitest'
import { DEFAULT_MOBILE_BREAKPOINT } from '../hooks/use-is-mobile'

const css = readFileSync(resolve(__dirname, 'ide-v2.css'), 'utf-8')
const MOBILE_SHELL = '.ide-plane-shell[data-mobile-viewport="true"]'
const DESKTOP_SHELL = '.ide-plane-shell[data-mobile-viewport="false"]'

function declarations(selector: string): Record<string, string> {
  const declarations: Record<string, string> = {}
  parse(css).walkRules(rule => {
    if (!rule.selectors.includes(selector)) return
    rule.walkDecls(declaration => {
      declarations[declaration.prop] = declaration.value.trim()
    })
  })
  return declarations
}

function mediaDeclarations(selector: string, maxWidth: string): Record<string, string> {
  const declarations: Record<string, string> = {}
  parse(css).walkAtRules('media', atRule => {
    if (!atRule.params.includes(`max-width: ${maxWidth}`)) return
    atRule.walkRules(rule => {
      if (!rule.selectors.includes(selector)) return
      rule.walkDecls(declaration => {
        declarations[declaration.prop] = declaration.value.trim()
      })
    })
  })
  return declarations
}

describe('keeper-v2 IDE responsive contract', () => {
  it('drops the tree before mobile so the editor keeps a usable width', () => {
    expect(mediaDeclarations(
      `${DESKTOP_SHELL}[data-rails-collapsed="false"] .ide-v2-body.ide-plane-grid`,
      '1180px',
    )['grid-template-columns']).toBe('minmax(0, 1fr) minmax(270px, 320px)')
    expect(mediaDeclarations(`${DESKTOP_SHELL} .ide-v2-tree`, '1180px').display).toBe('none')
    expect(mediaDeclarations(`${DESKTOP_SHELL} .ide-v2-tree-toggle`, '1180px').display).toBe('none')
  })

  it('uses the typed viewport state instead of a second CSS breakpoint SSOT', () => {
    expect(css).not.toContain(`max-width: ${DEFAULT_MOBILE_BREAKPOINT}px`)
    expect(declarations(`${MOBILE_SHELL} .ide-v2-body.ide-plane-grid`)['grid-template-columns'])
      .toBe('minmax(0, 1fr)')
  })

  it('keeps annotation creation available when the right rail is not mounted', () => {
    expect(declarations(`${MOBILE_SHELL} .ide-v2-responsive-annotation-composer`).display)
      .toBe('block')
  })

  it('hides controls for panes that mobile layout cannot render', () => {
    expect(declarations(`${MOBILE_SHELL} .ide-v2-tree-toggle`).display).toBe('none')
    expect(declarations(`${MOBILE_SHELL} .ide-v2-rail-toggle`).display).toBe('none')
  })

  it('keeps the advanced toolbar popover inside the mobile viewport', () => {
    const popover = declarations(`${MOBILE_SHELL} .ide-toolbar-advanced-popover`)
    expect(popover.position).toBe('fixed')
    expect(popover.left).toBe('12px')
    expect(popover.right).toBe('12px')
    expect(popover.width).toBe('auto')
  })
})
