import { describe, expect, it } from 'vitest'
import { formatUnixTs } from './types'

describe('formatUnixTs', () => {
  it("writes the stamp on the viewer's own clock", () => {
    // Built from local parts, so the expectation holds in any time zone.
    const local = new Date(2026, 10, 27, 13, 2, 3)
    expect(formatUnixTs(local.getTime() / 1000)).toBe('11-27 13:02:03')
  })

  it('pads single-digit parts', () => {
    const local = new Date(2026, 0, 5, 4, 7, 9)
    expect(formatUnixTs(local.getTime() / 1000)).toBe('01-05 04:07:09')
  })

  it.each([null, undefined, 0, -1, Number.NaN])('has no stamp for %s', (value) => {
    expect(formatUnixTs(value)).toBe('없음')
  })
})
