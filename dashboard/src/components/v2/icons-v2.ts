// MASC v2 — nav icon set (ported 1:1 from prototype shell.jsx ICON map).
// Custom 24×24 line icons (NOT lucide) so the rail matches the design exactly.

import { html } from 'htm/preact'
import type { VNode } from 'preact'

type Icon = VNode

// Closed key union (WO-A4-3c): with Record<string, Icon> a typo'd icon key
// compiled fine and rendered undefined silently; the union turns that into
// a compile error at every ICONS[...] index and NavEntry.icon literal.
export type IconKey =
  | 'grid'
  | 'users'
  | 'layers'
  | 'board'
  | 'term'
  | 'code'
  | 'plug'
  | 'gear'
  | 'shield'
  | 'target'
  | 'monitor'
  | 'logs'
  | 'fusion'
  | 'clock'

export const ICONS: Readonly<Record<IconKey, Icon>> = {
  grid: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><rect x="3" y="3" width="7" height="7" rx="1.4" /><rect x="14" y="3" width="7" height="7" rx="1.4" /><rect x="3" y="14" width="7" height="7" rx="1.4" /><rect x="14" y="14" width="7" height="7" rx="1.4" /></svg>`,
  users: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="8" r="3.2" /><path d="M3.5 19c0-3 2.6-5 5.5-5s5.5 2 5.5 5" /><path d="M16.5 6.2a3 3 0 0 1 0 5.6" /><path d="M18.5 19c0-2-.8-3.6-2-4.6" /></svg>`,
  layers: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l9 5-9 5-9-5z" /><path d="M3 13l9 5 9-5" /><path d="M3 17.5l9 5 9-5" /></svg>`,
  board: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"><rect x="3" y="4" width="5" height="16" rx="1.2" /><rect x="10" y="4" width="5" height="11" rx="1.2" /><rect x="17" y="4" width="4" height="14" rx="1.2" /></svg>`,
  term: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2.2" /><path d="M7 9l3 3-3 3" /><path d="M13 15h4" /></svg>`,
  code: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M8 6l-5 6 5 6" /><path d="M16 6l5 6-5 6" /><path d="M13.5 4l-3 16" /></svg>`,
  plug: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M9 3v5M15 3v5" /><path d="M6 8h12v3a6 6 0 0 1-12 0z" /><path d="M12 17v4" /></svg>`,
  gear: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3" /><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.1 5.1l2.1 2.1M16.8 16.8l2.1 2.1M18.9 5.1l-2.1 2.1M7.2 16.8l-2.1 2.1" /></svg>`,
  shield: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7 3v5.5c0 4.3-3 7.3-7 8.5-4-1.2-7-4.2-7-8.5V6z" /><path d="M9.2 12l2 2 3.6-3.8" /></svg>`,
  target: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.5" /><circle cx="12" cy="12" r="4" /><circle cx="12" cy="12" r="0.6" fill="currentColor" /></svg>`,
  monitor: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12h3.5l2-6 4 13 2.2-7H21" /></svg>`,
  logs: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6h10M4 10h16M4 14h13M4 18h9" /></svg>`,
  fusion: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="4.5" cy="5" r="1.7" /><circle cx="4.5" cy="12" r="1.7" /><circle cx="4.5" cy="19" r="1.7" /><path d="M6.2 5.4 11 11M6.2 12H11M6.2 18.6 11 13" /><circle cx="12.9" cy="12" r="2" /><path d="M14.9 12H19.5" /><circle cx="20" cy="12" r="1.6" fill="currentColor" /></svg>`,
  clock: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.5" /><path d="M12 7.5V12l3 2" /></svg>`,
}

export const ICON_MORE: Icon = html`<svg viewBox="0 0 24 24" fill="currentColor" stroke="none"><circle cx="5" cy="12" r="1.7" /><circle cx="12" cy="12" r="1.7" /><circle cx="19" cy="12" r="1.7" /></svg>`
