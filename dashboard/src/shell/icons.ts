/**
 * Ultra-lean inline SVG stroke icons for the A+ Shell chrome.
 * Keeps `lucide-preact` out of the critical first-load JS chunk.
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'

export type ShellIconName =
  | 'pulse'
  | 'work'
  | 'knowledge'
  | 'keepers'
  | 'runtime'
  | 'infra'
  | 'settings'
  | 'account'
  | 'lock'
  | 'search'
  | 'inbox'
  | 'layers'
  | 'bell'
  | 'sidebar'
  | 'chevron'
  | 'more'
  | 'check'
  | 'x'
  | 'alert'
  | 'refresh'
  | 'sun'
  | 'moon'
  | 'contrast'

const ICON_PATHS: Readonly<Record<ShellIconName, string>> = Object.freeze({
  pulse: 'M2 12h3.5l2-6 4 12 2.5-6H22',
  work: 'M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2M9 5a2 2 0 0 0 2 2h2a2 2 0 0 0 2-2M9 5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2m-6 9 2 2 4-4',
  knowledge: 'M4 19.5A2.5 2.5 0 0 1 6.5 17H20M4 19.5A2.5 2.5 0 0 0 6.5 22H20V2H6.5A2.5 2.5 0 0 0 4 4.5v15Z',
  keepers: 'M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm14 10v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75',
  runtime: 'M13 2 3 14h9l-1 8 10-12h-9l1-8Z',
  infra: 'M2 6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V6Zm0 10a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v2a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-2Zm4-8h.01M6 17h.01',
  settings: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm7.4-3a7.4 7.4 0 0 0-.1-1l2-1.5-2-3.4-2.3.9a7.7 7.7 0 0 0-1.7-1l-.4-2.5H9.1l-.4 2.5a7.7 7.7 0 0 0-1.7 1l-2.3-.9-2 3.4 2 1.5a7.4 7.4 0 0 0 0 2l-2 1.5 2 3.4 2.3-.9c.5.4 1.1.8 1.7 1l.4 2.5h5.8l.4-2.5c.6-.2 1.2-.6 1.7-1l2.3.9 2-3.4-2-1.5c.1-.3.1-.7.1-1Z',
  account: 'M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z',
  lock: 'M7 11V7a5 5 0 0 1 10 0v4M5 11h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2Z',
  search: 'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16Zm10 2-4.35-4.35',
  inbox: 'M22 12h-6l-2 3h-4l-2-3H2m20 0v6a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-6m20 0-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11L2 12',
  layers: 'M12 2 2 7l10 5 10-5-10-5ZM2 17l10 5 10-5M2 12l10 5 10-5',
  bell: 'M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9m-4.27 13a2 2 0 0 1-3.46 0',
  sidebar: 'M3 5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5Zm6-2v18',
  chevron: 'm6 9 6 6 6-6',
  more: 'M12 13a1 1 0 1 0 0-2 1 1 0 0 0 0 2Zm7 0a1 1 0 1 0 0-2 1 1 0 0 0 0 2ZM5 13a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z',
  check: 'M20 6 9 17l-5-5',
  x: 'M18 6 6 18M6 6l12 12',
  alert: 'M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0ZM12 9v4m0 4h.01',
  refresh: 'M23 4v6h-6M1 20v-6h6M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15',
  sun: 'M12 17a5 5 0 1 0 0-10 5 5 0 0 0 0 10Zm0-15v2m0 16v2M4.93 4.93l1.41 1.41m11.32 11.32 1.41 1.41M2 12h2m16 0h2M4.93 19.07l1.41-1.41m11.32-11.32 1.41-1.41',
  moon: 'M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79Z',
  contrast: 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm0 2v16a8 8 0 0 0 0-16Z',
})

export function ShellIcon({
  name,
  size = 16,
  className = '',
}: {
  readonly name: ShellIconName
  readonly size?: number
  readonly className?: string
}): VNode {
  return html`
    <svg
      width=${size}
      height=${size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      class=${`ap-icon ${className}`.trim()}
    >
      <path d=${ICON_PATHS[name]} />
    </svg>
  `
}
