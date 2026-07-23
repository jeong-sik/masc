import { describe, expect, it } from 'vitest'

import {
  parsePersonaListResponse,
  PersonaCountMismatchError,
  PersonaSchemaDriftError,
} from './persona'

const detailedPersona = {
  persona_name: 'sonsukku',
  display_name: '손석구',
  role: 'reviewer',
  trait: '집요함',
  profile_path: '/personas/sonsukku/profile.json',
  has_keeper_defaults: true,
}

describe('parsePersonaListResponse', () => {
  it('decodes the detailed backend contract without compatibility aliases', () => {
    expect(parsePersonaListResponse({ count: 1, personas: [detailedPersona] })).toEqual({
      count: 1,
      personas: [detailedPersona],
    })
  })

  it.each([
    { count: 1, personas: ['sonsukku'] },
    { count: 1, personas: [{ ...detailedPersona, persona_name: '' }] },
    { count: 1, personas: [{ ...detailedPersona, has_keeper_defaults: 'yes' }] },
    { count: 0, personas: 'not-an-array' },
  ])('rejects malformed or legacy payloads: %j', payload => {
    expect(() => parsePersonaListResponse(payload)).toThrow(PersonaSchemaDriftError)
  })

  it('rejects a declared count that disagrees with the decoded roster', () => {
    expect(() => parsePersonaListResponse({ count: 2, personas: [detailedPersona] }))
      .toThrow(PersonaCountMismatchError)
  })

  it('distinguishes an empty detailed roster from schema drift', () => {
    expect(parsePersonaListResponse({ count: 0, personas: [] })).toEqual({
      count: 0,
      personas: [],
    })
  })
})
