import { describe, expect, it } from 'vitest'
import { assertExhaustive } from './exhaustive'

describe('assertExhaustive', () => {
  it('throws with the supplied context when called at runtime', () => {
    // `as never` is only required because this test is intentionally
    // bypassing the compile-time guarantee in order to exercise the
    // runtime fallback. Real callers reach this line only via an
    // upstream type-erasure bug.
    expect(() => assertExhaustive('rogue-value' as never, 'TestUnion')).toThrow(
      /assertExhaustive: unexpected TestUnion value: rogue-value/,
    )
  })

  it('stringifies non-string values safely', () => {
    expect(() => assertExhaustive(42 as never, 'NumUnion')).toThrow(
      /assertExhaustive: unexpected NumUnion value: 42/,
    )
    expect(() => assertExhaustive(null as never, 'NullableUnion')).toThrow(
      /assertExhaustive: unexpected NullableUnion value: null/,
    )
  })
})
