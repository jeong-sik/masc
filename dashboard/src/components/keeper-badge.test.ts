// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { h, render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import {
  authSession,
  bumpSessionEpoch,
  resetAuthStateForTests,
  setSingleUserToken,
} from '../core/auth'
import {
  loadAuthenticatedPortrait,
  resetPortraitCacheForTests,
} from '../lib/portrait-cache'
import { KeeperBadge, kSlot, kSigil, keeperPortraitUrl } from './keeper-badge'

describe('kSlot', () => {
  it('returns deterministic slot 1..12 for unknown ids', () => {
    const slot = kSlot('unknown-keeper-7')
    expect(slot).toBeGreaterThanOrEqual(1)
    expect(slot).toBeLessThanOrEqual(12)
    expect(kSlot('unknown-keeper-7')).toBe(slot)
  })

  it('distributes 100 random ids across at least 8 of 12 slots', () => {
    const seen = new Set<number>()
    for (let i = 0; i < 100; i++) seen.add(kSlot(`id-${i}`))
    expect(seen.size).toBeGreaterThanOrEqual(8)
  })
})

describe('kSigil', () => {
  it('extracts first + last segment initials for hyphenated ids without family collisions', () => {
    expect(kSigil('foo-bar')).toBe('FB')
    expect(kSigil('code-reviewer-sister')).toBe('CS')
    expect(kSigil('code-reviewer-brother')).toBe('CB')
    expect(kSigil('code-reviewer-father')).toBe('CF')
    expect(kSigil('code-reviewer-uncle')).toBe('CU')
    expect(kSigil('e-masc-the-leader')).toBe('EL')
    expect(kSigil('e-masc-the-scribe')).toBe('ES')
    expect(kSigil('alpha-beta-gamma')).toBe('AG')
  })

  it('falls back to first 2 letters for non-hyphenated ids', () => {
    expect(kSigil('agentcode')).toBe('AG')
    expect(kSigil('providerf')).toBe('PR')
  })

  it('uppercases lowercase ids', () => {
    expect(kSigil('alice')).toBe('AL')
  })

  it('strips non-alphanumeric chars before deriving', () => {
    expect(kSigil('ab.cd')).toBe('AB')
    expect(kSigil('foo!bar')).toBe('FO')
  })
})

describe('KeeperBadge & authenticated portrait cache', () => {
  let container: HTMLDivElement
  const origFetch = globalThis.fetch

  beforeEach(() => {
    resetAuthStateForTests()
    resetPortraitCacheForTests()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    globalThis.fetch = origFetch
    vi.restoreAllMocks()
    resetPortraitCacheForTests()
    resetAuthStateForTests()
  })

  it('renders a soft-tinted chip with collision-free sigil and slot class', () => {
    render(h(KeeperBadge, { id: 'code-reviewer-sister' }), container)
    const chip = container.querySelector('.kb-chip')
    expect(chip).not.toBeNull()
    expect(chip?.classList.contains(`kb-slot-${kSlot('code-reviewer-sister')}`)).toBe(true)
    expect(container.querySelector('.kb-sigil')?.textContent).toBe('CS')
    expect(container.querySelector('.kb-label')?.textContent).toBe('code-reviewer-sister')
  })

  it('fetches portrait with Authorization Bearer in single_user mode, caches blob URL, revokes on epoch bump, and falls back to sigil on error', async () => {
    setSingleUserToken('tok-portrait-test')
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }

    const createObjSpy = vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:keeper-portrait-1')
    const revokeObjSpy = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {})
    const fetchMock = vi.fn(async () => new Response(new Blob(['png-bytes'], { type: 'image/png' }), {
      status: 200,
      headers: { 'Content-Type': 'image/png' },
    }))
    globalThis.fetch = fetchMock as unknown as typeof fetch

    render(h(KeeperBadge, { id: 'e-masc-the-leader', portrait: true, size: 'lg' }), container)

    await waitFor(() => {
      const img = container.querySelector('img.kb-portrait') as HTMLImageElement | null
      expect(img).not.toBeNull()
      expect(img?.getAttribute('src')).toBe('blob:keeper-portrait-1')
      expect(img?.getAttribute('data-portrait-url')).toBe(keeperPortraitUrl('e-masc-the-leader', 64))
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer tok-portrait-test')
    expect(init.credentials).toBe('same-origin')
    expect(createObjSpy).toHaveBeenCalledTimes(1)

    // Subsequent load hits cache without re-fetching
    const cachedUrl = await loadAuthenticatedPortrait(keeperPortraitUrl('e-masc-the-leader', 64))
    expect(cachedUrl).toBe('blob:keeper-portrait-1')
    expect(fetchMock).toHaveBeenCalledTimes(1)

    // Image error falls back cleanly to sigil EL
    const img = container.querySelector('img.kb-portrait') as HTMLImageElement
    fireEvent.error(img)
    await waitFor(() => {
      expect(container.querySelector('img.kb-portrait')).toBeNull()
      expect(container.querySelector('.kb-sigil')?.textContent).toBe('EL')
    })

    // Session epoch bump revokes cached blob URLs
    bumpSessionEpoch()
    expect(revokeObjSpy).toHaveBeenCalledWith('blob:keeper-portrait-1')
  })

  it('omits Authorization Bearer in multi_account mode and caches 404/401 misses without retry spam', async () => {
    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'acc-1',
      email: 'ops@example.com',
      displayName: 'Ops',
      role: 'admin',
      csrfToken: 'csrf-1',
      authMethods: { google: true, github: false, dev_token: false },
      workspaceId: 'default',
    }

    const fetchMock = vi.fn(async () => new Response('not found', { status: 404 }))
    const url = keeperPortraitUrl('codex-mcp-client', 64)

    const first = await loadAuthenticatedPortrait(url, fetchMock as unknown as typeof fetch)
    const second = await loadAuthenticatedPortrait(url, fetchMock as unknown as typeof fetch)
    expect(first).toBeNull()
    expect(second).toBeNull()
    expect(fetchMock).toHaveBeenCalledTimes(1)

    const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect((init.headers as Record<string, string>).Authorization).toBeUndefined()
    expect(init.credentials).toBe('same-origin')
  })
})
