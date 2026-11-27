// @vitest-environment jsdom

import { cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { bumpSessionEpoch, currentSessionEpoch } from '../../core/auth'
import {
  clearWorkspaceMediaCache,
  getWorkspaceMediaCacheStats,
} from '../../lib/workspace-media-cache'
import { WorkspaceChatImage } from './workspace-image'

const PNG_1X1 = Uint8Array.from(atob(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII=',
), byte => byte.charCodeAt(0))

let blobSeq = 0
let revokeSpy: ReturnType<typeof vi.fn<(url: string) => void>>

beforeEach(() => {
  blobSeq = 0
  clearWorkspaceMediaCache()
  revokeSpy = vi.fn<(url: string) => void>()
  vi.stubGlobal('URL', Object.assign(URL, {
    createObjectURL: vi.fn(() => `blob:workspace-chat-${++blobSeq}`),
    revokeObjectURL: revokeSpy,
  }))
})

afterEach(() => {
  cleanup()
  clearWorkspaceMediaCache()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

it('retries a retained image in the same workspace after an HTTP 503 and renders object URL', async () => {
  vi.stubGlobal('IntersectionObserver', undefined)
  const path = '/api/v1/media/' + 'a'.repeat(64)
  const fetch = vi.fn<typeof globalThis.fetch>()
    .mockResolvedValueOnce(new Response(null, { status: 503 }))
    .mockResolvedValueOnce(new Response(PNG_1X1, { headers: { 'Content-Type': 'image/png' } }))
  vi.stubGlobal('fetch', fetch)

  const view = render(html`<${WorkspaceChatImage}
    path=${path} caption="도구 출력" workspaceEpoch=${currentSessionEpoch()} />`)
  const retry = await view.findByRole('button', { name: '이미지 다시 시도' })
  expect(view.getByRole('status').textContent).toBe('이미지를 불러올 수 없습니다')
  expect(fetch).toHaveBeenCalledTimes(1)

  fireEvent.click(retry)

  const image = await view.findByRole('img', { name: '도구 출력' })
  expect(image.getAttribute('src')).toMatch(/^blob:/)
  expect(image.getAttribute('decoding')).toBe('async')
  expect(fetch).toHaveBeenCalledTimes(2)
  expect(fetch.mock.calls.map(([url]) => String(url))).toEqual([
    window.location.origin + path,
    window.location.origin + path,
  ])

  // Clicking the loaded image opens the lightbox preview modal and Escape closes it.
  fireEvent.click(view.getByRole('button', { name: '도구 출력 크게 보기' }))
  expect(document.querySelector('[role="dialog"][aria-modal="true"]')).not.toBeNull()
  fireEvent.keyDown(document, { key: 'Escape' })
  expect(document.querySelector('[role="dialog"][aria-modal="true"]')).toBeNull()

  // Unmounting releases the ref-counted lease cleanly; epoch bump revokes the object URL.
  view.unmount()
  expect(getWorkspaceMediaCacheStats().activeLeases).toBe(0)
  bumpSessionEpoch()
  expect(revokeSpy).toHaveBeenCalledWith('blob:workspace-chat-1')
})

it('deduplicates fetches across sibling WorkspaceChatImage mounts sharing one media path', async () => {
  vi.stubGlobal('IntersectionObserver', undefined)
  const path = '/api/v1/media/' + 'b'.repeat(64)
  const fetch = vi.fn<typeof globalThis.fetch>(() =>
    Promise.resolve(new Response(PNG_1X1, { headers: { 'Content-Type': 'image/png' } })),
  )
  vi.stubGlobal('fetch', fetch)
  const epoch = currentSessionEpoch()

  const view = render(html`
    <div>
      <${WorkspaceChatImage} path=${path} caption="첫 번째" workspaceEpoch=${epoch} />
      <${WorkspaceChatImage} path=${path} caption="두 번째" workspaceEpoch=${epoch} />
    </div>
  `)

  const firstImg = await view.findByRole('img', { name: '첫 번째' })
  const secondImg = await view.findByRole('img', { name: '두 번째' })
  expect(fetch).toHaveBeenCalledTimes(1)
  expect(firstImg.getAttribute('src')).toBe(secondImg.getAttribute('src'))
  expect(getWorkspaceMediaCacheStats().activeLeases).toBe(2)

  view.unmount()
  expect(getWorkspaceMediaCacheStats().activeLeases).toBe(0)
})
