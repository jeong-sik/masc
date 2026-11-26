// @vitest-environment jsdom

import { cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { currentSessionEpoch } from '../../core/auth'
import { WorkspaceChatImage } from './workspace-image'

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

it('retries a retained image in the same workspace after an HTTP 503', async () => {
  vi.stubGlobal('IntersectionObserver', undefined)
  const path = '/api/v1/media/' + 'a'.repeat(64)
  const png = Uint8Array.from(atob(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII=',
  ), byte => byte.charCodeAt(0))
  const fetch = vi.fn<typeof globalThis.fetch>()
    .mockResolvedValueOnce(new Response(null, { status: 503 }))
    .mockResolvedValueOnce(new Response(png, { headers: { 'Content-Type': 'image/png' } }))
  vi.stubGlobal('fetch', fetch)

  const view = render(html`<${WorkspaceChatImage}
    path=${path} caption="도구 출력" workspaceEpoch=${currentSessionEpoch()} />`)
  const retry = await view.findByRole('button', { name: '이미지 다시 시도' })
  expect(view.getByRole('status').textContent).toBe('이미지를 불러올 수 없습니다')
  expect(fetch).toHaveBeenCalledTimes(1)

  fireEvent.click(retry)

  const image = await view.findByRole('img', { name: '도구 출력' })
  expect(image.getAttribute('src')).toMatch(/^data:image\/png;base64,/)
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
})
