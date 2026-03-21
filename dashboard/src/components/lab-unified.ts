// MASC Dashboard — Experimental Surface
// Keeps TRPG and avatar experiments outside the main operations surface.

import { html } from 'htm/preact'
import { route, navigate } from '../router'
import { Lab } from './lab'

type LabSection = 'overview' | 'trpg' | 'avatars'

function currentSection(): LabSection {
  const section = route.value.params.section
  if (section === 'trpg' || section === 'avatars') return section
  return 'overview'
}

export function LabSurface() {
  const section = currentSection()

  return html`
    <div class="tab-unified">
      <div class="tab-pill-bar">
        <button
          class="tab-pill ${section === 'overview' ? 'tab-pill--active' : ''}"
          onClick=${() => navigate('lab', { section: 'overview' })}
        >
          개요
        </button>
        <button
          class="tab-pill ${section === 'trpg' ? 'tab-pill--active' : ''}"
          onClick=${() => navigate('lab', { section: 'trpg' })}
        >
          TRPG
        </button>
        <button
          class="tab-pill ${section === 'avatars' ? 'tab-pill--active' : ''}"
          onClick=${() => navigate('lab', { section: 'avatars' })}
        >
          아바타
        </button>
      </div>

      <${Lab} />
    </div>
  `
}

export const LabUnified = LabSurface
