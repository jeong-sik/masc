import { describe, it, expect, vi } from 'vitest'
import {
  navigate,
  navigateToPost,
  replaceRoute,
  route,
  hashForRoute,
  REDIRECTED_FROM_PARAM,
  CROSS_SURFACE_SECTION_REDIRECTS,
} from './router'
import {
  DASHBOARD_SECTION_ITEMS,
  SECTION_REDIRECTS,
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

  it('redirects the Gate section to the Gate operations view', () => {
    navigate('command', { section: 'gate' })
    expect(route.value.tab).toBe('command')
    expect(route.value.params.section).toBe('operations')
    expect(route.value.params.view).toBe('gate')
  })

  it('redirects Gate deep links to the Gate operations view', () => {
    window.location.hash = '#command/gate'
    window.dispatchEvent(new HashChangeEvent('hashchange'))
    expect(route.value.tab).toBe('command')
    expect(route.value.params.section).toBe('operations')
    expect(route.value.params.view).toBe('gate')
  })

  it('falls back invalid activity section to default agents section', () => {
    navigate('monitoring', { section: 'activity', ag_range: '24h' })
    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('agents')
    expect(route.value.params.range).toBe('24h')
    expect(route.value.params.ag_range).toBeUndefined()
  })

  it('keeps runtime diagnostic monitor links routeable while hidden from primary IA', () => {
    navigate('monitoring', { section: 'transport-health' })
    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('transport-health')
    expect(window.location.hash).toBe('#monitoring?section=transport-health')

    navigate('monitoring', { section: 'feature-health' })
    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('feature-health')
    expect(window.location.hash).toBe('#monitoring?section=feature-health')
  })

  it('redirects retired Git graph links into the repository graph view', () => {
    navigate('monitoring', { section: 'git-graph' })
    expect(route.value.tab).toBe('workspace')
    expect(route.value.params.section).toBe('repositories')
    expect(route.value.params.view).toBeUndefined()
  })

  it('redirects retired command connectors links directly to the connectors surface', () => {
    navigate('command', { section: 'connectors' })
    expect(route.value.tab).toBe('connectors')
    expect(route.value.params.section).toBe('connector-status')
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

  it('redirects retired command connectors path links without an operations null hop', () => {
    window.location.hash = '#command/connectors'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('connectors')
    expect(route.value.params.section).toBe('connector-status')
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

  it('does not map retired cockpit cognition subtabs to legacy views', () => {
    window.location.hash = '#mode=Cognition&tab=dc-str'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('agents')
    expect(route.value.params.view).toBeUndefined()
    expect(route.value.params.tab).toBe('dc-str')
    expect(window.location.hash).toContain('section=agents')
    expect(window.location.hash).toContain('tab=dc-str')
  })

  it('does not map retired observe safe-auto subtabs across surfaces', () => {
    window.location.hash = '#repo=viewer&mode=Observe&tab=sa-dash'
    window.dispatchEvent(new HashChangeEvent('hashchange'))

    expect(route.value.tab).toBe('monitoring')
    expect(route.value.params.section).toBe('runtime')
    expect(route.value.params.view).toBeUndefined()
    expect(route.value.params.repo).toBe('viewer')
    expect(route.value.params.mode).toBe('Observe')
    expect(route.value.params.tab).toBe('sa-dash')
  })

  it.each(['ct-agt', 'ct-mtx', 'ct-lat'])(
    'does not map retired observe cost subtab %s to cost focus',
    tab => {
      window.location.hash = `#repo=viewer&mode=Observe&tab=${tab}&q=latency`
      window.dispatchEvent(new HashChangeEvent('hashchange'))

      expect(route.value.tab).toBe('monitoring')
      expect(route.value.params.section).toBe('runtime')
      expect(route.value.params.view).toBeUndefined()
      expect(route.value.params.focus).toBeUndefined()
      expect(route.value.params.repo).toBe('viewer')
      expect(route.value.params.mode).toBe('Observe')
      expect(route.value.params.tab).toBe(tab)
      expect(route.value.params.q).toBe('latency')
      expect(window.location.hash).toContain(`tab=${tab}`)
    },
  )

  it('replaceRoute writes a canonical hash while preserving the current search params', () => {
    window.history.replaceState(null, '', '/dashboard?theme=paper#overview')
    replaceRoute('workspace', { section: 'planning', view: 'default' })

    expect(route.value.tab).toBe('workspace')
    expect(route.value.params.section).toBe('planning')
    expect(route.value.params.view).toBeUndefined()
    expect(window.location.search).toBe('?theme=paper')
    expect(window.location.hash).toBe('#workspace?section=planning')
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

describe('REDIRECTED_FROM_PARAM (RFC-0049)', () => {
  it('records the original surface:section when a redirect resolves', () => {
    navigate('monitoring', { section: 'git-graph' })
    expect(route.value.tab).toBe('workspace')
    expect(route.value.params.section).toBe('repositories')
    expect(route.value.params[REDIRECTED_FROM_PARAM]).toBe('monitoring:git-graph')
  })

  it('omits the param entirely on direct (non-redirected) navigation', () => {
    navigate('lab', { section: 'tools' })
    expect(route.value.params[REDIRECTED_FROM_PARAM]).toBeUndefined()
  })

  it('never leaks the internal param into the URL hash', () => {
    navigate('monitoring', { section: 'git-graph' })
    expect(window.location.hash).not.toContain(REDIRECTED_FROM_PARAM)
    expect(window.location.hash).not.toContain('__redirected_from')
  })

  it('hashForRoute strips the internal param even if callers pass it', () => {
    const hash = hashForRoute('workspace', {
      section: 'repositories',
      [REDIRECTED_FROM_PARAM]: 'monitoring:git-graph',
    })
    expect(hash).not.toContain(REDIRECTED_FROM_PARAM)
    expect(hash).not.toContain('__redirected_from')
  })
})

// --- RFC-0048 PR-A — redirect-ledger contract -----------------------------
//
// Every section ID ever shown in the sidebar (including ones now hidden,
// removed, or reachable only via redirect) must resolve to a (tab, section)
// pair currently registered in DASHBOARD_SECTION_ITEMS. Without this gate,
// silently deleting a section breaks operator bookmarks and external
// links — RFC-0048 §4.3.

function registeredSections(tab: NonHomeTabId): Set<string> {
  return new Set(
    DASHBOARD_SECTION_ITEMS[tab].map(item => item.params.section ?? ''),
  )
}

interface RedirectSource {
  fromTab: string
  fromSection: string
  description: string
}

function enumerateRedirectSources(): RedirectSource[] {
  const sources: RedirectSource[] = []
  for (const key of Object.keys(SECTION_REDIRECTS)) {
    const [fromTab, fromSection] = key.split(':') as [string, string]
    sources.push({ fromTab, fromSection, description: `SECTION_REDIRECTS[${key}]` })
  }
  for (const key of Object.keys(CROSS_SURFACE_SECTION_REDIRECTS)) {
    const [fromTab, fromSection] = key.split(':') as [string, string]
    sources.push({
      fromTab,
      fromSection,
      description: `CROSS_SURFACE_SECTION_REDIRECTS[${key}]`,
    })
  }
  return sources
}

describe('redirect-ledger contract (RFC-0048 §4.3)', () => {
  it('every visible section in DASHBOARD_SECTION_ITEMS resolves to itself', () => {
    const failures: string[] = []
    for (const tab of Object.keys(DASHBOARD_SECTION_ITEMS) as NonHomeTabId[]) {
      for (const item of DASHBOARD_SECTION_ITEMS[tab]) {
        const section = item.params.section
        if (!section) continue
        navigate(tab, { section })
        const landed = route.value
        const registered = registeredSections(landed.tab as NonHomeTabId)
        const landedSection = landed.params.section ?? ''
        if (!registered.has(landedSection)) {
          failures.push(
            `${tab}:${section} → ${landed.tab}:${landedSection} (not in DASHBOARD_SECTION_ITEMS)`,
          )
        }
      }
    }
    expect(failures).toEqual([])
  })

  it('every redirect source resolves to a currently-rendered section', () => {
    const sources = enumerateRedirectSources()
    expect(sources.length).toBeGreaterThan(0)

    const failures: string[] = []
    for (const { fromTab, fromSection, description } of sources) {
      navigate(fromTab as NonHomeTabId, { section: fromSection })
      const landed = route.value
      const landedTab = landed.tab as NonHomeTabId
      const landedSection = landed.params.section ?? ''
      const registered = registeredSections(landedTab)
      if (!registered.has(landedSection)) {
        failures.push(
          `${description}: ${fromTab}:${fromSection} → ${landedTab}:${landedSection} (not rendered)`,
        )
      }
    }
    expect(failures).toEqual([])
  })

  it('redirect resolution converges in one hop (no chains)', () => {
    // After applying a redirect, the resulting (tab, section) must NOT
    // itself be a key in either redirect map. Otherwise repeated
    // navigation could loop or land somewhere unexpected.
    const sources = enumerateRedirectSources()
    const chained: string[] = []
    for (const { fromTab, fromSection, description } of sources) {
      navigate(fromTab as NonHomeTabId, { section: fromSection })
      const landed = route.value
      const landedKey = `${landed.tab}:${landed.params.section ?? ''}`
      if (
        landedKey in SECTION_REDIRECTS
        || landedKey in CROSS_SURFACE_SECTION_REDIRECTS
      ) {
        chained.push(`${description} lands on ${landedKey} which is itself a redirect source`)
      }
    }
    expect(chained).toEqual([])
  })

  it('hashForRoute on every section ID produces a non-empty canonical hash', () => {
    const sources = enumerateRedirectSources()
    const visible: { tab: NonHomeTabId; section: string }[] = []
    for (const tab of Object.keys(DASHBOARD_SECTION_ITEMS) as NonHomeTabId[]) {
      for (const item of DASHBOARD_SECTION_ITEMS[tab]) {
        if (item.params.section) {
          visible.push({ tab, section: item.params.section })
        }
      }
    }

    const empty: string[] = []
    for (const { fromTab, fromSection, description } of sources) {
      const hash = hashForRoute(fromTab as NonHomeTabId, { section: fromSection })
      if (!hash || hash === '#') {
        empty.push(description)
      }
    }
    for (const { tab, section } of visible) {
      const hash = hashForRoute(tab, { section })
      if (!hash || hash === '#') {
        empty.push(`DASHBOARD_SECTION_ITEMS ${tab}:${section}`)
      }
    }
    expect(empty).toEqual([])
  })
})
