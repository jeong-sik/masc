// MASC Dashboard — Lab Tab
// Absorbs: command + lab(TRPG). Command plane default, TRPG as subsection.

import { html } from 'htm/preact'
import { route, navigate } from '../router'
import { Command } from './command'
import { Lab } from './lab'

export function LabUnified() {
  const surface = route.value.params.surface

  return html`
    <div class="tab-unified">
      <div class="tab-pill-bar">
        <button
          class="tab-pill ${surface !== 'trpg' ? 'tab-pill--active' : ''}"
          onClick=${() => navigate('lab')}
        >
          \uC9C0\uD718
        </button>
        <button
          class="tab-pill ${surface === 'trpg' ? 'tab-pill--active' : ''}"
          onClick=${() => navigate('lab', { surface: 'trpg' })}
        >
          TRPG
        </button>
      </div>

      ${surface === 'trpg'
        ? html`<${Lab} />`
        : html`<${Command} />`
      }
    </div>
  `
}
