// MASC Dashboard — Operations Surface
// Canonical command surface is the ops review queue + guided actions.

import { html } from 'htm/preact'
import { Ops } from './ops'

export function Operations() {
  return html`
    <div class="flex flex-col gap-5">
      <div class="transition-opacity duration-300"><${Ops} /></div>
    </div>
  `
}
