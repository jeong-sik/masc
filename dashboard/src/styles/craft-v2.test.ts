// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { declarationsForSelector } from './css-test-utils'

const cssPath = resolve(__dirname, 'craft-v2.css')
const css = readFileSync(cssPath, 'utf-8')

describe('craft-v2.css data-bubble=flat toggle', () => {
  it('flattens the live .chat-bubble (not the design-only .bubble)', () => {
    const flat = declarationsForSelector(css, '.v2-app[data-bubble="flat"] .chat-bubble')
    expect(flat.background).toBe('transparent')
    expect(flat['border-color']).toBe('transparent')
    expect(flat['border-radius']).toBe('0')
    expect(flat.padding).toBe('2px 0 0')
  })

  it('keeps the brass user spine on the flat user bubble', () => {
    const flatUser = declarationsForSelector(css, '.v2-app[data-bubble="flat"] .chat-bubble.user')
    expect(flatUser.background).toBe('transparent')
    expect(flatUser['border-left']).toContain('2px solid')
  })

  it('no longer targets the never-rendered .bubble class (regression guard)', () => {
    // The live chat renders `.chat-bubble` (chat/primitives.ts), never bare
    // `.bubble`, so the design-ported `.bubble` selector matched nothing. If it
    // reappears, the toggle is inert again.
    expect(() => declarationsForSelector(css, '.v2-app[data-bubble="flat"] .bubble')).toThrow(
      /Selector not found/,
    )
    expect(() => declarationsForSelector(css, '.v2-app[data-bubble="flat"] .bubble.user')).toThrow(
      /Selector not found/,
    )
  })

  it('has no .v2-keeper-chat phantom-prefix rules (dead chat density removed)', () => {
    // The design scoped chat density under a `.v2-keeper-chat` container the live
    // dashboard never renders, so those ported rules were dead. Strip comments so
    // the tombstone note does not count, then assert no selector reintroduces it.
    const withoutComments = css.replace(/\/\*[\s\S]*?\*\//g, '')
    expect(withoutComments).not.toContain('v2-keeper-chat')
  })
})

describe('craft-v2.css density chat console (retargeted to live classes)', () => {
  it('applies the spacious chat values to the live .kw-*/.chat-* classes', () => {
    expect(declarationsForSelector(css, '.v2-app[data-density="spacious"] .kw-chat-head').padding)
      .toBe('20px 28px 16px')
    expect(declarationsForSelector(
      css,
      '.v2-app[data-density="spacious"] [data-keeper-chat-layout="workspace"] .chat-transcript',
    ).padding)
      .toBe('34px 40px 14px')
    const bubble = declarationsForSelector(
      css,
      '.v2-app[data-density="spacious"] [data-keeper-chat-layout="workspace"] .chat-bubble',
    )
    expect(bubble.padding).toBe('16px 20px')
    expect(bubble['line-height']).toBe('1.7')
    // Ownership contract: outer composer spacing belongs to .kw-composer-wrap
    // alone (keeper-workspace.css). Density rules must NOT re-pad the inner —
    // the removed 16px 30px 24px was the second layer of a 62px bottom gap.
    expect(() => declarationsForSelector(
      css,
      '.v2-app[data-density="spacious"] [data-keeper-chat-layout="workspace"] .kw-composer-inner',
    )).toThrow('Selector not found')
  })

  it('applies the compact chat values to the live .kw-*/.chat-* classes', () => {
    expect(declarationsForSelector(css, '.v2-app[data-density="compact"] .kw-chat-head').padding)
      .toBe('10px 16px 10px')
    expect(declarationsForSelector(
      css,
      '.v2-app[data-density="compact"] [data-keeper-chat-layout="workspace"] .chat-transcript',
    ).padding)
      .toBe('14px 24px 6px')
    expect(() => declarationsForSelector(
      css,
      '.v2-app[data-density="compact"] [data-keeper-chat-layout="workspace"] .kw-composer-inner',
    )).toThrow('Selector not found')
  })

  it('applies context-rail + roster spacious values to live classes', () => {
    const rail = declarationsForSelector(css, '.v2-app[data-density="spacious"] .kw-rail-scroll')
    expect(rail.padding).toBe('20px')
    expect(rail.gap).toBe('24px')
    expect(declarationsForSelector(css, '.v2-app[data-density="spacious"] .kw-rail .kw-sec').padding)
      .toBe('14px 16px')
    expect(declarationsForSelector(css, '.v2-app[data-density="spacious"] .kw-roster-head').padding)
      .toBe('16px 14px')
    expect(declarationsForSelector(css, '.v2-app[data-density="spacious"] .kw-roster-filters').padding)
      .toBe('12px 14px')
    expect(declarationsForSelector(css, '.v2-app[data-density="compact"] .kw-rail-scroll').padding)
      .toBe('12px')
  })

  it('gives the keeper workspace scroll areas the themed webkit scrollbar', () => {
    // The design scoped the scrollbar to `.thread`/`.ctx-scroll`/`.roster-list`;
    // the keeper workspace renders `.kw-thread`/`.kw-rail-scroll`/`.kw-roster-list`,
    // so those need to be in the selector list to get the 10px themed bar.
    expect(declarationsForSelector(css, '.v2-app .kw-thread::-webkit-scrollbar').width).toBe('10px')
    expect(declarationsForSelector(css, '.v2-app .kw-rail-scroll::-webkit-scrollbar').width).toBe('10px')
    expect(declarationsForSelector(css, '.v2-app .kw-roster-list::-webkit-scrollbar').width).toBe('10px')
    expect(declarationsForSelector(css, '.v2-app .kw-thread::-webkit-scrollbar-thumb')['background-clip'])
      .toBe('padding-box')
  })

  it('does not target the design-only .thread / .bubble chat classes (regression guard)', () => {
    // The live keeper workspace renders `.kw-thread` / `.chat-bubble`; the design
    // class names `.thread` / `.bubble` never match, so a density rule on them is dead.
    expect(() => declarationsForSelector(css, '.v2-app[data-density="spacious"] .thread')).toThrow(
      /Selector not found/,
    )
    expect(() => declarationsForSelector(css, '.v2-app[data-density="spacious"] .bubble')).toThrow(
      /Selector not found/,
    )
    expect(() => declarationsForSelector(css, '.v2-app[data-density="spacious"] .chat-bubble')).toThrow(
      /Selector not found/,
    )
  })
})
