import { describe, it, expect, vi } from 'vitest'
import { navigate, replaceRoute, route } from './router'

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

  it('redirects retired activity links to observatory on the monitoring surface', () => {
    navigate('monitoring', { section: 'activity', ag_range: '24h' })
    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('observatory')
    expect(route.value.params.range).toBe('24h')
    expect(route.value.params.ag_range).toBeUndefined()
  })

  it('redirects retired Git graph links into the repository graph view', () => {
    navigate('monitoring', { section: 'git-graph' })
    expect(route.value.tab).toBe('workspace')
    expect(route.value.params.section).toBe('repositories')
    expect(route.value.params.view).toBe('graph')
  })

  it('redirects retired safe-autonomy links into operations safety', () => {
    navigate('monitoring', { section: 'safe-autonomy' })
    expect(route.value.tab).toBe('command')
    expect(route.value.params.section).toBe('operations')
    expect(route.value.params.view).toBe('safety')
  })
  it('maps cockpit Cognition design deep links into the production keeper surface', () => {
    window.location.hash = '#repo=viewer&branch=wt%2Fsangsu-smoke&mode=Cognition'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('cognition')
    expect(route.value.params.repo).toBe('viewer')
    expect(route.value.params.branch).toBe('wt/sangsu-smoke')
    expect(route.value.params.mode).toBe('Cognition')
    expect(window.location.hash).toContain('#monitoring?')
  })

  it('treats slash-bearing raw cockpit query hashes as queries', () => {
    window.location.hash = '#repo=viewer&branch=wt/sangsu-smoke&mode=Cognition'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('cognition')
    expect(route.value.params.branch).toBe('wt/sangsu-smoke')
  })

  it('maps cockpit IDE split mode links into the Code IDE view state', () => {
    window.location.hash = '#mode=Split&branch=main'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('code')
    expect(route.value.params.section).toBe('ide-shell')
    expect(route.value.params.view).toBe('split-diff')
    expect(route.value.params.branch).toBe('main')
  })

  it('maps path-qualified cockpit mode links when no explicit section is present', () => {
    window.location.hash = '#code?mode=Split&branch=main'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('code')
    expect(route.value.params.section).toBe('ide-shell')
    expect(route.value.params.view).toBe('split-diff')
    expect(route.value.params.branch).toBe('main')
  })

  it('keeps explicit production sections stronger than cockpit mode aliases', () => {
    window.location.hash = '#monitoring?section=runtime&mode=Cognition'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('runtime')
    expect(route.value.params.mode).toBe('Cognition')
  })

  it('maps cockpit cognition subtabs to explicit cognition views', () => {
    window.location.hash = '#mode=Cognition&tab=dc-str'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('cognition')
    expect(route.value.params.view).toBe('decisions')
    expect(window.location.hash).toContain('view=decisions')
  })

  it('maps observe safe-auto subtabs across surfaces without dropping context', () => {
    window.location.hash = '#repo=viewer&mode=Observe&tab=sa-dash'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('command')
    expect(route.value.params.section).toBe('operations')
    expect(route.value.params.view).toBe('safety')
    expect(route.value.params.repo).toBe('viewer')
  })

  it('replaceRoute writes a canonical hash while preserving the current search params', () => {
    window.history.replaceState(null, '', '/dashboard?theme=paper#overview')
    replaceRoute('workspace', { section: 'planning', view: 'default' })

    expect(route.value.tab).toBe('workspace')
    expect(route.value.params.section).toBe('planning')
    expect(route.value.params.view).toBe('default')
    expect(window.location.search).toBe('?theme=paper')
    expect(window.location.hash).toBe('#workspace?section=planning&view=default')
  })

  it('replaceRoute dispatches hashchange for existing listeners', () => {
    const onHashChange = vi.fn()
    window.addEventListener('hashchange', onHashChange)
    try {
      replaceRoute('monitoring', { section: 'fleet-health', view: 'tool-quality' })
      expect(onHashChange).toHaveBeenCalledTimes(1)
    } finally {
      window.removeEventListener('hashchange', onHashChange)
    }
  })
})
