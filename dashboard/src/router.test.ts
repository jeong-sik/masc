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

  it('redirects removed warroom params to intervene', () => {
    navigate('command', { section: 'warroom', surface: 'swarm' })
    expect(route.value.tab).toBe('command')
    expect(route.value.params.section).toBe('intervene')
    expect(route.value.params.surface).toBeUndefined()
  })

  it('keeps governance params on the command surface', () => {
    navigate('command', { section: 'governance' })
    expect(route.value.tab).toBe('command')
    expect(route.value.params.section).toBe('governance')
  })

  it('keeps governance deep links on the command surface', () => {
    window.location.hash = '#command/governance'
    window.dispatchEvent(new HashChangeEvent('hashchange'))
    expect(route.value.tab).toBe('command')
    expect(route.value.params.section).toBe('governance')
  })
})
