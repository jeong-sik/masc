// Shared hover cursor — keeper-v2 monitor-more design (.ob-cursor).
// Single vertical line rendered once inside the parent .ob-panel, spanning
// all tracks. Reads cursorPosition signal (from cursor-store.ts).

import { html } from 'htm/preact'
import { cursorPosition } from './cursor-store'

export function CursorLine() {
  const pos = cursorPosition.value
  if (pos == null) return null
  return html`
    <div
      class="ob-cursor"
      style="left: ${(pos.pct * 100).toFixed(3)}%;"
      aria-hidden="true"
    ></div>
  `
}
