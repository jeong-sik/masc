// MASC Dashboard — Experimental Surface
// Keeps experimental features outside the main operations surface.

import { html } from 'htm/preact'
import { Lab } from './lab'

export function LabSurface() {
  return html`
    <div class="flex flex-col gap-4">
      <div class="transition-opacity duration-300">
        <${Lab} />
      </div>
    </div>
  `
}

export const LabUnified = LabSurface
