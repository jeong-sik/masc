import { describe, it, expect, vi } from 'vitest'
import {
  initRouter,
  navigate,
  navigateToPost,
  replaceRoute,
  route,
  hashForRoute,
} from './router'
import {
  DASHBOARD_SECTION_ITEMS,
} from './config/navigation'
import type { NonHomeTabId } from './types'

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

  it('navigates to top-level keepers without monitor section baggage', () => {
    navigate('keepers', { section: 'agents', keeper: 'sangsu' })
    expect(route.value.tab).toBe('keepers')
    expect(route.value.params).toEqual({ keeper: 'sangsu' })
    expect(window.location.hash).toBe('#keepers?keeper=sangsu')
  })

  it('navigates to top-level board without workspace section baggage', () => {
    navigate('board', { section: 'board', post: 'post-1', comment: 'comment-1' })
    expect(route.value.tab).toBe('board')
    expect(route.value.params).toEqual({ post: 'post-1', comment: 'comment-1' })
    expect(window.location.hash).toBe('#board?post=post-1&comment=comment-1')
  })

  it('navigates to top-level schedule without lab section baggage', () => {
    navigate('schedule', { section: 'tools', surface: 'lab', view: 'legacy' })
    expect(route.value.tab).toBe('schedule')
    expect(route.value.params).toEqual({ view: 'legacy' })
    expect(window.location.hash).toBe('#schedule?view=legacy')
  })

  it('navigates to top-level fusion without section baggage', () => {
    navigate('fusion', { section: 'workspace', run_id: 'fus-1', surface: 'old' })
    expect(route.value.tab).toBe('fusion')
    expect(route.value.params).toEqual({ run_id: 'fus-1' })
    expect(window.location.hash).toBe('#fusion?run_id=fus-1')
  })

  it('keeps Settings section hashes routeable without adding sidebar subsections', () => {
    navigate('settings', { section: 'runtimes', surface: 'old' })
    expect(route.value.tab).toBe('settings')
    expect(route.value.params).toEqual({ section: 'runtimes' })
    expect(window.location.hash).toBe('#settings?section=runtimes')

    navigate('settings', { section: 'account' })
    expect(route.value.params).toEqual({ section: 'account' })
    expect(window.location.hash).toBe('#settings?section=account')
  })

  it('keeps workspace board deep links routeable for compatibility', () => {
    navigate('workspace', { section: 'board', post: 'post-1' })
    expect(route.value.tab).toBe('workspace')
    expect(route.value.params).toEqual({ section: 'board', post: 'post-1' })
    expect(window.location.hash).toBe('#workspace?section=board&post=post-1')
  })

  it('opens board posts on the top-level board surface', () => {
    navigateToPost('post 1')
    expect(window.location.hash).toBe('#board?post=post%201')
  })

  it('redirects removed operations params to operations', () => {
    navigate('command', { section: 'operations', surface: 'swarm' })
    expect(route.value.tab).toBe('command')
    expect(route.value.params.section).toBe('operations')
    expect(route.value.params.surface).toBeUndefined()
  })

  it('keeps runtime diagnostic monitor links routeable while hidden from primary IA', () => {
    navigate('monitoring', { section: 'transport-health' })
    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('transport-health')
    expect(window.location.hash).toBe('#monitoring?section=transport-health')
  })

  it('canonicalizes connector route filters', () => {
    navigate('connectors', { section: 'connector-status', connector: 'telegram' })
    expect(route.value.tab).toBe('connectors')
    expect(route.value.params).toEqual({ section: 'connector-status', connector: 'telegram' })
    expect(window.location.hash).toBe('#connectors?section=connector-status&connector=telegram')

    navigate('connectors', { section: 'connector-status', connector: 'bogus' })
    expect(route.value.params).toEqual({ section: 'connector-status' })
    expect(window.location.hash).toBe('#connectors?section=connector-status')
  })

  it('maps cockpit Cognition design deep links into the Monitor agents lane', () => {
    window.location.hash = '#repo=viewer&branch=wt%2Fsangsu-smoke&mode=Cognition'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('agents')
    expect(route.value.params.repo).toBe('viewer')
    expect(route.value.params.branch).toBe('wt/sangsu-smoke')
    expect(route.value.params.mode).toBe('Cognition')
    expect(window.location.hash).toContain('section=agents')
  })

  it('treats slash-bearing raw cockpit query hashes as queries and redirects Cognition to agents', () => {
    window.location.hash = '#repo=viewer&branch=wt/sangsu-smoke&mode=Cognition'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('agents')
    expect(route.value.params.branch).toBe('wt/sangsu-smoke')
    expect(window.location.hash).toContain('section=agents')
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

  it('preserves IDE context surface params on Code routes', () => {
    navigate('code', {
      section: 'ide-shell',
      view: 'source',
      file: 'lib/runtime.ml',
      line: '42',
      surface: 'Task',
      source_id: 'task:runtime',
    })

    expect(route.value.tab).toBe('code')
    expect(route.value.params).toMatchObject({
      section: 'ide-shell',
      view: 'source',
      file: 'lib/runtime.ml',
      line: '42',
      surface: 'Task',
      source_id: 'task:runtime',
    })
    expect(window.location.hash).toContain('surface=Task')
  })

  it('keeps explicit production sections stronger than cockpit mode aliases', () => {
    window.location.hash = '#monitoring?section=runtime&mode=Cognition'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('runtime')
    expect(route.value.params.mode).toBe('Cognition')
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

describe('canonical section routes', () => {
  it('keeps every registered section on its requested surface', () => {
    for (const tab of Object.keys(DASHBOARD_SECTION_ITEMS) as NonHomeTabId[]) {
      for (const item of DASHBOARD_SECTION_ITEMS[tab]) {
        navigate(tab, item.params)
        expect(route.value.tab).toBe(tab)
        expect(route.value.params.section).toBe(item.params.section)
        expect(window.location.hash).toBe(hashForRoute(tab, item.params))
      }
    }
  })

  it('uses the default section for an unknown query or path', () => {
    navigate('monitoring', { section: 'not-a-section', keeper: 'nova' })
    expect(route.value.params).toEqual({ section: 'agents', keeper: 'nova' })

    window.location.hash = '#command/not-a-section?target_id=op-42'
    window.dispatchEvent(new HashChangeEvent('hashchange'))
    expect(route.value.tab).toBe('command')
    expect(route.value.params).toEqual({ section: 'operations', target_id: 'op-42' })
  })
})

// A URL that names a destination must reach it or say it cannot. Landing on
// overview is a silent answer: the person who wrote the link concludes the
// screen does not exist. Observed while looking for the Internal Agents panel,
// which was rendering fine the whole time.
describe('deep links written by hand', () => {
  function bootWith(pathname: string, search: string, hash = ''): void {
    window.history.replaceState(null, '', `${pathname}${search}${hash}`)
    initRouter()
  }

  it('resolves the tab from a query on /dashboard', () => {
    bootWith('/dashboard', '?tab=monitoring&section=internal-agents')
    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('internal-agents')
  })

  // The server answers the dashboard at the root too, so the same link written
  // without /dashboard is the same request.
  it('resolves the tab from a query on the root path', () => {
    bootWith('/', '?tab=monitoring&section=internal-agents')
    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('internal-agents')
  })

  it('still lands on overview when the query names no tab', () => {
    bootWith('/dashboard', '?section=internal-agents')
    expect(route.value.tab).toBe('overview')
  })

  it('keeps the canonical hash form working', () => {
    bootWith('/dashboard', '', '#monitoring?section=internal-agents')
    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('internal-agents')
  })

  it('decodes query values exactly once', () => {
    bootWith(
      '/dashboard',
      '?tab=monitoring&section=agents&keeper=a%2Bb%2520c',
    )
    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.keeper).toBe('a+b%20c')
  })
})
