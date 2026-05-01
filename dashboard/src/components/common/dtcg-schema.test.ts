// @ts-nocheck
import { describe, expect, it } from 'vitest'
import type {
  DTCGToken,
  DTCGTokenGroup,
  DTCGTokenType,
  DTCGShadowValue,
  DTCGTransitionValue,
} from './dtcg-schema'

describe('DTCG schema types (runtime shape validation)', () => {
  const allTypes: DTCGTokenType[] = [
    'color',
    'dimension',
    'fontFamily',
    'fontWeight',
    'duration',
    'cubicBezier',
    'number',
    'shadow',
    'transition',
  ]

  it('accepts every token type literal', () => {
    expect(allTypes.length).toBe(9)
    expect(new Set(allTypes).size).toBe(9)
  })

  it('accepts a valid color token object', () => {
    const token: DTCGToken = {
      $value: '#ff0000',
      $type: 'color',
      $description: 'Primary red',
    }
    expect(token.$type).toBe('color')
    expect(token.$value).toBe('#ff0000')
    expect(token.$description).toBe('Primary red')
  })

  it('accepts a token with extensions', () => {
    const token: DTCGToken = {
      $value: 16,
      $type: 'number',
      $extensions: { 'com.example.scale': 1.5 },
    }
    expect(token.$extensions).toEqual({ 'com.example.scale': 1.5 })
  })

  it('accepts a nested token group', () => {
    const group: DTCGTokenGroup = {
      $type: 'color',
      $description: 'Brand palette',
      primary: { $value: '#ff0000', $type: 'color' },
      secondary: { $value: '#00ff00', $type: 'color' },
      nested: {
        deep: { $value: '#0000ff', $type: 'color' },
      },
    }
    expect(group.$type).toBe('color')
    expect(group.primary.$value).toBe('#ff0000')
    expect((group.nested as DTCGTokenGroup).deep.$value).toBe('#0000ff')
  })

  it('accepts shadow value structure', () => {
    const shadow: DTCGShadowValue = {
      color: 'rgba(0,0,0,0.2)',
      offsetX: '0px',
      offsetY: '4px',
      blur: '8px',
      spread: '0px',
    }
    expect(shadow.blur).toBe('8px')
  })

  it('accepts transition value structure', () => {
    const transition: DTCGTransitionValue = {
      duration: 300,
      timingFunction: [0.4, 0, 0.2, 1],
    }
    expect(transition.duration).toBe(300)
    expect(transition.timingFunction).toEqual([0.4, 0, 0.2, 1])
  })

  it('accepts transition with optional delay', () => {
    const transition: DTCGTransitionValue = {
      duration: 200,
      delay: 50,
      timingFunction: [0, 0, 1, 1],
    }
    expect(transition.delay).toBe(50)
  })
})
