import { describe, it, expect } from 'vitest'
import { navigate, route } from './router'

describe('navigate', () => {
  it('navigates to monitoring tab with agent param', () => {
    navigate('monitoring', { section: 'agents', agent: 'sangsu' })
    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('agents')
    expect(route.value.params.agent).toBe('sangsu')
  })

  it('navigates to workspace tab with board section', () => {
    navigate('workspace', { section: 'board' })
    expect(route.value.tab).toBe('workspace')
    expect(route.value.params.section).toBe('board')
  })

  it('redirects removed warroom params to operations', () => {
    navigate('command', { section: 'warroom', surface: 'swarm' })
    expect(route.value.tab).toBe('command')
    expect(route.value.params.section).toBe('operations')
    expect(route.value.params.surface).toBeUndefined()
  })

  it('redirects governance to operations on the command surface (Phase 1)', () => {
    navigate('command', { section: 'governance' })
    expect(route.value.tab).toBe('command')
    expect(route.value.params.section).toBe('operations')
  })

  it('redirects governance deep links to operations on the command surface', () => {
    window.location.hash = '#command/governance'
    window.dispatchEvent(new HashChangeEvent('hashchange'))
    expect(route.value.tab).toBe('command')
    expect(route.value.params.section).toBe('operations')
  })
})
