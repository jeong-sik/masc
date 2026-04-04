import { describe, expect, it } from 'vitest'
import { liveStateClass } from './mission-utils'

describe('liveStateClass', () => {
  it('treats paused and blocked keepers as idle-style mission state', () => {
    expect(liveStateClass('paused')).toBe('mission-state-idle')
    expect(liveStateClass('blocked')).toBe('mission-state-idle')
  })
})
