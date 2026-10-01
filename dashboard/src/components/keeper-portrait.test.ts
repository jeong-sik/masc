import { readKeeperPortrait, type KeeperPortraitReading } from '../api/schemas/keeper-portrait'
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { clearStoredToken, setStoredToken } from '../api/core'
import { KeeperPortrait, keeperPortraitUrl, PORTRAIT_MAX_PX, PORTRAIT_MIN_PX } from './keeper-portrait'

describe('keeperPortraitUrl', () => {
  it('asks for twice the drawn size', () => {
    expect(keeperPortraitUrl('wick-tester', 32)).toBe('/api/v1/keepers/wick-tester/portrait.png?size=64')
  })

  it('stays inside the sizes the server accepts', () => {
    expect(keeperPortraitUrl('a', 1)).toBe(`/api/v1/keepers/a/portrait.png?size=${PORTRAIT_MIN_PX}`)
    expect(keeperPortraitUrl('a', 4000)).toBe(`/api/v1/keepers/a/portrait.png?size=${PORTRAIT_MAX_PX}`)
  })

  it('encodes the name as one path segment', () => {
    expect(keeperPortraitUrl('a/b c', 32)).toBe('/api/v1/keepers/a%2Fb%20c/portrait.png?size=64')
  })
})

const ready: KeeperPortraitReading = { state: 'ready', equipment: { face: 'bare_face', neck: 'bare_neck', head: 'bare_head', hand: 'empty_hand', base: 'no_dish' } }

const png = () => new Response(new Blob([new Uint8Array([137, 80, 78, 71])], { type: 'image/png' }), { status: 200 })
const refused = (status: number) => new Response('{"error":"refused"}', { status })

describe('KeeperPortrait', () => {
  let container: HTMLDivElement
  let created: string[]
  let revoked: string[]
  const originalCreate = URL.createObjectURL
  const originalRevoke = URL.revokeObjectURL

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    created = []
    revoked = []
    URL.createObjectURL = () => {
      const url = `blob:portrait-${created.length + 1}`
      created.push(url)
      return url
    }
    URL.revokeObjectURL = (url: string) => { revoked.push(url) }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    URL.createObjectURL = originalCreate
    URL.revokeObjectURL = originalRevoke
    clearStoredToken()
    vi.unstubAllGlobals()
  })

  const fallback = html`<span data-testid="fallback">KB</span>`
  const portrait = (name: string, reading: KeeperPortraitReading = ready) =>
    html`<${KeeperPortrait} name=${name} reading=${reading} sizePx=${40} fallback=${fallback} />`
  const shown = () => container.querySelector('img[data-testid="keeper-portrait"]') as HTMLImageElement | null

  it('requests an authenticated accessory preview and restores the current portrait', async () => {
    setStoredToken('portrait-preview-token')
    const fetchMock = vi.fn(async (_path: string, _init?: RequestInit) => png())
    vi.stubGlobal('fetch', fetchMock)
    render(html`<${KeeperPortrait} name="wick-tester" reading=${ready} sizePx=${40} previewItem="glasses" fallback=${fallback} />`, container)
    await waitFor(() => expect(shown()?.getAttribute('src')).toBe('blob:portrait-1'))
    expect(fetchMock.mock.calls[0]?.[0]).toBe(keeperPortraitUrl('wick-tester', 40, ready.equipment, 'glasses'))
    expect(new Headers(fetchMock.mock.calls[0]?.[1]?.headers).get('Authorization')).toBe('Bearer portrait-preview-token')
    render(portrait('wick-tester'), container)
    await waitFor(() => expect(shown()?.getAttribute('src')).toBe('blob:portrait-2'))
    expect(fetchMock.mock.calls[1]?.[0]).toBe(keeperPortraitUrl('wick-tester', 40, ready.equipment))
    expect(revoked).toEqual(['blob:portrait-1'])
  })

  it('reserves its box while the portrait is on its way', () => {
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(() => {})))
    render(portrait('wick-tester'), container)
    const box = container.querySelector('[data-testid="keeper-portrait-loading"]') as HTMLElement
    expect(box.style.width).toBe('40px')
    expect(box.style.height).toBe('40px')
    expect(shown()).toBeNull()
    expect(container.querySelector('[data-testid="fallback"]')).toBeNull()
  })

  it('asks with the dashboard token and shows the bytes through an object URL', async () => {
    setStoredToken('portrait-read-token')
    const fetchMock = vi.fn(async (_path: string, _init?: RequestInit) => png())
    vi.stubGlobal('fetch', fetchMock)
    render(portrait('wick-tester'), container)
    await waitFor(() => expect(shown()).not.toBeNull())

    const [path, init] = fetchMock.mock.calls[0]!
    expect(path).toBe(keeperPortraitUrl('wick-tester', 40, ready.equipment))
    expect(new Headers(init?.headers).get('Authorization')).toBe('Bearer portrait-read-token')
    expect(init?.cache).toBe('no-cache')
    const img = shown()!
    expect(img.getAttribute('src')).toBe('blob:portrait-1')
    expect(img.getAttribute('alt')).toBe('')
    expect(img.getAttribute('width')).toBe('40')
    expect(img.getAttribute('height')).toBe('40')
  })

  it('draws the fallback when the server refuses, asks once, and asks again when opened again', async () => {
    const fetchMock = vi.fn(async () => refused(401))
    vi.stubGlobal('fetch', fetchMock)
    render(portrait('wick-tester'), container)
    await waitFor(() => expect(container.querySelector('[data-testid="fallback"]')).not.toBeNull())
    await new Promise(resolve => setTimeout(resolve, 20))
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(created).toEqual([])

    render(null, container)
    fetchMock.mockImplementation(async () => png())
    render(portrait('wick-tester'), container)
    await waitFor(() => expect(shown()).not.toBeNull())
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('refuses a pending A image when the server read B, without memoizing B after equipment returns to A', async () => {
    let complete!: (response: Response) => void
    const fetchMock = vi.fn((_path: string, _init?: RequestInit) => new Promise<Response>(resolve => { complete = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    render(portrait('wick-tester'), container)
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
    const path = fetchMock.mock.calls[0]![0]
    expect(JSON.parse(new URL(path, 'http://fixture.invalid').searchParams.get('expected_equipment')!)).toEqual(ready.equipment)
    // Current equipment B at the route read causes conflict, even if it returns
    // to A before the still-observed A roster renders again.
    complete(refused(409))
    await waitFor(() => expect(container.querySelector('[data-testid="keeper-portrait-refused"]')).not.toBeNull())
    expect(container.querySelector('[data-testid="keeper-portrait-refused"]')?.getAttribute('title')).toContain('장비 관측이 변경')
    render(portrait('wick-tester', { ...ready }), container)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(shown()).toBeNull()
    expect(created).toEqual([])
    render(null, container)
    fetchMock.mockImplementation(async () => png())
    render(portrait('wick-tester'), container)
    await waitFor(() => expect(shown()?.getAttribute('src')).toBe('blob:portrait-1'))
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('draws the fallback when the bytes are not an image it can show', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => png()))
    render(portrait('wick-tester'), container)
    await waitFor(() => expect(shown()).not.toBeNull())
    shown()!.dispatchEvent(new Event('error'))
    await waitFor(() => expect(container.querySelector('[data-testid="fallback"]')).not.toBeNull())
    expect(shown()).toBeNull()
  })

  it('revokes each object URL when the keeper changes and when it unmounts', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => png()))
    render(portrait('wick-tester'), container)
    await waitFor(() => expect(shown()?.getAttribute('src')).toBe('blob:portrait-1'))

    render(portrait('wick-other'), container)
    await waitFor(() => expect(shown()?.getAttribute('src')).toBe('blob:portrait-2'))
    expect(revoked).toEqual(['blob:portrait-1'])

    render(null, container)
    expect(revoked).toEqual(['blob:portrait-1', 'blob:portrait-2'])
  })

  it('refreshes an open Keeper on equipment change and removes stale pictures on failure', async () => {
    const fetchMock = vi.fn(async () => png())
    vi.stubGlobal('fetch', fetchMock)
    render(portrait('wick-tester'), container)
    await waitFor(() => expect(shown()?.getAttribute('src')).toBe('blob:portrait-1'))
    const equipped = readKeeperPortrait({ state: 'ready', equipment: { ...ready.equipment, head: 'crown' } })
    render(portrait('wick-tester', equipped), container)
    await waitFor(() => expect(shown()?.getAttribute('src')).toBe('blob:portrait-2'))
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(revoked).toEqual(['blob:portrait-1'])
    render(portrait('wick-tester', readKeeperPortrait({ state: 'unavailable', reason: 'ledger unreadable' })), container)
    await waitFor(() => expect(revoked).toEqual(['blob:portrait-1', 'blob:portrait-2']))
    expect(shown()).toBeNull()
    expect(container.querySelector('[data-testid="keeper-portrait-unavailable"]')?.getAttribute('title')).toBe('ledger unreadable')
    expect(fetchMock).toHaveBeenCalledTimes(2)
    let recover: (response: Response) => void = () => {}
    fetchMock.mockImplementationOnce(() => new Promise<Response>(resolve => { recover = resolve }))
    render(portrait('wick-tester', equipped), container)
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(3))
    expect(shown()).toBeNull()
    expect(container.querySelector('[data-testid="keeper-portrait-loading"]')).not.toBeNull()
    recover(png())
    await waitFor(() => expect(shown()?.getAttribute('src')).toBe('blob:portrait-3'))
  })

  it('does not manufacture a picture for missing or malformed equipment', () => {
    const fetchMock = vi.fn(async () => png())
    vi.stubGlobal('fetch', fetchMock)
    render(portrait('wick-tester', readKeeperPortrait(undefined)), container)
    expect(container.querySelector('[data-testid="keeper-portrait-unavailable"]')).not.toBeNull()
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('abandons a request still on its way when it unmounts', async () => {
    let signal: AbortSignal | undefined
    let answer: (response: Response) => void = () => {}
    const fetchMock = vi.fn((_path: string, init?: RequestInit) => {
      signal = init?.signal ?? undefined
      return new Promise<Response>(resolve => { answer = resolve })
    })
    vi.stubGlobal('fetch', fetchMock)
    render(portrait('wick-tester'), container)
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
    render(null, container)
    expect(signal?.aborted).toBe(true)
    answer(png())
    await new Promise(resolve => setTimeout(resolve, 20))
    expect(created).toEqual([])
  })
})
