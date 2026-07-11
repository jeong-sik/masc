import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'
import { declarationsForSelector } from './css-test-utils'

const cssPath = resolve(__dirname, 'keeper-workspace.css')
const css = readFileSync(cssPath, 'utf-8')

function baseDeclarationsForSelector(selector: string): Record<string, string> {
  const declarations: Record<string, string> = {}
  let found = false

  parse(css).walkRules((rule) => {
    if (rule.parent?.type === 'atrule') return
    if (!rule.selectors.includes(selector)) return
    found = true
    rule.walkDecls((decl) => {
      declarations[decl.prop] = decl.value.trim()
    })
  })

  if (!found) throw new Error(`Selector not found: ${selector}`)
  return declarations
}

describe('keeper-workspace v2.3 fleet surface CSS', () => {
  it('keeps new roster text surfaces from overflowing the row', () => {
    const gloss = declarationsForSelector(css, '.kw-kp-gloss')
    expect(gloss.overflow).toBe('hidden')
    expect(gloss['text-overflow']).toBe('ellipsis')
    expect(gloss['white-space']).toBe('nowrap')

    const rightRail = declarationsForSelector(css, '.kw-kp-right')
    expect(rightRail['padding-right']).toBeUndefined()
    expect(rightRail['align-items']).toBe('flex-end')
  })

  it('keeps roster rows to one hover/focus command target', () => {
    const menuButton = baseDeclarationsForSelector('.kw-kp-more')
    const hoverButton = baseDeclarationsForSelector('.kw-kp-row:hover .kw-kp-more')
    const focusButton = baseDeclarationsForSelector('.kw-kp-row:focus-within .kw-kp-more')

    expect(menuButton.position).toBe('absolute')
    expect(menuButton.opacity).toBe('0')
    expect(menuButton.width).toBe('26px')
    expect(hoverButton.opacity).toBe('1')
    expect(focusButton.opacity).toBe('1')
    expect(css).not.toContain('.kw-kp-chat')
    expect(css).not.toContain('.kw-kp-inline-actions')
    expect(css).not.toContain('.kw-kp-inline-action')
    expect(css).not.toContain('.kw-fleet-chat')
  })

  it('keeps selected runtime details ellipsized inside the rail card', () => {
    const titleText = declarationsForSelector(css, '.kw-fleet-aside-title strong')
    expect(titleText.overflow).toBe('hidden')
    expect(titleText['text-overflow']).toBe('ellipsis')
    expect(titleText['white-space']).toBe('nowrap')

    const vitalValue = declarationsForSelector(css, '.kw-fleet-vitals b')
    expect(vitalValue.overflow).toBe('hidden')
    expect(vitalValue['text-overflow']).toBe('ellipsis')
    expect(vitalValue['white-space']).toBe('nowrap')

    const toolPill = declarationsForSelector(css, '.kw-fleet-tools span')
    expect(toolPill.overflow).toBe('hidden')
    expect(toolPill['text-overflow']).toBe('ellipsis')
    expect(toolPill['white-space']).toBe('nowrap')
  })

  it('visibly guards fleet lifecycle actions while they are in flight', () => {
    const railDisabled = declarationsForSelector(css, '.kw-fleet-action:disabled')
    expect(railDisabled.cursor).toBe('wait')
    expect(railDisabled.opacity).toBe('0.68')

    const railBusy = declarationsForSelector(css, '.kw-fleet-action.busy')
    expect(railBusy['border-color']).toContain('34, 211, 238')
    expect(railBusy.color).toBe('#cffafe')
  })
})
