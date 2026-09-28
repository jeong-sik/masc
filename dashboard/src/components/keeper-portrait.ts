// Keeper portrait: the candle imp the server draws from the keeper's name.
//
// GET /api/v1/keepers/:name/portrait.png?size=N is a public read, like the
// keeper's other plain reads, so a plain <img> can ask for it. The server
// tags the PNG with a strong ETag and `Cache-Control: no-cache`, so the
// browser keeps the file and only revalidates it.
//
// When the image cannot load (an older server, a keeper that is gone) the
// caller's fallback is drawn instead, so the header never shows a broken
// image icon.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { VNode } from 'preact'

// The renderer's accepted edge lengths (lib/keeper_portrait,
// Keeper_portrait_draw.min_size / max_size). The server refuses anything
// outside them rather than clamping, so the client stays inside.
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

export interface KeeperPortraitProps {
  name: string
  /** Drawn width and height in CSS pixels; fixed so nothing shifts while it loads. */
  sizePx: number
  /** Drawn instead when the portrait cannot load. */
  fallback: VNode
}

export function KeeperPortrait({ name, sizePx, fallback }: KeeperPortraitProps) {
  // Remember which name failed, so switching to another keeper tries again.
  const [failedName, setFailedName] = useState<string | null>(null)
  if (failedName === name) return fallback
  return html`<img
    src=${keeperPortraitUrl(name, sizePx)}
    width=${sizePx}
    height=${sizePx}
    alt=${name}
    loading="lazy"
    decoding="async"
    class="block shrink-0 rounded-full"
    data-testid="keeper-portrait"
    onError=${() => setFailedName(name)}
  />`
}
