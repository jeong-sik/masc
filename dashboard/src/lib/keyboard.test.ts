import { describe, expect, it } from 'vitest'
import { isSubmitEnter } from './keyboard'

describe('isSubmitEnter', () => {
  it('accepts a plain Enter keydown', () => {
    const event = new KeyboardEvent('keydown', { key: 'Enter' })
    expect(isSubmitEnter(event)).toBe(true)
  })

  it('rejects non-Enter keys', () => {
    const event = new KeyboardEvent('keydown', { key: 'a' })
    expect(isSubmitEnter(event)).toBe(false)
  })

  it('rejects Enter fired during IME composition (isComposing)', () => {
    const event = new KeyboardEvent('keydown', { key: 'Enter', isComposing: true })
    expect(isSubmitEnter(event)).toBe(false)
  })

  it('rejects Enter reported via legacy keyCode 229', () => {
    const event = new KeyboardEvent('keydown', { key: 'Enter' })
    Object.defineProperty(event, 'keyCode', { get: () => 229 })
    expect(isSubmitEnter(event)).toBe(false)
  })

  it('keeps Shift+Enter decisions at the call site', () => {
    const event = new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true })
    expect(isSubmitEnter(event)).toBe(true)
  })
})
