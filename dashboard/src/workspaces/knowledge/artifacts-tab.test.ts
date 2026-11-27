// @vitest-environment jsdom

import { html } from 'htm/preact'
import { cleanup, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { authSession, bumpSessionEpoch, setSingleUserToken } from '../../core/auth'
import { resourceCache } from '../../core/resource-cache'
import { clearWorkspaceMediaCache } from '../../lib/workspace-media-cache'
import { ArtifactsTab } from './artifacts-tab'

const PNG_1X1 = Uint8Array.from(atob(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII=',
), byte => byte.charCodeAt(0))

const DEFAULT_AUTH_METHODS = Object.freeze({ google: false, github: false, dev_token: false })

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function makeArtifactSummary(id: string, title: string, format: 'html' | 'markdown' = 'html') {
  return {
    id,
    revision: 1,
    title,
    summary: 'Artifact summary',
    format,
    author: 'sangsu',
    created_at: '2026-11-27T05:00:00Z',
    body: { _blob: { sha256: 'a'.repeat(64), bytes: 512 } },
    task_id: null,
    goal_id: null,
  }
}

beforeEach(() => {
  resourceCache.clearAll()
  clearWorkspaceMediaCache()
  setSingleUserToken('artifact-admin-token')
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
})

afterEach(() => {
  cleanup()
  resourceCache.clearAll()
  clearWorkspaceMediaCache()
  setSingleUserToken(null)
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

describe('ArtifactsTab sandboxed HTML media hydration', () => {
  it('gates srcDoc until workspace media resolves, keeps sandbox="", preserves DOCTYPE, and sends Bearer auth', async () => {
    const artId = `artifact-${'1'.repeat(32)}`
    const mediaPath = `/api/v1/media/${'b'.repeat(64)}`
    let resolveMedia!: (res: Response) => void
    let mediaHeaders: HeadersInit | undefined

    const fetchMock = vi.fn<typeof globalThis.fetch>((input, init) => {
      const url = String(input)
      if (url.endsWith('/api/v1/published-artifacts')) {
        return Promise.resolve(jsonResponse({
          artifacts: [makeArtifactSummary(artId, 'Visual Report', 'html')],
          diagnostics: [],
        }))
      }
      if (url.endsWith(`/api/v1/published-artifacts/${artId}`)) {
        return Promise.resolve(jsonResponse({
          artifact: makeArtifactSummary(artId, 'Visual Report', 'html'),
          content: `<!DOCTYPE html><html><body><h1>Visual</h1><img src="${mediaPath}" alt="Chart"><script>alert(1)</script></body></html>`,
          revisions: [],
        }))
      }
      if (url.endsWith(mediaPath)) {
        mediaHeaders = init?.headers
        return new Promise<Response>((resolve) => { resolveMedia = resolve })
      }
      return Promise.resolve(new Response(null, { status: 404 }))
    })
    vi.stubGlobal('fetch', fetchMock)

    const view = render(html`
      <${ArtifactsTab} subroute="artifacts" entityId=${artId} onNavigate=${vi.fn()} onInspect=${vi.fn()} />
    `)

    // While media is in flight: iframe MUST NOT mount yet (zero pre-hydration 401 flash!)
    await waitFor(() => {
      expect(view.queryByTestId('artifact-media-hydrating')).not.toBeNull()
    })
    expect(view.container.querySelector('iframe.kn-artifact-frame')).toBeNull()
    expect(new Headers(mediaHeaders).get('Authorization')).toBe('Bearer artifact-admin-token')

    // Resolve media fetch -> iframe mounts with strict sandbox="" and inline data: URI
    resolveMedia(new Response(PNG_1X1, { status: 200, headers: { 'Content-Type': 'image/png' } }))

    await waitFor(() => {
      const iframe = view.container.querySelector<HTMLIFrameElement>('iframe.kn-artifact-frame')
      expect(iframe).not.toBeNull()
      expect(iframe?.getAttribute('sandbox')).toBe('')
      const srcDoc = iframe?.getAttribute('srcdoc') ?? iframe?.srcdoc ?? ''
      expect(srcDoc.startsWith('<!DOCTYPE html>\n')).toBe(true)
      expect(srcDoc).toContain('data:image/png;base64,')
      expect(srcDoc).not.toContain(mediaPath)
    })
  })

  it('shows honest warning and strips unresolvable media src when media fetch fails', async () => {
    const artId = `artifact-${'2'.repeat(32)}`
    const missingMedia = `/api/v1/media/${'c'.repeat(64)}`

    const fetchMock = vi.fn<typeof globalThis.fetch>((input) => {
      const url = String(input)
      if (url.endsWith('/api/v1/published-artifacts')) {
        return Promise.resolve(jsonResponse({
          artifacts: [makeArtifactSummary(artId, 'Broken Img Report', 'html')],
          diagnostics: [],
        }))
      }
      if (url.endsWith(`/api/v1/published-artifacts/${artId}`)) {
        return Promise.resolve(jsonResponse({
          artifact: makeArtifactSummary(artId, 'Broken Img Report', 'html'),
          content: `<html><body><img src="${missingMedia}" alt="Missing"></body></html>`,
          revisions: [],
        }))
      }
      if (url.endsWith(missingMedia)) {
        return Promise.resolve(new Response(null, { status: 404 }))
      }
      return Promise.resolve(new Response(null, { status: 404 }))
    })
    vi.stubGlobal('fetch', fetchMock)

    const view = render(html`
      <${ArtifactsTab} subroute="artifacts" entityId=${artId} onNavigate=${vi.fn()} onInspect=${vi.fn()} />
    `)

    await waitFor(() => {
      expect(view.queryByTestId('artifact-media-warning')?.textContent).toContain('이미지 1건을 불러오지 못했습니다')
      const iframe = view.container.querySelector<HTMLIFrameElement>('iframe.kn-artifact-frame')
      expect(iframe?.getAttribute('sandbox')).toBe('')
      const srcDoc = iframe?.getAttribute('srcdoc') ?? iframe?.srcdoc ?? ''
      expect(srcDoc).not.toContain(missingMedia)
    })
  })

  it('aborts in-flight HTML media hydration cleanly when sessionEpoch bumps or component unmounts', async () => {
    const artId = `artifact-${'3'.repeat(32)}`
    const mediaPath = `/api/v1/media/${'d'.repeat(64)}`
    let mediaSignal: AbortSignal | undefined

    const fetchMock = vi.fn<typeof globalThis.fetch>((input, init) => {
      const url = String(input)
      if (url.endsWith('/api/v1/published-artifacts')) {
        return Promise.resolve(jsonResponse({
          artifacts: [makeArtifactSummary(artId, 'Slow Report', 'html')],
          diagnostics: [],
        }))
      }
      if (url.endsWith(`/api/v1/published-artifacts/${artId}`)) {
        return Promise.resolve(jsonResponse({
          artifact: makeArtifactSummary(artId, 'Slow Report', 'html'),
          content: `<html><body><img src="${mediaPath}"></body></html>`,
          revisions: [],
        }))
      }
      if (url.endsWith(mediaPath)) {
        mediaSignal = init?.signal ?? undefined
        return new Promise<Response>(() => undefined)
      }
      return Promise.resolve(new Response(null, { status: 404 }))
    })
    vi.stubGlobal('fetch', fetchMock)

    const view = render(html`
      <${ArtifactsTab} subroute="artifacts" entityId=${artId} onNavigate=${vi.fn()} onInspect=${vi.fn()} />
    `)

    await waitFor(() => {
      expect(mediaSignal).toBeDefined()
    })
    bumpSessionEpoch()
    expect(mediaSignal?.aborted).toBe(true)
    view.unmount()
  })
})
