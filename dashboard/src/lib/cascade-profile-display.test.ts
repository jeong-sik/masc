import { describe, expect, it } from 'vitest'

import {
  cascadeProfileDescription,
  cascadeProfileDisplay,
  cascadeProfileLabel,
  cascadeProfileOptionLabel,
  cascadeProfileSearchText,
} from './cascade-profile-display'

describe('cascade-profile-display', () => {
  it('maps keeper_unified to a friendly balanced label', () => {
    expect(cascadeProfileDisplay('keeper_unified')).toEqual({
      label: 'Balanced',
      description: '기본 멀티-CLI 균형형. 대부분 keeper용.',
    })
  })

  it('builds option labels that preserve the internal id', () => {
    expect(cascadeProfileOptionLabel('tool_use_strict')).toBe('Tool Required (tool_use_strict)')
  })

  it('falls back to the raw name for unknown profiles', () => {
    expect(cascadeProfileLabel('custom_live')).toBe('custom_live')
    expect(cascadeProfileDescription('custom_live')).toBe('Custom/internal cascade profile.')
  })

  it('includes raw id and friendly text in search text', () => {
    const text = cascadeProfileSearchText('resilient_breaker')
    expect(text).toContain('resilient_breaker')
    expect(text).toContain('resilient')
  })
})
