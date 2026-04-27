import { describe, it, expect } from 'vitest'
import {
  focusable,
  FOCUSABLE_CLASS,
  FOCUSABLE_ERR_CLASS,
} from './focusable'

describe('focusable constants', () => {
  it('FOCUSABLE_CLASS is the bare SPEC class', () => {
    expect(FOCUSABLE_CLASS).toBe('focusable')
  })

  it('FOCUSABLE_ERR_CLASS chains the SPEC `.is-err` modifier', () => {
    expect(FOCUSABLE_ERR_CLASS).toBe('focusable is-err')
  })
})

describe('focusable()', () => {
  it('returns the bare class when called with no arg', () => {
    expect(focusable()).toBe('focusable')
  })

  it('returns the bare class for an empty option bag', () => {
    expect(focusable({})).toBe('focusable')
  })

  it('returns the bare class when err is undefined', () => {
    expect(focusable({ err: undefined })).toBe('focusable')
  })

  it('returns the bare class when err is explicit false', () => {
    expect(focusable({ err: false })).toBe('focusable')
  })

  it('chains is-err only when err is explicit true', () => {
    expect(focusable({ err: true })).toBe('focusable is-err')
  })

  it('result is a stable literal — repeated calls return identical strings', () => {
    expect(focusable()).toBe(focusable())
    expect(focusable({ err: true })).toBe(focusable({ err: true }))
  })

  // Concatenation pattern that callers will use — verifies the
  // returned fragment composes cleanly with arbitrary leading classes
  // (no leading/trailing whitespace, no double spaces).
  it('composes with leading classes via template literal', () => {
    const composed = `btn primary ${focusable()}`
    expect(composed).toBe('btn primary focusable')
  })

  it('composes the err variant the same way', () => {
    const composed = `input mono ${focusable({ err: true })}`
    expect(composed).toBe('input mono focusable is-err')
  })
})
