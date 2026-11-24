/**
 * Authenticated Keeper Portrait Cache (`URL.createObjectURL` + `sessionEpoch` fence).
 *
 * Browser `<img src="/api/v1/keepers/:k/portrait.png">` omits `Authorization: Bearer` in
 * `single_user` mode, causing HTTP 401 console errors on every keeper badge/card.
 * This cache loads portraits via mode-aware `fetch`:
 * - `single_user_local`: sends `Authorization: Bearer <token>` (when set) + `credentials: 'same-origin'`
 * - `multi_account_signed_in`: sends `credentials: 'same-origin'` (zero Bearer header)
 * - unauthenticated/probing sessions: returns `null` immediately (0× HTTP 401)
 * - caches `401`/`404`/non-image misses per `(sessionEpoch, sessionKey, url)` to prevent retry storms
 * - revokes all cached `blob:` URLs via `URL.revokeObjectURL` whenever `sessionEpoch` advances.
 */

import { useEffect, useState } from 'preact/hooks'
import {
  authSession,
  currentSessionEpoch,
  getSingleUserToken,
  isEpochCurrent,
  resolveWorkspaceUrl,
  sessionEpoch,
  type AuthSession,
} from '../core/auth'

type PortraitCacheEntry =
  | { readonly kind: 'ok'; readonly blobUrl: string }
  | { readonly kind: 'miss' }

const portraitEntries = new Map<string, PortraitCacheEntry>()
const inFlightPortraits = new Map<string, Promise<string | null>>()

function canFetchPortraitForSession(session: AuthSession): boolean {
  return session.kind === 'single_user_local' || session.kind === 'multi_account_signed_in'
}

function sessionCacheTag(session: AuthSession): string {
  if (session.kind === 'multi_account_signed_in') return `ma:${session.accountId}`
  if (session.kind === 'single_user_local') return `su:${session.tokenPresent ? 'tok' : 'notok'}`
  return session.kind
}

function isDirectImageSrc(url: string): boolean {
  return url.startsWith('blob:') || url.startsWith('data:')
}

function revokeAllPortraits(): void {
  const canRevoke = typeof URL !== 'undefined' && typeof URL.revokeObjectURL === 'function'
  if (canRevoke) {
    for (const entry of portraitEntries.values()) {
      if (entry.kind === 'ok') {
        try {
          URL.revokeObjectURL(entry.blobUrl)
        } catch {
          /* ignore revoke errors in non-browser test envs */
        }
      }
    }
  }
  portraitEntries.clear()
  inFlightPortraits.clear()
}

let lastTrackedEpoch = sessionEpoch.peek()
sessionEpoch.subscribe((epoch) => {
  if (epoch !== lastTrackedEpoch) {
    lastTrackedEpoch = epoch
    revokeAllPortraits()
  }
})

export function getCachedAuthenticatedPortrait(url: string | null): {
  readonly hit: boolean
  readonly blobUrl: string | null
} {
  if (!url) return { hit: true, blobUrl: null }
  if (isDirectImageSrc(url)) return { hit: true, blobUrl: url }

  const session = authSession.peek()
  if (!canFetchPortraitForSession(session)) return { hit: true, blobUrl: null }

  const resolvedUrl = resolveWorkspaceUrl(url)
  const key = `${currentSessionEpoch()}:${sessionCacheTag(session)}:${resolvedUrl}`
  const existing = portraitEntries.get(key)
  if (!existing) return { hit: false, blobUrl: null }
  return {
    hit: true,
    blobUrl: existing.kind === 'ok' ? existing.blobUrl : null,
  }
}

export async function loadAuthenticatedPortrait(
  url: string,
  fetchImpl: typeof fetch = globalThis.fetch,
): Promise<string | null> {
  if (!url) return null
  if (isDirectImageSrc(url)) return url
  if (typeof URL === 'undefined' || typeof URL.createObjectURL !== 'function') return null

  const session = authSession.peek()
  if (!canFetchPortraitForSession(session)) return null

  const startEpoch = currentSessionEpoch()
  const resolvedUrl = resolveWorkspaceUrl(url)
  const key = `${startEpoch}:${sessionCacheTag(session)}:${resolvedUrl}`

  const existing = portraitEntries.get(key)
  if (existing) {
    return existing.kind === 'ok' ? existing.blobUrl : null
  }

  const inflight = inFlightPortraits.get(key)
  if (inflight) return inflight

  const headers: Record<string, string> = { Accept: 'image/png,image/*;q=0.9,*/*;q=0.1' }
  if (session.kind === 'single_user_local') {
    const token = getSingleUserToken()
    if (token) headers.Authorization = `Bearer ${token}`
  }

  const pending = (async (): Promise<string | null> => {
    try {
      const response = await fetchImpl(resolvedUrl, {
        method: 'GET',
        credentials: 'same-origin',
        headers,
      })
      if (!isEpochCurrent(startEpoch)) return null
      if (!response.ok) {
        portraitEntries.set(key, { kind: 'miss' })
        return null
      }
      const ct = (response.headers.get('content-type') ?? '').toLowerCase()
      if (ct && !ct.startsWith('image/')) {
        portraitEntries.set(key, { kind: 'miss' })
        return null
      }
      const blob = await response.blob()
      if (!isEpochCurrent(startEpoch)) return null
      if (!blob || blob.size === 0) {
        portraitEntries.set(key, { kind: 'miss' })
        return null
      }
      const blobUrl = URL.createObjectURL(blob)
      portraitEntries.set(key, { kind: 'ok', blobUrl })
      return blobUrl
    } catch {
      if (isEpochCurrent(startEpoch)) {
        portraitEntries.set(key, { kind: 'miss' })
      }
      return null
    } finally {
      inFlightPortraits.delete(key)
    }
  })()

  inFlightPortraits.set(key, pending)
  return pending
}

export function useAuthenticatedPortrait(url: string | null): string | null {
  const epoch = sessionEpoch.value
  const session = authSession.value
  const sessionKey = sessionCacheTag(session)
  const eligible = url !== null && (isDirectImageSrc(url) || canFetchPortraitForSession(session))

  const [resolvedSrc, setResolvedSrc] = useState<string | null>(() => {
    if (!url || !eligible) return null
    const cached = getCachedAuthenticatedPortrait(url)
    return cached.hit ? cached.blobUrl : null
  })

  useEffect(() => {
    if (!url || !eligible) {
      setResolvedSrc(null)
      return
    }
    if (isDirectImageSrc(url)) {
      setResolvedSrc(url)
      return
    }
    const cached = getCachedAuthenticatedPortrait(url)
    if (cached.hit) {
      setResolvedSrc(cached.blobUrl)
      return
    }

    let cancelled = false
    setResolvedSrc(null)
    void loadAuthenticatedPortrait(url).then((blobUrl) => {
      if (!cancelled) {
        setResolvedSrc(blobUrl)
      }
    })
    return () => {
      cancelled = true
    }
  }, [url, eligible, epoch, sessionKey])

  return resolvedSrc
}

export function resetPortraitCacheForTests(): void {
  revokeAllPortraits()
  lastTrackedEpoch = sessionEpoch.peek()
}
