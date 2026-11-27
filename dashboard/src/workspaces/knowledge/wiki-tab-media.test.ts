// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { authSession, setSingleUserToken, wipeTransientSecrets } from '../../core/auth'
import { resourceCache } from '../../core/resource-cache'
import { shellToasts } from '../../shell/shell-state'
import { WikiTab } from './wiki-tab'

const VALID_SHA = 'e'.repeat(64)
const ARTIFACT_ID = 'artifact-0123456789abcdef0123456789abcdef'
const PNG_BYTES = new Uint8Array([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
])
const SVG_BYTES = new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"></svg>')

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

async function flushUi(ticks = 6): Promise<void> {
  for (let i = 0; i < ticks; i += 1) {
    await new Promise((r) => setTimeout(r, 0))
  }
}

function makeWikiMocks(uploadHandler?: (init?: RequestInit) => Promise<Response> | Response) {
  return vi.fn<typeof fetch>(async (input, init) => {
    const url = String(input)
    if (url === '/api/v1/media' && init?.method === 'POST') {
      if (uploadHandler) return uploadHandler(init)
      return jsonResponse({
        path: `/api/v1/media/${VALID_SHA}`,
        sha256: VALID_SHA,
        mime: 'image/png',
        bytes: PNG_BYTES.byteLength,
        width: 320,
        height: 200,
      }, 201)
    }
    if (url === '/api/v1/published-artifacts') {
      return jsonResponse({
        artifacts: [
          {
            id: ARTIFACT_ID,
            revision: 1,
            title: 'System Benchmark',
            summary: 'HTML report',
            format: 'html',
            author: 'sangsu',
            created_at: '2026-11-26T00:00:00Z',
            body: { _blob: { sha256: 'd'.repeat(64), bytes: 512 } },
          },
        ],
        diagnostics: [],
      })
    }
    if (url.startsWith('/api/v1/wiki/arch-notes')) {
      return jsonResponse({
        schema_version: 1,
        instance_id: 'inst-1',
        generated_at_unix: 1732430000,
        data: {
          page: 'arch-notes',
          slug: 'arch-notes',
          file: 'arch-notes.md',
          sha256: 'f'.repeat(64),
          body_markdown: '# Intro\n\nExisting paragraph.',
          frontmatter: {
            title: 'Architecture Notes',
            summary: 'Core notes',
            source: 'observation',
            author: 'librarian',
            created: '2026-11-20T00:00:00Z',
            updated: '2026-11-25T00:00:00Z',
            revision: 1,
            tags: ['core'],
          },
          outgoing_links: [],
          backlinks: [],
          lint_findings: [],
        },
      })
    }
    if (url.startsWith('/api/v1/wiki?')) {
      const parsed = new URL(url, 'http://localhost')
      const tagParam = parsed.searchParams.get('tag')
      const allPages = [
        {
          slug: 'arch-notes',
          file: 'arch-notes.md',
          title: 'Architecture Notes',
          summary: 'Core notes',
          source: 'observation',
          author: 'librarian',
          created: '2026-11-20T00:00:00Z',
          updated: '2026-11-25T00:00:00Z',
          revision: 1,
          tags: ['core'],
          backlink_count: 0,
          outgoing_link_count: 0,
          sources_count: 0,
          hearsay_count: 0,
          sha256: 'f'.repeat(64),
        },
        {
          slug: 'media-guide',
          file: 'media-guide.md',
          title: 'Media Guide',
          summary: 'How images work',
          source: 'research',
          author: 'sangsu',
          created: '2026-11-21T00:00:00Z',
          updated: '2026-11-26T00:00:00Z',
          revision: 2,
          tags: ['media'],
          backlink_count: 0,
          outgoing_link_count: 0,
          sources_count: 0,
          hearsay_count: 0,
          sha256: 'b'.repeat(64),
        },
      ]
      const filteredPages = tagParam ? allPages.filter((p) => p.tags.includes(tagParam)) : allPages
      return jsonResponse({
        schema_version: 1,
        instance_id: 'inst-1',
        generated_at_unix: 1732430000,
        data: {
          pages_total: filteredPages.length,
          pages_readable: filteredPages.length,
          pages_unreadable: 0,
          pages: filteredPages,
          unreadable_pages: [],
          tags: [
            { tag: 'core', count: 1 },
            { tag: 'media', count: 1 },
          ],
          sources: { observation: 1, research: 1 },
          lint: {
            total_findings: 0,
            counts: {},
            log_hole_suppressed: false,
            orphans: [],
            duplicate_title_candidates: [],
            findings: [],
          },
        },
      })
    }
    return jsonResponse({})
  })
}

describe('WikiTab authoring productivity UX', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resourceCache.clearAll()
    wipeTransientSecrets()
    setSingleUserToken('admin-secret-token')
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
    wipeTransientSecrets()
    vi.restoreAllMocks()
  })

  async function enterWikiEditor(): Promise<HTMLTextAreaElement> {
    render(
      html`<${WikiTab} subroute="wiki" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    const editBtn = await vi.waitFor(() => {
      const btn = [...container.querySelectorAll<HTMLButtonElement>('button')].find((b) =>
        b.textContent?.includes('CAS 편집'),
      )
      expect(btn).toBeDefined()
      return btn!
    }, { timeout: 5000 })
    editBtn.click()
    return await vi.waitFor(() => {
      const ta = container.querySelector<HTMLTextAreaElement>('textarea[aria-label="Markdown 본문 편집기"]')
      expect(ta).not.toBeNull()
      return ta!
    }, { timeout: 5000 })
  }

  it('supports split, write-only, and live preview modes updating as the author types', async () => {
    globalThis.fetch = makeWikiMocks()
    const textarea = await enterWikiEditor()

    // Default split mode renders both textarea and live MarkdownContent document preview
    expect(container.querySelector('[data-testid="wiki-editor-workspace"]')?.getAttribute('data-view-mode')).toBe('split')
    const preview = container.querySelector('[data-testid="wiki-editor-live-preview"]')!
    expect(preview).not.toBeNull()
    expect(preview.querySelector('h1')?.textContent).toBe('Intro')

    // Live preview updates after split-mode debounce as text changes
    textarea.value = '## Updated Live Heading\n\n| A | B |\n| - | - |\n| 1 | 2 |'
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    await vi.waitFor(() => {
      expect(preview.querySelector('h2')?.textContent).toBe('Updated Live Heading')
      expect(preview.querySelector('table')).not.toBeNull()
    }, { timeout: 2000 })

    // Switch to write-only mode
    container.querySelector<HTMLButtonElement>('[data-testid="wiki-editor-mode-write"]')!.click()
    await flushUi(2)
    expect(container.querySelector('[data-testid="wiki-editor-live-preview"]')).toBeNull()
    expect(container.querySelector('textarea[aria-label="Markdown 본문 편집기"]')).not.toBeNull()

    // Switch to preview-only mode
    container.querySelector<HTMLButtonElement>('[data-testid="wiki-editor-mode-preview"]')!.click()
    await flushUi(2)
    expect(container.querySelector('textarea[aria-label="Markdown 본문 편집기"]')).toBeNull()
    expect(container.querySelector('[data-testid="wiki-editor-live-preview"] h2')?.textContent).toBe('Updated Live Heading')
  })

  it('uploads pasted PNG image via POST /api/v1/media and inserts canonical Markdown at cursor', async () => {
    const fetchMock = makeWikiMocks()
    globalThis.fetch = fetchMock
    const textarea = await enterWikiEditor()

    textarea.value = 'Before  After'
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    textarea.focus()
    textarea.setSelectionRange(7, 7)
    textarea.dispatchEvent(new Event('select', { bubbles: true }))
    await flushUi(2)

    const pngFile = new File([PNG_BYTES], 'arch-diagram.png', { type: 'image/png' })
    const pasteEvent = new Event('paste', { bubbles: true, cancelable: true })
    Object.defineProperty(pasteEvent, 'clipboardData', {
      value: { files: [pngFile], items: [], types: ['Files'] },
    })
    textarea.dispatchEvent(pasteEvent)
    await flushUi(8)

    expect(pasteEvent.defaultPrevented).toBe(true)
    expect(textarea.value).toBe(`Before ![arch-diagram](/api/v1/media/${VALID_SHA}) After`)
    const uploadCall = fetchMock.mock.calls.find(([url, init]) => String(url) === '/api/v1/media' && init?.method === 'POST')
    expect(uploadCall).toBeDefined()
    expect((uploadCall![1]?.headers as Record<string, string>)['Content-Type']).toBe('image/png')
    expect((uploadCall![1]?.headers as Record<string, string>).Authorization).toBe('Bearer admin-secret-token')
  })

  it('shows drag-and-drop overlay, uploads dropped image, and rejects SVG with an explicit error', async () => {
    const fetchMock = makeWikiMocks()
    globalThis.fetch = fetchMock
    const textarea = await enterWikiEditor()
    const dropzone = container.querySelector<HTMLElement>('[data-testid="wiki-editor-dropzone"]')!

    const dragEnter = new Event('dragenter', { bubbles: true, cancelable: true })
    Object.defineProperty(dragEnter, 'dataTransfer', { value: { types: ['Files'], files: [] } })
    dropzone.dispatchEvent(dragEnter)
    await flushUi(2)
    expect(container.querySelector('[data-testid="wiki-editor-drop-overlay"]')).not.toBeNull()

    // Drop an SVG -> blocked client-side before network, shows alert + error toast
    const svgFile = new File([SVG_BYTES], 'vector.svg', { type: 'image/svg+xml' })
    const badDrop = new Event('drop', { bubbles: true, cancelable: true })
    Object.defineProperty(badDrop, 'dataTransfer', { value: { types: ['Files'], files: [svgFile], items: [] } })
    dropzone.dispatchEvent(badDrop)
    await flushUi(6)

    expect(container.querySelector('[data-testid="wiki-editor-drop-overlay"]')).toBeNull()
    expect(container.querySelector('[data-testid="wiki-editor-upload-error"]')?.textContent).toContain('SVG')
    expect(shellToasts.value.some((t) => t.tone === 'error' && t.message.includes('SVG'))).toBe(true)
    expect(fetchMock.mock.calls.some(([url]) => String(url) === '/api/v1/media')).toBe(false)

    // Drop a valid PNG -> uploads and inserts
    const pngFile = new File([PNG_BYTES], 'chart.png', { type: 'image/png' })
    const goodDrop = new Event('drop', { bubbles: true, cancelable: true })
    Object.defineProperty(goodDrop, 'dataTransfer', { value: { types: ['Files'], files: [pngFile], items: [] } })
    dropzone.dispatchEvent(goodDrop)
    await flushUi(8)

    expect(container.querySelector('[data-testid="wiki-editor-upload-error"]')).toBeNull()
    expect(textarea.value).toContain(`![chart](/api/v1/media/${VALID_SHA})`)
  })

  it('inserts ![[wiki:<slug>]] and ![[artifact:<id>]] via Quick Embed Picker at cursor', async () => {
    globalThis.fetch = makeWikiMocks()
    const textarea = await enterWikiEditor()
    textarea.value = 'See: '
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    textarea.focus()
    textarea.setSelectionRange(5, 5)
    textarea.dispatchEvent(new Event('select', { bubbles: true }))
    await flushUi(2)

    // Insert Wiki embed
    container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-picker-trigger"]')!.click()
    await flushUi(2)
    container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-option-wiki-media-guide"]')!.click()
    await flushUi(2)
    expect(textarea.value).toBe('See: ![[wiki:media-guide]]')

    // Insert Artifact embed
    container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-picker-trigger"]')!.click()
    const artifactTab = await vi.waitFor(() => {
      const tab = container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-tab-artifact"]')
      expect(tab).not.toBeNull()
      return tab!
    }, { timeout: 5000 })
    artifactTab.click()
    const artifactOption = await vi.waitFor(() => {
      const opt = container.querySelector<HTMLButtonElement>(`[data-testid="wiki-embed-option-artifact-${ARTIFACT_ID}"]`)
      expect(opt).not.toBeNull()
      return opt!
    }, { timeout: 5000 })
    artifactOption.click()
    await vi.waitFor(() => {
      expect(textarea.value).toBe(`See: ![[wiki:media-guide]]![[artifact:${ARTIFACT_ID}]]`)
    }, { timeout: 5000 })
  })

  it('uploads multiple images sequentially in order and supports canceling an in-flight upload', async () => {
    const sha1 = '1'.repeat(64)
    const sha2 = '2'.repeat(64)
    let uploadCallCount = 0
    const fetchMock = makeWikiMocks(() => {
      uploadCallCount += 1
      const sha = uploadCallCount === 1 ? sha1 : sha2
      return jsonResponse({
        path: `/api/v1/media/${sha}`,
        sha256: sha,
        mime: 'image/png',
        bytes: PNG_BYTES.byteLength,
        width: 100,
        height: 100,
      }, 201)
    })
    globalThis.fetch = fetchMock
    const textarea = await enterWikiEditor()
    textarea.value = 'Gallery:\n'
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    textarea.focus()
    textarea.setSelectionRange(9, 9)
    textarea.dispatchEvent(new Event('select', { bubbles: true }))
    await flushUi(2)

    const dropzone = container.querySelector<HTMLElement>('[data-testid="wiki-editor-dropzone"]')!
    const file1 = new File([PNG_BYTES], 'first.png', { type: 'image/png' })
    const file2 = new File([PNG_BYTES], 'second.png', { type: 'image/png' })
    const dropEvt = new Event('drop', { bubbles: true, cancelable: true })
    Object.defineProperty(dropEvt, 'dataTransfer', { value: { types: ['Files'], files: [file1, file2], items: [] } })
    dropzone.dispatchEvent(dropEvt)
    await vi.waitFor(() => {
      expect(textarea.value).toBe(`Gallery:\n![first](/api/v1/media/${sha1})\n![second](/api/v1/media/${sha2})`)
    }, { timeout: 5000 })

    // Now test in-flight upload cancellation
    let aborted = false
    globalThis.fetch = makeWikiMocks((init) => new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => {
        aborted = true
        reject(new DOMException('Aborted', 'AbortError'))
      })
    }))

    const pendingFile = new File([PNG_BYTES], 'slow.png', { type: 'image/png' })
    const pendingDrop = new Event('drop', { bubbles: true, cancelable: true })
    Object.defineProperty(pendingDrop, 'dataTransfer', { value: { types: ['Files'], files: [pendingFile], items: [] } })
    dropzone.dispatchEvent(pendingDrop)

    const statusBar = await vi.waitFor(() => {
      const bar = container.querySelector('[data-testid="wiki-editor-upload-status"]')
      expect(bar).not.toBeNull()
      return bar!
    }, { timeout: 5000 })
    expect(statusBar.textContent).toContain('이미지 업로드 중… (1/1)')
    statusBar.querySelector<HTMLButtonElement>('button')!.click()
    await vi.waitFor(() => {
      expect(aborted).toBe(true)
      expect(container.querySelector('[data-testid="wiki-editor-upload-status"]')).toBeNull()
    }, { timeout: 5000 })
    expect(container.querySelector('[data-testid="wiki-editor-upload-error"]')).toBeNull()
  })

  it('blocks CAS save button and Cmd+S while an image upload is in flight', async () => {
    const fetchMock = makeWikiMocks((init) => new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
    }))
    globalThis.fetch = fetchMock
    await enterWikiEditor()

    const dropzone = container.querySelector<HTMLElement>('[data-testid="wiki-editor-dropzone"]')!
    const slowFile = new File([PNG_BYTES], 'pending.png', { type: 'image/png' })
    const dropEvt = new Event('drop', { bubbles: true, cancelable: true })
    Object.defineProperty(dropEvt, 'dataTransfer', { value: { types: ['Files'], files: [slowFile], items: [] } })
    dropzone.dispatchEvent(dropEvt)

    const saveBtn = await vi.waitFor(() => {
      const btn = [...container.querySelectorAll<HTMLButtonElement>('button')].find((b) =>
        b.textContent?.includes('업로드 완료 대기'),
      )
      expect(btn).toBeDefined()
      return btn!
    }, { timeout: 5000 })
    expect(saveBtn.disabled).toBe(true)

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 's', metaKey: true, bubbles: true, cancelable: true }))
    await vi.waitFor(() => {
      expect(container.textContent).toContain('이미지 업로드가 끝난 뒤 저장할 수 있습니다.')
    }, { timeout: 2000 })
    expect(fetchMock.mock.calls.some(([, init]) => init?.method === 'PUT')).toBe(false)
  })

  it('keeps unfiltered wiki pages in WikiEmbedPicker even when sidebar tag filter narrows the list', async () => {
    globalThis.fetch = makeWikiMocks()
    render(
      html`<${WikiTab} subroute="wiki" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )

    // Filter sidebar to #core only (which hides media-guide from displayedPages)
    const tagBtn = await vi.waitFor(() => {
      const btn = container.querySelector<HTMLButtonElement>('[data-testid="wiki-tag-filter"]')
      expect(btn).not.toBeNull()
      return btn!
    }, { timeout: 5000 })
    tagBtn.click()
    const coreOpt = await vi.waitFor(() => {
      const opt = container.querySelector<HTMLButtonElement>('[data-testid="wiki-tag-core"]')
      expect(opt).not.toBeNull()
      return opt!
    }, { timeout: 5000 })
    coreOpt.click()

    const editBtn = await vi.waitFor(() => {
      const btn = [...container.querySelectorAll<HTMLButtonElement>('button')].find((b) =>
        b.textContent?.includes('CAS 편집'),
      )
      expect(btn).toBeDefined()
      return btn!
    }, { timeout: 5000 })
    editBtn.click()

    const pickerTrigger = await vi.waitFor(() => {
      const btn = container.querySelector<HTMLButtonElement>('[data-testid="wiki-embed-picker-trigger"]')
      expect(btn).not.toBeNull()
      return btn!
    }, { timeout: 5000 })
    pickerTrigger.click()

    await vi.waitFor(() => {
      expect(container.querySelector('[data-testid="wiki-embed-option-wiki-media-guide"]')).not.toBeNull()
    }, { timeout: 5000 })
  })
})
