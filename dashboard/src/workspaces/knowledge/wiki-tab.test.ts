// @vitest-environment jsdom
// jsdom: DOMPurify fails its smoke test under happy-dom and the renderer then
// escapes the whole body, so no link would reach the DOM.

import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { authSession, resetAuthStateForTests } from '../../core/auth'
import { resetObserverStateForTests } from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { KnowledgeWorkspace } from './index'

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' } })
}

// Under jsdom, Preact runs after-paint effects only when an act() scope ends,
// so each round lets fetches settle and then flushes the effects they caused.
async function settle(rounds = 8): Promise<void> {
  for (let i = 0; i < rounds; i++) {
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0))
    })
  }
}

describe('WikiTab body links', () => {
  let container: HTMLDivElement
  const origFetch = globalThis.fetch

  beforeEach(() => {
    resetAuthStateForTests()
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      role: 'admin',
      canTokenAdmin: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    resetObserverStateForTests()
    resourceCache.clearAll()
    vi.spyOn(HTMLElement.prototype, 'clientHeight', 'get').mockReturnValue(480)
    vi.spyOn(HTMLElement.prototype, 'clientWidth', 'get').mockReturnValue(600)
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    globalThis.fetch = origFetch
    vi.restoreAllMocks()
    resourceCache.clearAll()
    resetAuthStateForTests()
    resetObserverStateForTests()
  })

  it('Wiki body links to existing pages open the page in the tab, with the target summary as title', async () => {
    const indexPage = (slug: string, title: string, summary: string) => ({
      slug, file: `${slug}.md`, title, summary, source: 'observation',
      author: 'librarian', created: '2026-11-20T00:00:00Z', updated: '2026-11-24T05:00:00Z',
      revision: 1, tags: [], backlink_count: 0, outgoing_link_count: 0, sources_count: 0, hearsay_count: 0, sha256: `sha-${slug}`,
    })
    const pageEnvelope = (slug: string, body: string, outgoing_links: unknown[]) => ({
      schema_version: 1,
      instance_id: 'inst-1',
      generated_at_unix: 1732430000,
      data: {
        page: slug,
        slug,
        file: `${slug}.md`,
        frontmatter: {
          title: slug, summary: '', source: 'observation', author: 'librarian',
          created: '2026-11-20T00:00:00Z', updated: '2026-11-24T05:00:00Z', revision: 1, tags: [],
        },
        sha256: `sha-${slug}`,
        body_markdown: body,
        outgoing_links,
        backlinks: [],
        sources: { references: [], hearsay: [] },
        lint_findings: [],
      },
    })
    const link = (text: string, kind: string, target: string, raw: string, exists: boolean | null) =>
      ({ text, kind, target, raw, line: 1, exists })

    globalThis.fetch = vi.fn((input: RequestInfo | URL) => {
      const url = String(input)
      if (url.startsWith('/api/v1/wiki?')) {
        return Promise.resolve(jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1732430000,
          data: {
            pages_total: 2, pages_readable: 2, pages_unreadable: 0,
            pages: [indexPage('page-a', 'Page A', ''), indexPage('page-b', 'Page B', 'The second page')],
            unreadable_pages: [], tags: [], sources: { observation: 2 },
            lint: { total_findings: 0, counts: {}, log_hole_suppressed: false, orphans: [], duplicate_title_candidates: [], findings: [] },
          },
        }))
      }
      if (url === '/api/v1/wiki/page-a') {
        return Promise.resolve(jsonResponse(pageEnvelope(
          'page-a',
          'See [B](page-b.md), [gone](page-gone.md) and [site](https://example.com).',
          [
            link('B', 'page', 'page-b', 'page-b.md', true),
            link('gone', 'page', 'page-gone', 'page-gone.md', false),
            link('site', 'external', 'https://example.com', 'https://example.com', null),
          ],
        )))
      }
      if (url === '/api/v1/wiki/page-b') {
        return Promise.resolve(jsonResponse(pageEnvelope('page-b', 'Body of page B', [])))
      }
      return Promise.resolve(jsonResponse({}))
    }) as typeof fetch

    act(() => {
      render(html`<${KnowledgeWorkspace} subroute="wiki" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    })
    await settle()

    const byText = (text: string) =>
      [...container.querySelectorAll<HTMLAnchorElement>('.kn-md-panel a')].find((a) => a.textContent === text)
    expect(byText('B')?.getAttribute('href')).toBe('#/knowledge/wiki/page-b')
    expect(byText('B')?.hasAttribute('target')).toBe(false)
    expect(byText('B')?.getAttribute('title')).toBe('The second page')
    expect(byText('gone')?.getAttribute('href')).toBe('page-gone.md')
    expect(byText('site')?.getAttribute('target')).toBe('_blank')

    act(() => {
      byText('B')?.click()
    })
    await settle()
    expect(container.textContent).toContain('Body of page B')
  })
})
