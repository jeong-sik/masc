// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from 'vitest'
import { act } from 'preact/test-utils'
import { h, render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import {
  authSession,
  bumpSessionEpoch,
  setSingleUserToken,
} from '../../core/auth'
import { resourceCache } from '../../core/resource-cache'
import {
  clearWorkspaceMediaCache,
  getWorkspaceMediaCacheStats,
} from '../../lib/workspace-media-cache'
import { currentRoute, initAPlusRouter } from '../../routes/router'
import {
  MarkdownContent,
  clearEmbedMetadataCache,
  renderMarkdown,
} from './markdown-renderer'

const PNG_1X1 = Uint8Array.from(atob(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII=',
), byte => byte.charCodeAt(0))

const DEFAULT_AUTH_METHODS = Object.freeze({ google: false, github: false, dev_token: false })

afterEach(() => {
  clearWorkspaceMediaCache()
  clearEmbedMetadataCache()
  setSingleUserToken(null)
  authSession.value = { kind: 'probing' }
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

describe('MarkdownContent', () => {
  it('renders container', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '' }), container)
    expect(container.querySelector('.markdown-content')).not.toBeNull()
  })

  it('renders plain text as paragraph', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: 'hello world' }), container)
    expect(container.querySelector('p')).not.toBeNull()
    expect(container.textContent).toContain('hello world')
  })

  it('renders bold text', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '**bold**' }), container)
    expect(container.querySelector('strong')).not.toBeNull()
    expect(container.textContent).toContain('bold')
  })

  it('renders italic text', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '*italic*' }), container)
    expect(container.querySelector('em')).not.toBeNull()
    expect(container.textContent).toContain('italic')
  })

  it('renders headings', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '# H1\n## H2' }), container)
    expect(container.querySelector('h1')).not.toBeNull()
    expect(container.querySelector('h2')).not.toBeNull()
  })

  it('renders code block', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '```js\nconst x = 1;\n```' }), container)
    expect(container.querySelector('pre')).not.toBeNull()
    expect(container.querySelector('code')).not.toBeNull()
  })

  it('renders inline code', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: 'use `code`' }), container)
    expect(container.querySelector('code')).not.toBeNull()
    expect(container.textContent).toContain('code')
  })

  it('renders unordered list', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '- a\n- b' }), container)
    expect(container.querySelector('ul')).not.toBeNull()
    expect(container.querySelectorAll('li').length).toBe(2)
  })

  it('renders ordered list', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '1. first\n2. second' }), container)
    expect(container.querySelector('ol')).not.toBeNull()
    expect(container.querySelectorAll('li').length).toBe(2)
  })

  it('renders link with target blank', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '[link](https://example.com)' }), container)
    const a = container.querySelector('a') as HTMLAnchorElement
    expect(a).not.toBeNull()
    expect(a?.getAttribute('target')).toBe('_blank')
    expect(a?.getAttribute('rel')).toContain('noopener')
  })

  it('keeps nested emphasis and code in link labels', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '[**검토** `head`](https://example.test/review)' }), container)
    expect(container.querySelector('a strong')?.textContent).toBe('검토')
    expect(container.querySelector('a code')?.textContent).toBe('head')
  })

  it('links a failed image to its source when URL.parse is unavailable', () => {
    const container = document.createElement('div')
    class BrowserUrl extends URL {}
    Object.defineProperty(BrowserUrl, 'parse', { value: undefined })
    vi.stubGlobal('URL', BrowserUrl)
    try {
      act(() => render(h(MarkdownContent, { text: '![diagram](https://example.test/diagram.png)' }), container))
      container.querySelector('img')?.dispatchEvent(new Event('error'))
      expect(container.querySelector('a')?.getAttribute('href')).toBe('https://example.test/diagram.png')
    } finally {
      render(null, container)
      vi.unstubAllGlobals()
    }
  })

  it('renders blockquote', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '> quote' }), container)
    expect(container.querySelector('blockquote')).not.toBeNull()
  })

  it('renders table', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '| a | b |\n|---|---|\n| 1 | 2 |' }), container)
    expect(container.querySelector('table')).not.toBeNull()
    expect(container.querySelectorAll('td').length).toBe(2)
  })

  it('puts each table in a box that scrolls sideways, in chat and in documents', () => {
    for (const document of [false, true]) {
      const container = window.document.createElement('div')
      render(h(MarkdownContent, { text: '| a | b |\n|---|---|\n| 1 | 2 |', document }), container)
      const table = container.querySelector('table')
      expect(table?.parentElement?.classList.contains('markdown-table-scroll')).toBe(true)
    }
  })

  it('sanitizes script tags', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '<script>alert(1)</script>' }), container)
    expect(container.querySelector('script')).toBeNull()
  })

  it('renders sanitized HTML blocks without unsafe attributes in both chat and document modes', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, {
      text: '<div class="idea-card" onclick="alert(1)"><span data-x="bad">HTML idea</span></div>',
    }), container)

    const div = container.querySelector('.idea-card') as HTMLDivElement | null
    const span = container.querySelector('span') as HTMLSpanElement | null
    expect(div).not.toBeNull()
    expect(div?.textContent).toContain('HTML idea')
    expect(div?.getAttribute('onclick')).toBeNull()
    expect(span?.getAttribute('data-x')).toBeNull()

    // Document mode also enforces ALLOW_DATA_ATTR: false & FORBID_TAGS
    render(h(MarkdownContent, {
      document: true,
      text: '<div data-evil="1"><iframe src="https://evil.test"></iframe><form></form><span data-masc-media-src="https://evil.test/x.png" class="masc-media-slot">raw</span><a class="masc-embed-card" href="https://evil.test" data-masc-embed-kind="wiki" data-masc-embed-target="design-doc">spoof</a></div>',
    }), container)
    expect(container.querySelector('iframe')).toBeNull()
    expect(container.querySelector('form')).toBeNull()
    expect(container.querySelector('[data-evil]')).toBeNull()
    // Forged non-workspace data-masc-media-src and mismatched-href embed cards are stripped fail-closed
    expect(container.querySelector('[data-masc-media-src]')).toBeNull()
    expect(container.querySelector('[data-masc-embed-kind]')).toBeNull()
    expect(container.querySelector('.masc-embed-card')).toBeNull()
  })

  it('renders think block as details', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '<think>hidden thought</think>' }), container)
    expect(container.querySelector('details')).not.toBeNull()
    expect(container.querySelector('summary')).not.toBeNull()

    render(h(MarkdownContent, { text: '  <THINK>indented uppercase</THINK >' }), container)
    expect(container.querySelector('details.think-block')).not.toBeNull()
    expect(container.querySelector('details.think-block')?.textContent).toContain('indented uppercase')
  })

  it('keeps #fragment links in-page without target="_blank" when document={false}', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, {
      text: '[Jump](#sec) · [External](https://example.test/doc)',
    }), container)
    const links = Array.from(container.querySelectorAll('a'))
    expect(links).toHaveLength(2)
    expect(links[0]?.getAttribute('href')).toBe('#sec')
    expect(links[0]?.hasAttribute('target')).toBe(false)
    expect(links[1]?.getAttribute('href')).toBe('https://example.test/doc')
    expect(links[1]?.getAttribute('target')).toBe('_blank')
  })

  it('keeps inline think tags and document fragment navigation intact', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: 'Use `<think>literal</think>`.' }), container)
    expect(container.querySelector('code')?.textContent).toBe('<think>literal</think>')
    expect(container.querySelector('details')).toBeNull()

    render(h(MarkdownContent, {
      document: true,
      text: '[Appendix](#appendix) · [Spec](https://example.test/spec) · <a href="https://example.test/raw" target="_blank" rel="opener">RawExt</a> · <a href="#appendix" target="_blank">RawFrag</a>\n\n<h2 id="appendix">Appendix</h2>\n\n<details open><summary>Key</summary><kbd>Enter</kbd></details>',
    }), container)
    const links = Array.from(container.querySelectorAll('a'))
    expect(links).toHaveLength(4)
    expect(links[0]?.getAttribute('href')).toBe('#appendix')
    expect(links[0]?.hasAttribute('target')).toBe(false)
    expect(links[1]?.getAttribute('href')).toBe('https://example.test/spec')
    expect(links[1]?.getAttribute('target')).toBe('_blank')
    expect(links[1]?.getAttribute('rel')).toBe('noopener noreferrer')
    expect(links[2]?.getAttribute('href')).toBe('https://example.test/raw')
    expect(links[2]?.getAttribute('target')).toBe('_blank')
    expect(links[2]?.getAttribute('rel')).toBe('noopener noreferrer')
    expect(links[3]?.getAttribute('href')).toBe('#appendix')
    expect(links[3]?.hasAttribute('target')).toBe(false)
    expect(container.querySelector('#appendix')?.textContent).toBe('Appendix')
    expect(container.querySelector('details[open] kbd')?.textContent).toBe('Enter')
  })

  it('strips target from document links whose href is stripped or empty/fragment after sanitization', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, {
      document: true,
      text: '[Bad](javascript:alert(1)) · <a href="   " target="_blank">Blank</a> · <a href=" #sec" target="_blank">Padded</a>',
    }), container)
    const links = Array.from(container.querySelectorAll('a'))
    expect(links).toHaveLength(3)
    expect(links[0]?.hasAttribute('href')).toBe(false)
    expect(links[0]?.hasAttribute('target')).toBe(false)
    expect(links[1]?.hasAttribute('target')).toBe(false)
    expect(links[2]?.hasAttribute('target')).toBe(false)
  })

  it('scrolls to a document fragment without changing the Dashboard route', () => {
    const container = document.createElement('div')
    const previousUrl = window.location.href
    document.body.append(container)
    window.history.replaceState(null, '', '#/knowledge/board')
    const stopRouter = initAPlusRouter()
    try {
      render(h(MarkdownContent, {
        document: true,
        text: '[Appendix](#appendix)\n\n<h2 id="appendix">Appendix</h2>',
      }), container)
      const scrollIntoView = vi.fn()
      container.querySelector('h2')!.scrollIntoView = scrollIntoView

      const click = new MouseEvent('click', { bubbles: true, cancelable: true })
      container.querySelector('a')!.dispatchEvent(click)

      expect(click.defaultPrevented).toBe(true)
      expect(scrollIntoView).toHaveBeenCalledWith({ block: 'start' })
      expect(window.location.hash).toBe('#/knowledge/board')
      expect(currentRoute.value.path).toBe('/knowledge/board')
    } finally {
      stopRouter()
      window.history.replaceState(null, '', previousUrl)
      initAPlusRouter()()
      render(null, container)
      container.remove()
    }
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '', class: 'extra-class' }), container)
    const el = container.querySelector('.markdown-content') as HTMLElement
    expect(el?.classList.contains('extra-class')).toBe(true)
  })

  it('renders horizontal rule', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '---' }), container)
    expect(container.querySelector('hr')).not.toBeNull()
  })
})

describe('MarkdownContent workspace media & rich embeds', () => {
  it('emits zero bare <img src="/api/v1/media/..."> for Markdown, Obsidian media, and raw HTML img', () => {
    const sha = 'a'.repeat(64)
    const path = `/api/v1/media/${sha}`

    const mdHtml = renderMarkdown(`![chart](${path})`)
    expect(mdHtml).not.toContain(`<img`)
    expect(mdHtml).toContain(`data-masc-media-src="${path}"`)

    const obsidianHtml = renderMarkdown(`![[media:${sha}|Caption]]`)
    expect(obsidianHtml).not.toContain(`<img`)
    expect(obsidianHtml).toContain(`data-masc-media-src="${path}"`)
    expect(obsidianHtml).toContain(`data-masc-media-alt="Caption"`)

    const rawImgHtml = renderMarkdown(`<img src="${path}" alt="Raw">`)
    expect(rawImgHtml).not.toContain(`<img`)
    expect(rawImgHtml).toContain(`data-masc-media-src="${path}"`)
    expect(rawImgHtml).toContain(`data-masc-media-alt="Raw"`)

    const malformed = renderMarkdown('![bad](/api/v1/media/not-64-hex)')
    expect(malformed).not.toContain('<img')
    expect(malformed).toContain('masc-embed-invalid')
  })

  it('hydrates workspace media lazily via IntersectionObserver, opens lightbox, retries on error, and revokes on epoch bump', async () => {
    const sha = 'c'.repeat(64)
    const path = `/api/v1/media/${sha}`
    let blobSeq = 0
    const revokeSpy = vi.fn<(url: string) => void>()
    vi.stubGlobal('URL', Object.assign(URL, {
      createObjectURL: vi.fn(() => `blob:md-media-${++blobSeq}`),
      revokeObjectURL: revokeSpy,
    }))

    const observed: Array<{ target: Element; callback: IntersectionObserverCallback }> = []
    class FakeIntersectionObserver {
      callback: IntersectionObserverCallback
      constructor(callback: IntersectionObserverCallback) {
        this.callback = callback
      }
      observe(target: Element) {
        observed.push({ target, callback: this.callback })
      }
      unobserve() {}
      disconnect() {}
    }
    vi.stubGlobal('IntersectionObserver', FakeIntersectionObserver)

    setSingleUserToken('md-bearer-tok')
    const fetchMock = vi.fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(new Response(null, { status: 503 }))
      .mockResolvedValueOnce(new Response(PNG_1X1, { status: 200, headers: { 'Content-Type': 'image/png' } }))
    vi.stubGlobal('fetch', fetchMock)

    const container = document.createElement('div')
    document.body.append(container)
    try {
      act(() => {
        render(h(MarkdownContent, {
          document: true,
          text: `![[media:${sha}|Diagram caption]]`,
        }), container)
      })

      // Before intersection: skeleton loading slot, ZERO network fetch yet!
      expect(fetchMock).toHaveBeenCalledTimes(0)
      expect(container.querySelector('.masc-media-slot')?.getAttribute('data-masc-media-state')).toBe('loading')

      // Trigger intersection -> first attempt 503 -> error + retry button
      const entry = observed[0]!
      entry.callback([{ isIntersecting: true, target: entry.target } as IntersectionObserverEntry], {} as IntersectionObserver)

      await waitFor(() => {
        expect(container.querySelector('.masc-media-retry')).not.toBeNull()
      })
      expect(fetchMock).toHaveBeenCalledTimes(1)
      expect(String(fetchMock.mock.calls[0]?.[0])).toBe(window.location.origin + path)
      expect(new Headers(fetchMock.mock.calls[0]?.[1]?.headers).get('Authorization')).toBe('Bearer md-bearer-tok')

      // Click retry -> 200 PNG -> hydrated blob URL + caption
      const retryBtn = container.querySelector<HTMLButtonElement>('.masc-media-retry')!
      retryBtn.click()

      await waitFor(() => {
        const img = container.querySelector<HTMLImageElement>('.masc-media-img')
        expect(img).not.toBeNull()
        expect(img?.getAttribute('src')).toBe('blob:md-media-1')
        expect(img?.getAttribute('decoding')).toBe('async')
      })
      expect(container.querySelector('.masc-media-caption')?.textContent).toBe('Diagram caption')

      // Click zoom trigger -> opens lightbox modal -> Escape closes it
      const trigger = container.querySelector<HTMLButtonElement>('.masc-media-trigger')!
      fireEvent.click(trigger)
      await waitFor(() => {
        expect(document.querySelector('[role="dialog"][aria-modal="true"]')).not.toBeNull()
      })
      fireEvent.keyDown(document, { key: 'Escape' })
      await waitFor(() => {
        expect(document.querySelector('[role="dialog"][aria-modal="true"]')).toBeNull()
      })

      // Unmount releases slot lease; epoch bump revokes object URL
      act(() => render(null, container))
      expect(getWorkspaceMediaCacheStats().activeLeases).toBe(0)
      bumpSessionEpoch()
      expect(revokeSpy).toHaveBeenCalledWith('blob:md-media-1')
    } finally {
      render(null, container)
      container.remove()
    }
  })

  it('draws a 640px thumbnail for an attachment but opens the lightbox on the original image', async () => {
    const path = `/api/v1/attachments/att_${'d'.repeat(64)}`
    let blobSeq = 0
    vi.stubGlobal('URL', Object.assign(URL, {
      createObjectURL: vi.fn(() => `blob:md-att-${++blobSeq}`),
      revokeObjectURL: vi.fn(),
    }))
    vi.stubGlobal('IntersectionObserver', undefined)
    setSingleUserToken('md-bearer-tok')
    const originalAnswers = [503, 200]
    const fetchMock = vi.fn<typeof globalThis.fetch>(async (input) => {
      const url = String(input)
      const status = url.includes('max_px=') ? 200 : originalAnswers.shift()!
      return status === 200
        ? new Response(PNG_1X1, { status, headers: { 'Content-Type': 'image/png' } })
        : new Response(null, { status })
    })
    vi.stubGlobal('fetch', fetchMock)
    const fetched = () => fetchMock.mock.calls.map(call => String(call[0]))
    const dialog = () => document.querySelector('[role="dialog"][aria-modal="true"]')

    const container = document.createElement('div')
    document.body.append(container)
    try {
      act(() => {
        render(h(MarkdownContent, { document: true, text: `![Screenshot](${path})` }), container)
      })
      await waitFor(() => {
        expect(container.querySelector('.masc-media-img')?.getAttribute('src')).toBe('blob:md-att-1')
      })
      expect(fetched()).toEqual([`${window.location.origin}${path}?max_px=640`])

      // The first original fetch fails: the lightbox says so instead of showing the thumbnail.
      fireEvent.click(container.querySelector<HTMLButtonElement>('.masc-media-trigger')!)
      await waitFor(() => {
        expect(dialog()?.textContent).toContain('원본 이미지를 불러올 수 없습니다')
      })
      expect(dialog()?.querySelector('img')).toBeNull()
      fireEvent.keyDown(document, { key: 'Escape' })
      await waitFor(() => expect(dialog()).toBeNull())

      // Opening again fetches the original path, without the thumbnail query.
      fireEvent.click(container.querySelector<HTMLButtonElement>('.masc-media-trigger')!)
      await waitFor(() => {
        expect(dialog()?.querySelector('img')?.getAttribute('src')).toBe('blob:md-att-2')
      })
      expect(fetched()).toEqual([
        `${window.location.origin}${path}?max_px=640`,
        `${window.location.origin}${path}`,
        `${window.location.origin}${path}`,
      ])

      fireEvent.keyDown(document, { key: 'Escape' })
      await waitFor(() => expect(dialog()).toBeNull())
      act(() => render(null, container))
      expect(getWorkspaceMediaCacheStats().activeLeases).toBe(0)
    } finally {
      render(null, container)
      container.remove()
    }
  })

  it('renders typed wiki, bare wiki, artifact, invalid, and unsupported Obsidian embeds while ignoring code spans', () => {
    const artId = `artifact-${'f'.repeat(32)}`
    const onNavigate = vi.fn()
    const container = document.createElement('div')
    document.body.append(container)
    try {
      act(() => {
        render(h(MarkdownContent, {
          document: true,
          onNavigate,
          text: [
            '![[wiki:system-arch|Architecture]]',
            '![[release-notes]]',
            `![[artifact:${artId}|Bench Report]]`,
            '![[wiki:index]]',
            '![[ftp:secret]]',
            '`![[wiki:in-code]]`',
            '```\n![[wiki:in-fence]]\n```',
          ].join('\n\n'),
        }), container)
      })

      const wikiCards = container.querySelectorAll<HTMLAnchorElement>('a.masc-embed-card--wiki')
      expect(wikiCards).toHaveLength(2)
      expect(wikiCards[0]?.getAttribute('href')).toBe('#/knowledge/wiki/system-arch')
      expect(wikiCards[0]?.textContent).toContain('Architecture')
      expect(wikiCards[1]?.getAttribute('href')).toBe('#/knowledge/wiki/release-notes')
      expect(wikiCards[1]?.textContent).toContain('release-notes')

      const artCard = container.querySelector<HTMLAnchorElement>('a.masc-embed-card--artifact')
      expect(artCard?.getAttribute('href')).toBe(`#/knowledge/artifacts/${artId}`)
      expect(artCard?.textContent).toContain('Bench Report')

      expect(container.querySelector('.masc-embed-invalid')?.textContent).toContain('wiki:index')
      expect(container.querySelector('.masc-embed-unsupported')?.textContent).toContain('ftp')

      // Code spans and fences stay literal text
      const codeTexts = Array.from(container.querySelectorAll('code')).map((c) => c.textContent)
      expect(codeTexts).toContain('![[wiki:in-code]]')
      expect(codeTexts.some((t) => t?.includes('![[wiki:in-fence]]'))).toBe(true)

      // Clicking embed card invokes onNavigate with canonical route path
      const click = new MouseEvent('click', { bubbles: true, cancelable: true })
      wikiCards[0]!.dispatchEvent(click)
      expect(click.defaultPrevented).toBe(true)
      expect(onNavigate).toHaveBeenCalledWith('/knowledge/wiki/system-arch')
    } finally {
      render(null, container)
      container.remove()
    }
  })

  it('enriches multiple wiki & artifact embed cards with batched index lookups and skips fetches when unauthenticated', async () => {
    vi.stubGlobal('IntersectionObserver', undefined)
    const artId = `artifact-${'d'.repeat(32)}`
    const fetchMock = vi.fn<typeof globalThis.fetch>((input) => {
      const url = String(input)
      if (url.endsWith('/api/v1/wiki')) {
        return Promise.resolve(new Response(JSON.stringify({
          schema_version: 1,
          instance_id: 'i',
          generated_at_unix: 1,
          data: {
            pages: [
              { slug: 'design-guide', title: 'Design Guide Title', summary: 'Core media contract', revision: 4 },
              { slug: 'ops-runbook', title: 'Ops Runbook', summary: 'Deploy guide', revision: 2 },
            ],
          },
        }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      }
      if (url.endsWith('/api/v1/published-artifacts')) {
        return Promise.resolve(new Response(JSON.stringify({
          artifacts: [
            {
              id: artId,
              title: 'Latency Benchmark',
              summary: 'p99 under 12ms',
              format: 'html',
              revision: 3,
            },
          ],
        }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      }
      return Promise.resolve(new Response(null, { status: 404 }))
    })
    vi.stubGlobal('fetch', fetchMock)

    const container = document.createElement('div')
    document.body.append(container)
    try {
      // Unauthenticated (probing): ZERO network calls!
      act(() => {
        render(h(MarkdownContent, {
          document: true,
          text: `![[ wiki : design-guide ]]\n\n![[wiki:ops-runbook]]\n\n![[wiki:ghost-page]]\n\n![[ artifact : ${artId} ]]`,
        }), container)
      })
      expect(fetchMock).toHaveBeenCalledTimes(0)

      // Authenticated single-user admin: enriches all 3 wiki cards via ONE /api/v1/wiki fetch + 1 /api/v1/published-artifacts fetch
      authSession.value = {
        kind: 'single_user_local',
        mode: 'single_user',
        tokenPresent: true,
        role: 'admin',
        canTokenAdmin: true,
        canTokenRead: true,
        authMethods: DEFAULT_AUTH_METHODS,
        workspaceId: 'default',
      }
      act(() => {
        bumpSessionEpoch()
      })

      await waitFor(() => {
        const wikiCards = container.querySelectorAll('a.masc-embed-card--wiki')
        expect(wikiCards).toHaveLength(3)
        expect(wikiCards[0]?.textContent).toContain('Design Guide Title')
        expect(wikiCards[0]?.textContent).toContain('Core media contract')
        expect(wikiCards[1]?.textContent).toContain('Ops Runbook')
        expect(wikiCards[2]?.textContent).toContain('문서 없음')
        const artCard = container.querySelector('a.masc-embed-card--artifact')
        expect(artCard?.textContent).toContain('Latency Benchmark')
        expect(artCard?.textContent).toContain('HTML · rev 3')
      })

      const wikiCalls = fetchMock.mock.calls.filter(([u]) => String(u).includes('/api/v1/wiki'))
      const artCalls = fetchMock.mock.calls.filter(([u]) => String(u).includes('/api/v1/published-artifacts'))
      expect(wikiCalls).toHaveLength(1)
      expect(artCalls).toHaveLength(1)
    } finally {
      render(null, container)
      container.remove()
    }
  })

  it('refreshes embed metadata after resourceCache topic invalidation and after TTL expiry', async () => {
    const artId = `artifact-${'f'.repeat(32)}`
    let includeNewItems = false
    let wikiRevision = 1
    let nowMs = 1_700_000_000_000
    vi.spyOn(Date, 'now').mockImplementation(() => nowMs)

    const fetchMock = vi.fn<typeof globalThis.fetch>((input) => {
      const url = String(input)
      if (url.endsWith('/api/v1/wiki')) {
        const pages = includeNewItems
          ? [{ slug: 'brand-new-doc', title: 'Brand New Doc', summary: 'Freshly saved', revision: wikiRevision }]
          : []
        return Promise.resolve(new Response(JSON.stringify({
          schema_version: 1,
          instance_id: 'i',
          generated_at_unix: 1,
          data: { pages },
        }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      }
      if (url.endsWith('/api/v1/published-artifacts')) {
        const artifacts = includeNewItems
          ? [{ id: artId, title: 'Fresh Artifact', summary: 'Just published', format: 'markdown', revision: 1 }]
          : []
        return Promise.resolve(new Response(JSON.stringify({ artifacts }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }))
      }
      return Promise.resolve(new Response(null, { status: 404 }))
    })
    vi.stubGlobal('fetch', fetchMock)

    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      role: 'admin',
      canTokenAdmin: true,
      canTokenRead: true,
      authMethods: DEFAULT_AUTH_METHODS,
      workspaceId: 'default',
    }
    act(() => {
      bumpSessionEpoch()
    })

    const container = document.createElement('div')
    document.body.append(container)
    try {
      // 1. Initial render: both missing -> shows "문서 없음" / "아티팩트 없음"
      act(() => {
        render(h(MarkdownContent, {
          document: true,
          text: `![[wiki:brand-new-doc]]\n\n![[artifact:${artId}]]`,
        }), container)
      })
      await waitFor(() => {
        expect(container.querySelector('a.masc-embed-card--wiki')?.textContent).toContain('문서 없음')
        expect(container.querySelector('a.masc-embed-card--artifact')?.textContent).toContain('아티팩트 없음')
      })

      // 2. Author saves new Wiki page (WikiTab calls resourceCache.invalidateTopic('wiki'))
      //    and publishes new Artifact -> topic invalidation immediately refreshes on next render
      includeNewItems = true
      resourceCache.invalidateTopic('wiki')
      resourceCache.invalidateTopic('artifacts')

      act(() => {
        render(null, container)
        render(h(MarkdownContent, {
          document: true,
          text: `![[wiki:brand-new-doc]]\n\n![[artifact:${artId}]]`,
        }), container)
      })
      await waitFor(() => {
        const wikiCard = container.querySelector('a.masc-embed-card--wiki')
        expect(wikiCard?.textContent).toContain('Brand New Doc')
        expect(wikiCard?.textContent).toContain('rev 1')
        expect(wikiCard?.textContent).not.toContain('문서 없음')
        const artCard = container.querySelector('a.masc-embed-card--artifact')
        expect(artCard?.textContent).toContain('Fresh Artifact')
        expect(artCard?.textContent).not.toContain('아티팩트 없음')
      })

      // 3. Even without explicit topic invalidation, TTL expiry (>15s) refreshes updated revision
      wikiRevision = 2
      nowMs += 16_000
      act(() => {
        render(null, container)
        render(h(MarkdownContent, {
          document: true,
          text: '![[wiki:brand-new-doc]]',
        }), container)
      })
      await waitFor(() => {
        expect(container.querySelector('a.masc-embed-card--wiki')?.textContent).toContain('rev 2')
      })
    } finally {
      render(null, container)
      container.remove()
    }
  })
})

describe('renderMarkdown cache', () => {
  it('reuses sanitized HTML for identical source across calls', () => {
    renderMarkdown.clear()
    expect(renderMarkdown.size).toBe(0)

    const html = renderMarkdown('hello **world**')
    expect(html).toContain('<strong>')
    expect(renderMarkdown.size).toBe(1)

    renderMarkdown('hello **world**')
    expect(renderMarkdown.size).toBe(1) // cache hit: no new entry

    renderMarkdown('a different paragraph')
    expect(renderMarkdown.size).toBe(2)
  })
})
