import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { declarationsForSelector } from './css-test-utils'

const cssPath = resolve(__dirname, 'keeper-workspace.css')
const css = readFileSync(cssPath, 'utf-8')

describe('keeper-workspace v2.3 fleet surface CSS', () => {
  it('keeps new roster text surfaces from overflowing the row', () => {
    const gloss = declarationsForSelector(css, '.kw-kp-gloss')
    expect(gloss.overflow).toBe('hidden')
    expect(gloss['text-overflow']).toBe('ellipsis')
    expect(gloss['white-space']).toBe('nowrap')

    const inlineActionLabel = declarationsForSelector(css, '.kw-kp-inline-action span')
    expect(inlineActionLabel.overflow).toBe('hidden')
    expect(inlineActionLabel['text-overflow']).toBe('ellipsis')
    expect(inlineActionLabel['white-space']).toBe('nowrap')
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
    const inlineBusy = declarationsForSelector(css, '.kw-kp-inline-action.busy')
    expect(inlineBusy['border-color']).toContain('34, 211, 238')
    expect(inlineBusy.color).toBe('#cffafe')

    const railDisabled = declarationsForSelector(css, '.kw-fleet-action:disabled')
    expect(railDisabled.cursor).toBe('wait')
    expect(railDisabled.opacity).toBe('0.68')
  })
})
