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
    <div class="flex flex-col gap-6">
      <div class="flex gap-1.5 p-1.5 bg-card/40 backdrop-blur-md border border-card-border rounded-xl w-fit shadow-sm shadow-black/10">
        <button
          class="px-4 py-2 rounded-lg text-[13px] font-semibold transition-all duration-200 cursor-pointer border border-transparent ${section === 'overview' ? 'bg-accent/10 text-accent border-accent/20 shadow-sm' : 'bg-transparent text-text-muted hover:bg-white/5 hover:text-text-body'}"
          onClick=${() => navigate('lab', { section: 'overview' })}
        >
          개요
        </button>
        <button
          class="px-4 py-2 rounded-lg text-[13px] font-semibold transition-all duration-200 cursor-pointer border border-transparent ${section === 'trpg' ? 'bg-accent/10 text-accent border-accent/20 shadow-sm' : 'bg-transparent text-text-muted hover:bg-white/5 hover:text-text-body'}"
          onClick=${() => navigate('lab', { section: 'trpg' })}
        >
          TRPG 실험
        </button>
        <button
          class="px-4 py-2 rounded-lg text-[13px] font-semibold transition-all duration-200 cursor-pointer border border-transparent ${section === 'avatars' ? 'bg-accent/10 text-accent border-accent/20 shadow-sm' : 'bg-transparent text-text-muted hover:bg-white/5 hover:text-text-body'}"
          onClick=${() => navigate('lab', { section: 'avatars' })}
        >
          아바타 갤러리
        </button>
      </div>

      <div class="transition-opacity duration-300">
        <${Lab} />
      </div>
    </div>
  `
}

export const LabUnified = LabSurface
