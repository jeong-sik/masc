import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'

// Regression: grouping assignments under `.rt-assign-group-h` header divs broke
// `.rt-assign:first-of-type` -- both the header and each row render as <div>, so the
// header occupies the "first div sibling" slot and no `.rt-assign` row ever matches
// :first-of-type. The first row of every group kept its top border. Fixed by keying
// the border off the adjacent-sibling combinator, which does not care what (if
// anything) precedes the first `.rt-assign` in a group.
const runtimeCss = readFileSync(resolve(__dirname, 'runtime.css'), 'utf-8')

describe('runtime.assignments row border (grouped layout)', () => {
  it('does not gate the row border on :first-of-type', () => {
    const offenders: string[] = []
    parse(runtimeCss).walkRules((rule) => {
      if (rule.selectors.some(s => s.includes('.rt-assign') && s.includes(':first-of-type'))) {
        offenders.push(rule.selector)
      }
    })
    expect(offenders).toEqual([])
  })

  it('applies border-top only to a .rt-assign preceded by another .rt-assign', () => {
    let sawAdjacentBorder = false
    let baseHasBorder = false
    parse(runtimeCss).walkRules((rule) => {
      if (rule.selectors.includes('.rt-assign + .rt-assign')) {
        rule.walkDecls('border-top', () => { sawAdjacentBorder = true })
      }
      if (rule.selectors.includes('.rt-assign')) {
        rule.walkDecls('border-top', () => { baseHasBorder = true })
      }
    })
    expect(sawAdjacentBorder).toBe(true)
    expect(baseHasBorder).toBe(false)
  })
})
