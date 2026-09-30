import { keeperEquipmentKey, type KeeperPortraitReading } from '../api/schemas/keeper-portrait'
// Keeper portrait: the name's body wearing the server-observed equipment.
//
// GET /api/v1/keepers/:name/portrait.png?size=N is authorised like the
// keeper's other reads: open on a loopback server, a token once HTTP auth is
// strict. A bare <img src> cannot send the dashboard's token, so the PNG is
// fetched with authHeaders() and shown through an object URL, the way
// fetchToolBlobBytes reads artifact bytes. The server tags the PNG with a
// strong ETag and `Cache-Control: no-cache`; the fetch asks with
// `cache: 'no-cache'`, so the browser keeps the file and only revalidates it.
//
// When the portrait cannot load (a keeper that is gone, a
// refused token) the caller's fallback is drawn instead, so the header never
// shows a broken image icon. A failure is kept for this mount only: opening
// the keeper again asks once more, and nothing retries on its own.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { ApiRequestError, authHeaders, fetchWithTimeout } from '../api/core'
import { DEFAULT_GET_TIMEOUT_MS } from '../config/constants'

// The renderer's accepted edge lengths (lib/keeper_portrait,
// Keeper_portrait_draw.min_size / max_size). The server refuses anything
// outside them rather than clamping, so the client stays inside.
// keeper-portrait-bounds-parity.test.ts reads the OCaml values and fails when
// these copies drift from them.
export const PORTRAIT_MIN_PX = 16
export const PORTRAIT_MAX_PX = 512

// Pixels requested per CSS pixel, so the portrait stays sharp on a 2x screen.
const DEVICE_PIXELS_PER_CSS_PIXEL = 2

export function keeperPortraitUrl(name: string, cssPx: number): string {
  const px = Math.min(
    PORTRAIT_MAX_PX,
    Math.max(PORTRAIT_MIN_PX, Math.round(cssPx * DEVICE_PIXELS_PER_CSS_PIXEL)),
  )
  return `/api/v1/keepers/${encodeURIComponent(name)}/portrait.png?size=${px}`
}

/** The PNG at [path], asked for with the dashboard's token. Throws
 * `ApiRequestError` on a non-2xx answer. */
export async function fetchKeeperPortrait(
  path: string,
  opts: { signal?: AbortSignal } = {},
): Promise<Blob> {
  return fetchWithTimeout(
    path,
    { headers: authHeaders(), signal: opts.signal, cache: 'no-cache' },
    DEFAULT_GET_TIMEOUT_MS,
    async response => {
      if (!response.ok) {
        throw new ApiRequestError({
          method: 'GET', path, status: response.status, statusText: response.statusText,
        })
      }
      return response.blob()
    },
  )
}

type Portrait =
  | { kind: 'loading'; identity: string }
  | { kind: 'shown'; identity: string; objectUrl: string }
  | { kind: 'failed'; identity: string }

export interface KeeperPortraitProps {
  name: string
  reading: KeeperPortraitReading
  /** Drawn width and height in CSS pixels; fixed so nothing shifts while it loads. */
  sizePx: number
  /** Drawn instead when the portrait cannot load. */
  fallback: VNode
}

export function KeeperPortrait({ name, reading, sizePx, fallback }: KeeperPortraitProps) {
  const path = keeperPortraitUrl(name, sizePx)
  const equipmentKey = reading.state === 'ready' ? keeperEquipmentKey(reading.equipment) : null
  const identity = JSON.stringify([path, equipmentKey])
  const [portrait, setPortrait] = useState<Portrait>({ kind: 'loading', identity })

  // Synchronises with two things outside Preact: the request, and the object
  // URL's lifetime. Each path and equipment snapshot gets one request; changing either or unmounting
  // aborts it and revokes the URL it made.
  useEffect(() => {
    if (equipmentKey === null) {
      setPortrait({ kind: 'loading', identity })
      return
    }
    const controller = new AbortController()
    let objectUrl: string | null = null
    fetchKeeperPortrait(path, { signal: controller.signal })
      .then(blob => {
        if (controller.signal.aborted) return
        objectUrl = URL.createObjectURL(blob)
        setPortrait({ kind: 'shown', identity, objectUrl })
      })
      .catch(() => {
        if (!controller.signal.aborted) setPortrait({ kind: 'failed', identity })
      })
    return () => {
      controller.abort()
      if (objectUrl !== null) URL.revokeObjectURL(objectUrl)
    }
  }, [path, identity, equipmentKey])

  // A state left from the previous path is not this path's answer.
  if (reading.state === 'unavailable') {
    return html`<span title=${reading.reason} data-testid="keeper-portrait-unavailable">${fallback}</span>`
  }
  const current: Portrait = portrait.identity === identity ? portrait : { kind: 'loading', identity }
  switch (current.kind) {
    case 'failed':
      return fallback
    case 'loading':
      return html`<span
        class="block shrink-0 rounded-full"
        style=${{ width: `${sizePx}px`, height: `${sizePx}px` }}
        aria-hidden="true"
        data-testid="keeper-portrait-loading"
      ></span>`
    case 'shown':
      // The name is already written next to the portrait, so it is decorative.
      return html`<img
        src=${current.objectUrl}
        width=${sizePx}
        height=${sizePx}
        alt=""
        decoding="async"
        class="block shrink-0 rounded-full"
        data-testid="keeper-portrait"
        onError=${() => setPortrait({ kind: 'failed', identity })}
      />`
  }
}
