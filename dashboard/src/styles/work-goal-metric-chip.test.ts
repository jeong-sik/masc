import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { parse, Rule } from 'postcss'
import { describe, expect, it } from 'vitest'

// `declarationsForSelector` merges every matching rule, media blocks included,
// so the mobile override wins and the desktop values are invisible to it. The
// bound this file guards lives outside the media query, so it reads top-level
// rules only.
function baseDeclarations(css: string, selector: string): Record<string, string> {
  const declarations: Record<string, string> = {}
  let found = false

  parse(css).each((node) => {
    if (node.type !== 'rule') return
    const rule = node as Rule
    if (!rule.selectors.includes(selector)) return
    found = true
    rule.walkDecls((decl) => {
      declarations[decl.prop] = decl.value.trim()
    })
  })

  if (!found) throw new Error(`Top-level rule not found: ${selector}`)
  return declarations
}

const workCss = readFileSync(join(__dirname, 'work-v2.css'), 'utf8')

describe('goal card metric chip', () => {
  // The chip prints the goal's declared metric and its target value. Neither is
  // bounded anywhere: on the live workspace the longest metric is 292
  // characters of prose (380 with its target), against a median of 35. The chip
  // sits on the card header row next to the progress bar with `flex: none`, so
  // an unbounded one stretched that row past every sibling card.
  it('clips the metric chip instead of stretching the goal card header', () => {
    const chip = baseDeclarations(workCss, '.wk-metric')

    expect(chip['max-width']).toBe('34ch')
    expect(chip['overflow']).toBe('hidden')
    expect(chip['text-overflow']).toBe('ellipsis')
    expect(chip['white-space']).toBe('nowrap')
  })

  // Clipping is only honest if the whole value stays reachable. work.ts puts it
  // on the element's `title`; at mobile width the chip wraps instead of
  // clipping, which mobile-touch-targets.test.ts pins.
  it('lets the chip wrap rather than clip at mobile width', () => {
    let mobileRule: Record<string, string> | null = null

    parse(workCss).walkAtRules('media', (atRule) => {
      atRule.walkRules((rule) => {
        if (!rule.selectors.includes('.wk-metric')) return
        const declarations: Record<string, string> = {}
        rule.walkDecls((decl) => {
          declarations[decl.prop] = decl.value.trim()
        })
        mobileRule = declarations
      })
    })

    expect(mobileRule).not.toBeNull()
    expect(mobileRule!['white-space']).toBe('normal')
    expect(mobileRule!['max-width']).toBe('100%')
  })
})
