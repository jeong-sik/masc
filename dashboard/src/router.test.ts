import { describe, it, expect } from 'vitest'
import { navigate, route } from './router'

describe('navigate', () => {
  it('navigates to status tab with agent param', () => {
    navigate('status', { section: 'agents', agent: 'sangsu' })
    expect(route.value.tab).toBe('status')
    expect(route.value.params.section).toBe('agents')
    expect(route.value.params.agent).toBe('sangsu')
  })

  it('navigates to work tab with board section', () => {
    navigate('work', { section: 'board' })
    expect(route.value.tab).toBe('work')
    expect(route.value.params.section).toBe('board')
  })

  it('navigates to home', () => {
    navigate('home')
    expect(route.value.tab).toBe('home')
  })
})
