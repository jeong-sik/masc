// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { waitFor } from '@testing-library/preact'
import { axe } from 'jest-axe'
import { clearWorkspaceMediaCache } from '../../lib/workspace-media-cache'
import { MarkdownContent } from './markdown-renderer'

const PNG_1X1 = Uint8Array.from(atob(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII=',
), byte => byte.charCodeAt(0))

describe('MarkdownContent a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    clearWorkspaceMediaCache()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('renders plain text accessibly', async () => {
    render(html`<${MarkdownContent} text="Hello world" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders heading accessibly', async () => {
    render(html`<${MarkdownContent} text="# Title" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders link with target and rel', async () => {
    render(html`<${MarkdownContent} text="[link](https://example.com)" />`, container)
    const anchor = container.querySelector('a')
    expect(anchor).not.toBeNull()
    expect(anchor?.getAttribute('target')).toBe('_blank')
    expect(anchor?.getAttribute('rel')).toBe('noopener noreferrer')
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders list accessibly', async () => {
    render(html`<${MarkdownContent} text="- one\n- two" />`, container)
    const ul = container.querySelector('ul')
    expect(ul).not.toBeNull()
    expect(ul?.querySelectorAll('li').length).toBe(2)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders table accessibly', async () => {
    render(html`<${MarkdownContent} text="| A | B |\n|---|---|\n| 1 | 2 |" />`, container)
    const table = container.querySelector('table')
    expect(table).not.toBeNull()
    expect(await axe(container)).toHaveNoViolations()
  })

  it('sanitizes script tags', async () => {
    render(html`<${MarkdownContent} text="<script>alert(1)</script>safe" />`, container)
    expect(container.querySelector('script')).toBeNull()
    expect(container.textContent).toContain('safe')
  })

  it('renders think block as details/summary', async () => {
    render(html`<${MarkdownContent} text="<think>hidden thought</think>" />`, container)
    const details = container.querySelector('details')
    expect(details).not.toBeNull()
    expect(details?.querySelector('summary')).not.toBeNull()
  })

  it('renders hydrated workspace media and structured wiki/artifact embed cards accessibly', async () => {
    vi.stubGlobal('IntersectionObserver', undefined)
    vi.stubGlobal('URL', Object.assign(URL, {
      createObjectURL: vi.fn(() => 'blob:a11y-media-1'),
      revokeObjectURL: vi.fn(),
    }))
    vi.stubGlobal('fetch', vi.fn(() =>
      Promise.resolve(new Response(PNG_1X1, { status: 200, headers: { 'Content-Type': 'image/png' } })),
    ))

    const sha = 'e'.repeat(64)
    const artId = `artifact-${'1'.repeat(32)}`
    render(html`<${MarkdownContent} document text=${`![[media:${sha}|아키텍처 도식]]\n\n![[wiki:design-doc|설계 문서]]\n\n![[artifact:${artId}|벤치마크]]`} />`, container)

    await waitFor(() => {
      expect(container.querySelector('.masc-media-img')).not.toBeNull()
    })
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders media error fallback accessibly', async () => {
    vi.stubGlobal('IntersectionObserver', undefined)
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(new Response(null, { status: 404 }))))

    const sha = 'f'.repeat(64)
    render(html`<${MarkdownContent} document text=${`![missing](/api/v1/media/${sha})`} />`, container)

    await waitFor(() => {
      expect(container.querySelector('.masc-media-retry')).not.toBeNull()
    })
    expect(await axe(container)).toHaveNoViolations()
  })
})
