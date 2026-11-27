// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  authSession,
  bumpSessionEpoch,
  currentSessionEpoch,
  setSingleUserToken,
} from '../core/auth'
import {
  WORKSPACE_MEDIA_PREFIX,
  extractWorkspaceMediaSha256,
  isValidPublishedArtifactId,
  isValidWikiSlug,
  isWorkspaceMediaPath,
  isWorkspaceMediaSha256,
  isWorkspaceRasterMime,
  parseObsidianEmbed,
  parseWorkspaceRasterMime,
  workspaceMediaPath,
} from './keeper-media'
import {
  SANDBOX_HTML_MAX_MEDIA_ITEMS,
  WORKSPACE_MEDIA_CACHE_MAX_ENTRIES,
  acquireWorkspaceMediaDataUrl,
  acquireWorkspaceMediaObjectUrl,
  clearWorkspaceMediaCache,
  getWorkspaceMediaCacheStats,
  hydrateSandboxedHtmlMedia,
} from './workspace-media-cache'

const PNG_1X1 = Uint8Array.from(
  atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII='),
  (byte) => byte.charCodeAt(0),
)

function makeSha(char: string, index = 0): string {
  const hex = index.toString(16).padStart(4, '0')
  return `${hex}${char.repeat(60)}`
}

function makePath(char: string, index = 0): string {
  return `${WORKSPACE_MEDIA_PREFIX}${makeSha(char, index)}`
}

function makePngResponse(bytes: Uint8Array = PNG_1X1, contentType = 'image/png'): Response {
  const copy = new Uint8Array(bytes.byteLength)
  copy.set(bytes)
  return new Response(copy, {
    status: 200,
    headers: { 'Content-Type': contentType },
  })
}

const DEFAULT_AUTH_METHODS = Object.freeze({ google: false, github: false, dev_token: false })

describe('keeper-media validators & unified embed parser', () => {
  it('validates canonical workspace media paths and sha256 tokens strictly', () => {
    const sha = 'a'.repeat(64)
    const path = `${WORKSPACE_MEDIA_PREFIX}${sha}`
    expect(isWorkspaceMediaSha256(sha)).toBe(true)
    expect(isWorkspaceMediaPath(path)).toBe(true)
    expect(workspaceMediaPath(sha)).toBe(path)
    expect(extractWorkspaceMediaSha256(path)).toBe(sha)

    // Reject uppercase, wrong length, query string, path traversal
    expect(isWorkspaceMediaPath(`${WORKSPACE_MEDIA_PREFIX}${'A'.repeat(64)}`)).toBe(false)
    expect(isWorkspaceMediaPath(`${WORKSPACE_MEDIA_PREFIX}${'a'.repeat(63)}`)).toBe(false)
    expect(isWorkspaceMediaPath(`${path}?foo=bar`)).toBe(false)
    expect(isWorkspaceMediaPath('/api/v1/media/../etc/passwd')).toBe(false)
    expect(workspaceMediaPath('bad')).toBeNull()
    expect(extractWorkspaceMediaSha256('https://example.com/x.png')).toBeNull()
  })

  it('enforces closed raster MIME union and rejects SVG', () => {
    expect(parseWorkspaceRasterMime('image/png')).toBe('image/png')
    expect(parseWorkspaceRasterMime('image/jpeg; charset=binary')).toBe('image/jpeg')
    expect(parseWorkspaceRasterMime('image/jpg')).toBe('image/jpeg')
    expect(parseWorkspaceRasterMime('IMAGE/GIF')).toBe('image/gif')
    expect(parseWorkspaceRasterMime('image/webp')).toBe('image/webp')
    expect(isWorkspaceRasterMime('image/png')).toBe(true)

    expect(parseWorkspaceRasterMime('image/svg+xml')).toBeNull()
    expect(isWorkspaceRasterMime('image/svg+xml')).toBe(false)
    expect(parseWorkspaceRasterMime('text/html')).toBeNull()
    expect(parseWorkspaceRasterMime('application/octet-stream')).toBeNull()
  })

  it('validates wiki slugs and published artifact IDs matching OCaml contracts', () => {
    expect(isValidWikiSlug('architecture-notes')).toBe(true)
    expect(isValidWikiSlug('a1')).toBe(true)
    expect(isValidWikiSlug('index')).toBe(false)
    expect(isValidWikiSlug('log')).toBe(false)
    expect(isValidWikiSlug('-leading')).toBe(false)
    expect(isValidWikiSlug('trailing-')).toBe(false)
    expect(isValidWikiSlug('UpperCase')).toBe(false)
    expect(isValidWikiSlug('../escape')).toBe(false)

    const validArtifact = `artifact-${'0123456789abcdef'.repeat(2)}`
    expect(isValidPublishedArtifactId(validArtifact)).toBe(true)
    expect(isValidPublishedArtifactId('artifact-short')).toBe(false)
    expect(isValidPublishedArtifactId(`artifact-${'A'.repeat(32)}`)).toBe(false)
  })

  it('parses Obsidian embed grammar into closed WorkspaceEmbed variants', () => {
    const sha = 'b'.repeat(64)
    const artId = `artifact-${'c'.repeat(32)}`

    expect(parseObsidianEmbed(`media:${sha}|Architecture diagram`)).toEqual({
      kind: 'media',
      sha256: sha,
      path: `${WORKSPACE_MEDIA_PREFIX}${sha}`,
      caption: 'Architecture diagram',
      raw: `![[media:${sha}|Architecture diagram]]`,
    })

    expect(parseObsidianEmbed('wiki:design-doc|Design')).toEqual({
      kind: 'wiki',
      slug: 'design-doc',
      label: 'Design',
      raw: '![[wiki:design-doc|Design]]',
    })

    expect(parseObsidianEmbed('design-doc')).toEqual({
      kind: 'wiki',
      slug: 'design-doc',
      label: null,
      raw: '![[design-doc]]',
    })

    expect(parseObsidianEmbed(`artifact:${artId}|Bench`)).toEqual({
      kind: 'artifact',
      id: artId,
      label: 'Bench',
      raw: `![[artifact:${artId}|Bench]]`,
    })

    expect(parseObsidianEmbed('media:not-64-hex').kind).toBe('invalid')
    expect(parseObsidianEmbed('wiki:index').kind).toBe('invalid')
    expect(parseObsidianEmbed('artifact:bad-id').kind).toBe('invalid')
    expect(parseObsidianEmbed('Bad_Slug').kind).toBe('invalid')

    // Unknown scheme must NEVER be coerced to wiki slug
    expect(parseObsidianEmbed('javascript:alert(1)')).toEqual({
      kind: 'unsupported',
      scheme: 'javascript',
      rawTarget: 'javascript:alert(1)',
      label: null,
      raw: '![[javascript:alert(1)]]',
    })
  })
})

describe('workspace-media-cache', () => {
  let blobSeq = 0
  let createObjectUrlSpy: ReturnType<typeof vi.fn<(obj: Blob | MediaSource) => string>>
  let revokeObjectUrlSpy: ReturnType<typeof vi.fn<(url: string) => void>>

  beforeEach(() => {
    blobSeq = 0
    clearWorkspaceMediaCache()
    setSingleUserToken(null)
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: false,
      role: 'admin',
      canTokenAdmin: true,
      canTokenRead: true,
      authMethods: DEFAULT_AUTH_METHODS,
      workspaceId: 'default',
    }
    createObjectUrlSpy = vi.fn((_obj: Blob | MediaSource) => `blob:test-media-${++blobSeq}`)
    revokeObjectUrlSpy = vi.fn((_url: string) => undefined)
    vi.stubGlobal('URL', Object.assign(URL, {
      createObjectURL: createObjectUrlSpy,
      revokeObjectURL: revokeObjectUrlSpy,
    }))
  })

  afterEach(() => {
    clearWorkspaceMediaCache()
    setSingleUserToken(null)
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('deduplicates concurrent in-flight fetches and shares one object URL with ref-counting', async () => {
    const path = makePath('a')
    let resolveFetch!: (res: Response) => void
    const fetchMock = vi.fn<typeof globalThis.fetch>(
      () => new Promise<Response>((resolve) => { resolveFetch = resolve }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const p1 = acquireWorkspaceMediaObjectUrl(path)
    const p2 = acquireWorkspaceMediaObjectUrl(path)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(getWorkspaceMediaCacheStats().inFlight).toBe(1)

    resolveFetch(makePngResponse())
    const [r1, r2] = await Promise.all([p1, p2])
    expect(r1.ok).toBe(true)
    expect(r2.ok).toBe(true)
    if (!r1.ok || !r2.ok) return

    expect(r1.value.url).toBe('blob:test-media-1')
    expect(r2.value.url).toBe('blob:test-media-1')
    expect(createObjectUrlSpy).toHaveBeenCalledTimes(1)
    expect(getWorkspaceMediaCacheStats()).toMatchObject({ entries: 1, activeLeases: 2, inFlight: 0 })

    // Releasing twice on same handle is idempotent
    r1.value.release()
    r1.value.release()
    expect(getWorkspaceMediaCacheStats().activeLeases).toBe(1)
    r2.value.release()
    expect(getWorkspaceMediaCacheStats().activeLeases).toBe(0)
  })

  it('detaches an aborted waiter without cancelling sibling callers, and aborts network when all waiters abort', async () => {
    const path = makePath('b')
    let capturedSignal: AbortSignal | undefined
    let resolveFetch!: (res: Response) => void
    const fetchMock = vi.fn<typeof globalThis.fetch>((_input, init) => {
      capturedSignal = init?.signal ?? undefined
      return new Promise<Response>((resolve) => { resolveFetch = resolve })
    })
    vi.stubGlobal('fetch', fetchMock)

    const c1 = new AbortController()
    const c2 = new AbortController()
    const p1 = acquireWorkspaceMediaObjectUrl(path, { signal: c1.signal })
    const p2 = acquireWorkspaceMediaObjectUrl(path, { signal: c2.signal })

    c1.abort()
    const r1 = await p1
    expect(r1).toEqual({ ok: false, error: { kind: 'aborted' } })
    expect(capturedSignal?.aborted).toBe(false)

    resolveFetch(makePngResponse())
    const r2 = await p2
    expect(r2.ok).toBe(true)
    if (r2.ok) r2.value.release()

    // Now test aborting ALL waiters aborts the underlying fetch
    const path2 = makePath('c')
    let signal2: AbortSignal | undefined
    const fetchMock2 = vi.fn<typeof globalThis.fetch>((_input, init) => {
      signal2 = init?.signal ?? undefined
      return new Promise<Response>(() => undefined)
    })
    vi.stubGlobal('fetch', fetchMock2)

    const c3 = new AbortController()
    const p3 = acquireWorkspaceMediaObjectUrl(path2, { signal: c3.signal })
    c3.abort()
    const r3 = await p3
    expect(r3).toEqual({ ok: false, error: { kind: 'aborted' } })
    expect(signal2?.aborted).toBe(true)
    expect(getWorkspaceMediaCacheStats().inFlight).toBe(0)
  })

  it('evicts LRU entries over max count and revokes object URLs only when refCount reaches 0', async () => {
    const fetchMock = vi.fn<typeof globalThis.fetch>(() => Promise.resolve(makePngResponse()))
    vi.stubGlobal('fetch', fetchMock)

    // Pin entry 0 so LRU eviction cannot revoke its blob URL while mounted
    const first = await acquireWorkspaceMediaObjectUrl(makePath('e', 0))
    expect(first.ok).toBe(true)
    if (!first.ok) return

    // Fill remaining slots + 1 overflow (all unpinned)
    for (let i = 1; i <= WORKSPACE_MEDIA_CACHE_MAX_ENTRIES; i += 1) {
      const res = await acquireWorkspaceMediaObjectUrl(makePath('e', i))
      expect(res.ok).toBe(true)
      if (res.ok) res.value.release()
    }

    // Entry 1 (oldest unpinned) should have been evicted and revoked; entry 0 (pinned) stays alive
    expect(getWorkspaceMediaCacheStats().entries).toBe(WORKSPACE_MEDIA_CACHE_MAX_ENTRIES)
    expect(revokeObjectUrlSpy).toHaveBeenCalledWith('blob:test-media-2')
    expect(revokeObjectUrlSpy).not.toHaveBeenCalledWith(first.value.url)

    // Once entry 0 is released and cache is cleared, its URL is revoked
    first.value.release()
    clearWorkspaceMediaCache()
    expect(revokeObjectUrlSpy).toHaveBeenCalledWith(first.value.url)
  })

  it('purges entries and revokes object URLs on sessionEpoch bump (deferred until active lease releases)', async () => {
    const fetchMock = vi.fn<typeof globalThis.fetch>(() => Promise.resolve(makePngResponse()))
    vi.stubGlobal('fetch', fetchMock)

    const pUnpinned = makePath('d', 1)
    const pPinned = makePath('d', 2)
    const rUnpinned = await acquireWorkspaceMediaObjectUrl(pUnpinned)
    const rPinned = await acquireWorkspaceMediaObjectUrl(pPinned)
    expect(rUnpinned.ok && rPinned.ok).toBe(true)
    if (!rUnpinned.ok || !rPinned.ok) return

    rUnpinned.value.release()
    bumpSessionEpoch()

    // Unpinned entry from old epoch is immediately revoked; pinned entry waits for release()
    expect(getWorkspaceMediaCacheStats().entries).toBe(0)
    expect(revokeObjectUrlSpy).toHaveBeenCalledWith(rUnpinned.value.url)
    expect(revokeObjectUrlSpy).not.toHaveBeenCalledWith(rPinned.value.url)

    rPinned.value.release()
    expect(revokeObjectUrlSpy).toHaveBeenCalledWith(rPinned.value.url)
    expect(getWorkspaceMediaCacheStats().activeLeases).toBe(0)
  })

  it('sends Bearer token in single-user mode and omits Authorization in multi-account mode', async () => {
    const seenHeaders: Array<HeadersInit | undefined> = []
    const fetchMock = vi.fn<typeof globalThis.fetch>((_input, init) => {
      seenHeaders.push(init?.headers)
      return Promise.resolve(makePngResponse())
    })
    vi.stubGlobal('fetch', fetchMock)

    setSingleUserToken('secret-local-token')
    const rSingle = await acquireWorkspaceMediaObjectUrl(makePath('f', 1))
    expect(rSingle.ok).toBe(true)
    if (rSingle.ok) rSingle.value.release()
    expect(new Headers(seenHeaders[0]).get('Authorization')).toBe('Bearer secret-local-token')

    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'user-1',
      email: null,
      displayName: 'user-1',
      role: 'worker',
      csrfToken: 'csrf-1',
      authMethods: DEFAULT_AUTH_METHODS,
      workspaceId: 'ws-2',
    }
    bumpSessionEpoch()

    const rMulti = await acquireWorkspaceMediaObjectUrl(makePath('f', 2))
    expect(rMulti.ok).toBe(true)
    if (rMulti.ok) rMulti.value.release()
    expect(new Headers(seenHeaders[1]).get('Authorization')).toBeNull()
  })

  it('rejects SVG responses, oversize headers, and does not cache transient 503 failures', async () => {
    const svgPath = makePath('1', 1)
    const retryPath = makePath('1', 2)
    const fetchMock = vi.fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(new Response('<svg></svg>', { status: 200, headers: { 'Content-Type': 'image/svg+xml' } }))
      .mockResolvedValueOnce(new Response(null, { status: 503 }))
      .mockResolvedValueOnce(makePngResponse())
    vi.stubGlobal('fetch', fetchMock)

    const svgRes = await acquireWorkspaceMediaObjectUrl(svgPath)
    expect(svgRes).toEqual({
      ok: false,
      error: { kind: 'unsupported_mime', contentType: 'image/svg+xml' },
    })

    const failRes = await acquireWorkspaceMediaObjectUrl(retryPath)
    expect(failRes).toEqual({ ok: false, error: { kind: 'http_error', status: 503 } })

    const okRes = await acquireWorkspaceMediaObjectUrl(retryPath)
    expect(okRes.ok).toBe(true)
    if (okRes.ok) okRes.value.release()
    expect(fetchMock).toHaveBeenCalledTimes(3)
  })

  it('acquires inline data: URL and hydrates sandboxed HTML while preserving DOCTYPE & bounds', async () => {
    const p1 = makePath('2', 1)
    const pMissing = makePath('2', 2)
    const fetchMock = vi.fn<typeof globalThis.fetch>((input) => {
      const url = String(input)
      if (url.endsWith(p1)) return Promise.resolve(makePngResponse())
      return Promise.resolve(new Response(null, { status: 404 }))
    })
    vi.stubGlobal('fetch', fetchMock)

    const dataRes = await acquireWorkspaceMediaDataUrl(p1)
    expect(dataRes.ok).toBe(true)
    if (!dataRes.ok) return
    expect(dataRes.value.dataUrl).toMatch(/^data:image\/png;base64,/)

    const rawHtml = [
      '<!DOCTYPE html>',
      '<html><body>',
      `<img src="${p1}" alt="Chart">`,
      `<img src="${p1}" alt="Chart duplicate">`,
      `<img src="${pMissing}" alt="Missing">`,
      '<img src="/api/v1/media/not-valid" alt="Bad">',
      '<img src="https://example.test/ext.png" alt="External">',
      '<script>window.__ran = true</script>',
      '</body></html>',
    ].join('')

    const hydrated = await hydrateSandboxedHtmlMedia(rawHtml, { epoch: currentSessionEpoch() })
    expect(hydrated.ok).toBe(true)
    if (!hydrated.ok) return

    // p1 was already cached by acquireWorkspaceMediaDataUrl; only pMissing triggers fetch
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect((window as unknown as { __ran?: boolean }).__ran).toBeUndefined()
    expect(hydrated.value.resolvedCount).toBe(1)
    expect(hydrated.value.failedCount).toBe(2) // pMissing + malformed /api/v1/media/not-valid
    expect(hydrated.value.skippedCount).toBe(0)
    expect(hydrated.value.html.startsWith('<!DOCTYPE html>\n')).toBe(true)
    expect(hydrated.value.html).toContain('data:image/png;base64,')
    expect(hydrated.value.html).not.toContain(p1)
    expect(hydrated.value.html).not.toContain(pMissing)
    expect(hydrated.value.html).not.toContain('/api/v1/media/not-valid')
    expect(hydrated.value.html).toContain('https://example.test/ext.png')
  })

  it('caps sandboxed HTML media hydration at 32 unique items and strips overflow src', async () => {
    const fetchMock = vi.fn<typeof globalThis.fetch>(() => Promise.resolve(makePngResponse()))
    vi.stubGlobal('fetch', fetchMock)

    const imgs = Array.from(
      { length: SANDBOX_HTML_MAX_MEDIA_ITEMS + 3 },
      (_, i) => `<img src="${makePath('9', i)}" alt="img-${i}">`,
    ).join('')
    const hydrated = await hydrateSandboxedHtmlMedia(`<!DOCTYPE html><html><body>${imgs}</body></html>`)
    expect(hydrated.ok).toBe(true)
    if (!hydrated.ok) return

    expect(fetchMock).toHaveBeenCalledTimes(SANDBOX_HTML_MAX_MEDIA_ITEMS)
    expect(hydrated.value.resolvedCount).toBe(SANDBOX_HTML_MAX_MEDIA_ITEMS)
    expect(hydrated.value.skippedCount).toBe(3)
    expect(hydrated.value.html).not.toContain(WORKSPACE_MEDIA_PREFIX)
  })
})
