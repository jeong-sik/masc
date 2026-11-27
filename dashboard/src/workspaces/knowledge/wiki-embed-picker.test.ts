import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { axe } from 'jest-axe'
import { authSession, bumpSessionEpoch } from '../../core/auth'
import { resourceCache } from '../../core/resource-cache'
import {
  WikiEmbedPicker,
  formatArtifactEmbed,
  formatWikiEmbed,
} from './wiki-embed-picker'
import type { WikiPageSummary } from './types'

const SAMPLE_PAGES: readonly WikiPageSummary[] = [
  {
    slug: 'architecture-notes',
    file: 'architecture-notes.md',
    title: 'Architecture Notes',
    summary: 'System overview',
    source: 'observation',
    author: 'librarian',
    created: '2026-11-20T00:00:00Z',
    updated: '2026-11-24T05:00:00Z',
    revision: 3,
    tags: ['core', 'design'],
    backlink_count: 2,
    outgoing_link_count: 1,
    sources_count: 1,
    hearsay_count: 0,
    sha256: 'a'.repeat(64),
  },
  {
    slug: 'media-pipeline',
    file: 'media-pipeline.md',
    title: 'Media Pipeline',
    summary: 'Upload and serve',
    source: 'research',
    author: 'sangsu',
    created: '2026-11-21T00:00:00Z',
    updated: '2026-11-25T05:00:00Z',
    revision: 1,
    tags: ['media'],
    backlink_count: 0,
    outgoing_link_count: 0,
    sources_count: 0,
    hearsay_count: 0,
    sha256: 'b'.repeat(64),
  },
]

const ARTIFACT_ID = 'artifact-0123456789abcdef0123456789abcdef'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

async function flushUi(ticks = 4): Promise<void> {
  for (let i = 0; i < ticks; i += 1) {
    await new Promise((r) => setTimeout(r, 0))
  }
}

describe('WikiEmbedPicker', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resourceCache.clearAll()
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      role: 'admin',
      canTokenAdmin: true,
      canTokenRead: true,
      authMethods: { google: false, github: false, dev_token: true },
      workspaceId: 'default',
    }
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    resourceCache.clearAll()
    vi.restoreAllMocks()
  })

  it('formats canonical wiki and artifact embeds', () => {
    expect(formatWikiEmbed('architecture-notes')).toBe('![[wiki:architecture-notes]]')
    expect(formatArtifactEmbed(ARTIFACT_ID)).toBe(`![[artifact:${ARTIFACT_ID}]]`)
  })

  it('filters wiki pages and inserts ![[wiki:<slug>]] with one click', async () => {
    const onInsertEmbed = vi.fn()
    render(
      html`<${WikiEmbedPicker}
        wikiPages=${SAMPLE_PAGES}
        currentSlug="architecture-notes"
        onInsertEmbed=${onInsertEmbed}
      />`,
      container,
    )

    const trigger = container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-picker-trigger"]')!
    trigger.click()
    await flushUi()

    expect(container.querySelector('[data-testid="wiki-embed-picker-popover"]')).not.toBeNull()
    expect(container.textContent).toContain('(현재 페이지)')

    const search = container.querySelector<HTMLInputElement>('[data-testid="wiki-embed-picker-search"]')!
    search.value = 'media'
    search.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()

    expect(container.querySelector('[data-testid="wiki-embed-option-wiki-architecture-notes"]')).toBeNull()
    const option = container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-option-wiki-media-pipeline"]')!
    option.click()
    await flushUi()

    expect(onInsertEmbed).toHaveBeenCalledWith('![[wiki:media-pipeline]]')
    expect(container.querySelector('[data-testid="wiki-embed-picker-popover"]')).toBeNull()
  })

  it('lazily loads published artifacts for single-user admin and inserts ![[artifact:<id>]]', async () => {
    const fetchMock = vi.fn<typeof fetch>(async (input) => {
      expect(String(input)).toBe('/api/v1/published-artifacts')
      return jsonResponse({
        artifacts: [
          {
            id: ARTIFACT_ID,
            revision: 2,
            title: 'Latency Benchmark',
            summary: 'P99 report',
            format: 'html',
            author: 'sangsu',
            created_at: '2026-11-26T00:00:00Z',
            body: { _blob: { sha256: 'c'.repeat(64), bytes: 1024 } },
          },
        ],
        diagnostics: [],
      })
    })
    globalThis.fetch = fetchMock

    const onInsertEmbed = vi.fn()
    render(
      html`<${WikiEmbedPicker} wikiPages=${SAMPLE_PAGES} onInsertEmbed=${onInsertEmbed} />`,
      container,
    )

    container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-picker-trigger"]')!.click()
    await flushUi()
    // Should NOT fetch artifacts until user opens the Artifacts tab
    expect(fetchMock).not.toHaveBeenCalled()

    container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-tab-artifact"]')!.click()
    await flushUi(6)

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const option = container.querySelector<HTMLButtonElement>(`[data-testid="wiki-embed-option-artifact-${ARTIFACT_ID}"]`)!
    expect(option).not.toBeNull()
    option.click()
    await flushUi()

    expect(onInsertEmbed).toHaveBeenCalledWith(`![[artifact:${ARTIFACT_ID}]]`)
  })

  it('does not fetch /api/v1/published-artifacts in multi-account mode and shows honest notice', async () => {
    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'acc-1',
      email: 'admin@example.com',
      displayName: 'Admin',
      role: 'admin',
      csrfToken: 'csrf-1',
      authMethods: { google: true, github: false, dev_token: false },
      workspaceId: 'default',
    }
    const fetchMock = vi.fn<typeof fetch>()
    globalThis.fetch = fetchMock

    render(
      html`<${WikiEmbedPicker} wikiPages=${SAMPLE_PAGES} onInsertEmbed=${vi.fn()} />`,
      container,
    )

    container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-picker-trigger"]')!.click()
    await flushUi()
    container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-tab-artifact"]')!.click()
    await flushUi()

    expect(fetchMock).not.toHaveBeenCalled()
    expect(container.textContent).toContain('싱글유저 로컬 세션')
  })

  it('clears artifact list cleanly on workspace epoch change', async () => {
    globalThis.fetch = vi.fn<typeof fetch>(async () =>
      jsonResponse({
        artifacts: [
          {
            id: ARTIFACT_ID,
            revision: 1,
            title: 'Old Workspace Artifact',
            summary: '',
            format: 'markdown',
            author: 'sangsu',
            created_at: '2026-11-26T00:00:00Z',
          },
        ],
        diagnostics: [],
      }),
    )

    render(
      html`<${WikiEmbedPicker} wikiPages=${SAMPLE_PAGES} onInsertEmbed=${vi.fn()} />`,
      container,
    )
    container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-picker-trigger"]')!.click()
    await flushUi()
    container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-tab-artifact"]')!.click()
    await flushUi(6)
    expect(container.textContent).toContain('Old Workspace Artifact')

    resourceCache.clearAll()
    globalThis.fetch = vi.fn<typeof fetch>(async () => jsonResponse({ artifacts: [], diagnostics: [] }))
    bumpSessionEpoch()
    await flushUi(6)
    expect(container.textContent).not.toContain('Old Workspace Artifact')
  })

  it('passes axe accessibility checks in open list and empty-search states', async () => {
    render(
      html`<${WikiEmbedPicker}
        wikiPages=${SAMPLE_PAGES}
        currentSlug="architecture-notes"
        onInsertEmbed=${vi.fn()}
      />`,
      container,
    )
    container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-picker-trigger"]')!.click()
    await flushUi()
    expect(await axe(container)).toHaveNoViolations()

    const search = container.querySelector<HTMLInputElement>('[data-testid="wiki-embed-picker-search"]')!
    search.value = 'no-match-xyz'
    search.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()
    expect(container.querySelector('[role="list"]')).toBeNull()
    expect(await axe(container)).toHaveNoViolations()
  })

  it('shows overflow indicator when more than 40 wiki pages match', async () => {
    const manyPages: WikiPageSummary[] = Array.from({ length: 45 }, (_, idx) => ({
      slug: `page-${String(idx + 1).padStart(2, '0')}`,
      file: `page-${String(idx + 1).padStart(2, '0')}.md`,
      title: `Page ${idx + 1}`,
      summary: '',
      source: 'observation',
      author: 'librarian',
      created: '2026-11-20T00:00:00Z',
      updated: '2026-11-25T00:00:00Z',
      revision: 1,
      tags: [],
      backlink_count: 0,
      outgoing_link_count: 0,
      sources_count: 0,
      hearsay_count: 0,
      sha256: 'a'.repeat(64),
    }))
    render(
      html`<${WikiEmbedPicker} wikiPages=${manyPages} onInsertEmbed=${vi.fn()} />`,
      container,
    )
    container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-picker-trigger"]')!.click()
    await flushUi()

    expect(container.querySelectorAll('[role="listitem"]').length).toBe(40)
    const overflow = container.querySelector('[data-testid="wiki-embed-picker-overflow"]')
    expect(overflow?.textContent).toContain('+5건 더 있음')
  })
})
