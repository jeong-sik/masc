import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'

const css = readFileSync(resolve(__dirname, 'board-v2.css'), 'utf-8')

function mobileBoardDetailDecls(): Record<string, string> {
  const declarations: Record<string, string> = {}

  parse(css).walkAtRules('media', (atRule) => {
    if (!atRule.params.includes('max-width: 900px')) return

    atRule.walkRules((rule) => {
      if (!rule.selectors.includes('.v2-board-surface .bd-detail.has-post')) return
      if (!rule.selectors.includes('.v2-board-surface .bd-detail.is-mentions.is-mobile-open')) return

      rule.walkDecls((decl) => {
        declarations[decl.prop] = decl.value.trim()
      })
    })
  })

  return declarations
}

describe('board-v2.css mobile detail overlay', () => {
  it('reserves mobile shell tab clearance for thread and mention detail panels', () => {
    const declarations = mobileBoardDetailDecls()

    expect(declarations.left).toBe('0')
    expect(declarations.bottom).toBe('calc(46px + env(safe-area-inset-bottom, 0px))')
    expect(declarations.width).toBe('100%')
  })
})
