import { describe, expect, it } from 'vitest'

import { firstNonEmptyString } from './format-string'

describe('firstNonEmptyString', () => {
  it('returns the first trimmed non-empty string', () => {
    expect(firstNonEmptyString(null, '  ', ' hello ', 'world')).toBe('hello')
  })

  it('returns null when all values are empty', () => {
    expect(firstNonEmptyString(null, undefined, '  ')).toBeNull()
  })
})
