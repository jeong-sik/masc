// Vertical cursor line rendered across a track when cursor is active.
// Reads cursorPosition signal (from cursor-store.ts).

import { html } from 'htm/preact'
import { cursorPosition } from './cursor-store'

export function CursorLine() {
  const pos = cursorPosition.value
  if (pos == null) return null
  return html`
    <span
      class="absolute top-0 bottom-0 w-px bg-text-strong/50 pointer-events-none"
      style="left: ${(pos.pct * 100).toFixed(3)}%;"
      aria-hidden="true"
    ></span>
  `
}
