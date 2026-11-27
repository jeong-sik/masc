import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { authSession, setSingleUserToken, wipeTransientSecrets } from '../../core/auth'
import { RichComposer } from './rich-composer'

const VALID_SHA = 'c'.repeat(64)
const PNG_BYTES = new Uint8Array([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
])
const SVG_BYTES = new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"></svg>')

async function flushUi(ticks = 6): Promise<void> {
  for (let i = 0; i < ticks; i += 1) {
    await new Promise((r) => setTimeout(r, 0))
  }
}

vi.mock('../../api/link-previews', () => ({
  fetchLinkPreviews: vi.fn().mockResolvedValue({}),
}))

vi.mock('./markdown', () => ({
  Markdown: function Markdown(props: any) {
    return props.text
  },
}))

describe('RichComposer', () => {
  beforeEach(() => {
    wipeTransientSecrets()
    authSession.value = { kind: 'probing' }
  })

  afterEach(() => {
    wipeTransientSecrets()
    vi.restoreAllMocks()
  })

  it('renders write and preview tabs', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn() }), container)
    expect(container.textContent).toContain('Write')
    expect(container.textContent).toContain('Preview')
    expect(container.querySelectorAll('button.rich-composer-tab')).toHaveLength(2)
  })

  it('defaults to write mode showing textarea', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: 'hello', onValueChange: vi.fn() }), container)
    const ta = container.querySelector('textarea')
    expect(ta).not.toBeNull()
    expect(ta?.value).toBe('hello')
  })

  it('calls onValueChange on textarea input', () => {
    const onValueChange = vi.fn()
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange }), container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    ta.value = 'new text'
    ta.dispatchEvent(new Event('input'))
    expect(onValueChange).toHaveBeenCalledWith('new text')
  })

  it('switches to preview mode on preview tab click', async () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '# heading', onValueChange: vi.fn() }), container)
    const previewBtn = Array.from(container.querySelectorAll('button')).find((b) => b.textContent?.includes('Preview'))
    previewBtn?.click()
    await new Promise((r) => setTimeout(r, 10))
    expect(container.querySelector('textarea')).toBeNull()
    expect(container.textContent).toContain('heading')
  })

  it('shows empty preview message when value is empty', async () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn() }), container)
    const previewBtn = Array.from(container.querySelectorAll('button')).find((b) => b.textContent?.includes('Preview'))
    previewBtn?.click()
    await new Promise((r) => setTimeout(r, 10))
    expect(container.textContent).toContain('미리볼 내용이 아직 없습니다')
  })

  it('shows empty preview message when value is whitespace only', async () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '   ', onValueChange: vi.fn() }), container)
    const previewBtn = Array.from(container.querySelectorAll('button')).find((b) => b.textContent?.includes('Preview'))
    previewBtn?.click()
    await new Promise((r) => setTimeout(r, 10))
    expect(container.textContent).toContain('미리볼 내용이 아직 없습니다')
  })

  it('respects placeholder prop', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn(), placeholder: 'Type here' }), container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    expect(ta?.getAttribute('placeholder')).toBe('Type here')
  })

  it('respects rows prop', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn(), rows: 10 }), container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    expect(ta?.getAttribute('rows')).toBe('10')
  })

  it('respects disabled prop on tabs', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn(), disabled: true }), container)
    const buttons = container.querySelectorAll('button')
    expect(Array.from(buttons).every((b) => b.hasAttribute('disabled'))).toBe(true)
  })

  it('renders helpText when provided', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn(), helpText: 'some help' }), container)
    expect(container.textContent).toContain('some help')
  })

  it('renders ariaLabel on textarea', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn(), ariaLabel: 'Message body' }), container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    expect(ta?.getAttribute('aria-label')).toBe('Message body')
  })

  it('switches back to write mode on write tab click', async () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: 'text', onValueChange: vi.fn() }), container)
    const previewBtn = Array.from(container.querySelectorAll('button')).find((b) => b.textContent?.includes('Preview'))
    previewBtn?.click()
    await new Promise((r) => setTimeout(r, 10))
    const writeBtn = Array.from(container.querySelectorAll('button')).find((b) => b.textContent?.includes('Write'))
    writeBtn?.click()
    await new Promise((r) => setTimeout(r, 10))
    expect(container.querySelector('textarea')).not.toBeNull()
  })

  it('uploads pasted raster image via POST /api/v1/media and inserts Markdown at cursor', async () => {
    setSingleUserToken('composer-admin-token')
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

    const fetchMock = vi.fn<typeof fetch>().mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          path: `/api/v1/media/${VALID_SHA}`,
          sha256: VALID_SHA,
          mime: 'image/png',
          bytes: PNG_BYTES.byteLength,
          width: 64,
          height: 64,
        }),
        { status: 201, headers: { 'Content-Type': 'application/json' } },
      ),
    )
    globalThis.fetch = fetchMock

    const onValueChange = vi.fn()
    const container = document.createElement('div')
    document.body.appendChild(container)
    render(h(RichComposer, { value: 'Hello ', onValueChange }), container)

    const dropzone = container.querySelector('[data-testid="rich-composer-dropzone"]')!
    const pngFile = new File([PNG_BYTES], 'board-shot.png', { type: 'image/png' })
    const pasteEvent = new Event('paste', { bubbles: true, cancelable: true })
    Object.defineProperty(pasteEvent, 'clipboardData', {
      value: { files: [pngFile], items: [], types: ['Files'] },
    })
    dropzone.dispatchEvent(pasteEvent)
    await flushUi(8)

    expect(pasteEvent.defaultPrevented).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(onValueChange).toHaveBeenCalledWith(`Hello ![board-shot](/api/v1/media/${VALID_SHA})`)
    render(null, container)
    document.body.removeChild(container)
  })

  it('rejects dropped SVG image with typed alert and onUploadError callback without network call', async () => {
    const fetchMock = vi.fn<typeof fetch>()
    globalThis.fetch = fetchMock
    const onUploadError = vi.fn()
    const container = document.createElement('div')
    document.body.appendChild(container)
    render(h(RichComposer, { value: '', onValueChange: vi.fn(), onUploadError }), container)

    const dropzone = container.querySelector('[data-testid="rich-composer-dropzone"]')!
    const svgFile = new File([SVG_BYTES], 'bad.svg', { type: 'image/svg+xml' })
    const dropEvent = new Event('drop', { bubbles: true, cancelable: true })
    Object.defineProperty(dropEvent, 'dataTransfer', {
      value: { files: [svgFile], items: [], types: ['Files'] },
    })
    dropzone.dispatchEvent(dropEvent)
    await flushUi(6)

    expect(fetchMock).not.toHaveBeenCalled()
    expect(onUploadError).toHaveBeenCalledWith(expect.objectContaining({ kind: 'svg_not_allowed' }))
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('SVG')
    render(null, container)
    document.body.removeChild(container)
  })

  it('leaves plain-text paste untouched without calling fetch', async () => {
    const fetchMock = vi.fn<typeof fetch>()
    globalThis.fetch = fetchMock
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn() }), container)

    const dropzone = container.querySelector('[data-testid="rich-composer-dropzone"]')!
    const pasteEvent = new Event('paste', { bubbles: true, cancelable: true })
    Object.defineProperty(pasteEvent, 'clipboardData', {
      value: { files: [], items: [], types: ['text/plain'] },
    })
    dropzone.dispatchEvent(pasteEvent)
    await flushUi(4)

    expect(pasteEvent.defaultPrevented).toBe(false)
    expect(fetchMock).not.toHaveBeenCalled()
  })
})
