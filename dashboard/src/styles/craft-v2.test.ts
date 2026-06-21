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
      .toBe('18px 28px 16px')
    expect(declarationsForSelector(css, '.v2-app[data-density="spacious"] .chat-transcript').padding)
      .toBe('34px 40px 14px')
    const bubble = declarationsForSelector(css, '.v2-app[data-density="spacious"] .chat-bubble')
    expect(bubble.padding).toBe('17px 21px')
    expect(bubble['line-height']).toBe('1.7')
    expect(declarationsForSelector(css, '.v2-app[data-density="spacious"] .kw-composer-inner').padding)
      .toBe('16px 30px 22px')
  })

  it('applies the compact chat values to the live .kw-*/.chat-* classes', () => {
    expect(declarationsForSelector(css, '.v2-app[data-density="compact"] .kw-chat-head').padding)
      .toBe('10px 16px 9px')
    expect(declarationsForSelector(css, '.v2-app[data-density="compact"] .chat-transcript').padding)
      .toBe('14px 22px 6px')
    expect(declarationsForSelector(css, '.v2-app[data-density="compact"] .kw-composer-inner').padding)
      .toBe('9px 18px 12px')
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
  })
})
