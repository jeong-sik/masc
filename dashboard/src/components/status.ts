// MASC Dashboard — Status Surface
// Conventional read-only status area: sessions, agents, activity.

import { html } from 'htm/preact'
import { route, navigate } from '../router'
import { Mission } from './mission'
import { AgentsUnified } from './agents-unified'
import { Activity } from './activity'

type StatusSection = 'sessions' | 'agents' | 'activity'

function currentSection(): StatusSection {
  const section = route.value.params.section
  if (section === 'agents' || section === 'activity') return section
  return 'sessions'
}

export function Status() {
  const section = currentSection()

  return html`
    <div class="flex flex-col gap-6">
      <div class="flex gap-1.5 p-1.5 bg-card/40 backdrop-blur-md border border-card-border rounded-xl w-fit shadow-sm shadow-black/10">
        <button
          class="px-4 py-2 rounded-lg text-[13px] font-semibold transition-all duration-200 cursor-pointer border border-transparent ${section === 'sessions' ? 'bg-accent/10 text-accent border-accent/20 shadow-sm' : 'bg-transparent text-text-muted hover:bg-white/5 hover:text-text-body'}"
          onClick=${() => navigate('status', { section: 'sessions' })}
        >
          세션 현황
        </button>
        <button
          class="px-4 py-2 rounded-lg text-[13px] font-semibold transition-all duration-200 cursor-pointer border border-transparent ${section === 'agents' ? 'bg-accent/10 text-accent border-accent/20 shadow-sm' : 'bg-transparent text-text-muted hover:bg-white/5 hover:text-text-body'}"
          onClick=${() => navigate('status', { section: 'agents' })}
        >
          에이전트 목록
        </button>
        <button
          class="px-4 py-2 rounded-lg text-[13px] font-semibold transition-all duration-200 cursor-pointer border border-transparent ${section === 'activity' ? 'bg-accent/10 text-accent border-accent/20 shadow-sm' : 'bg-transparent text-text-muted hover:bg-white/5 hover:text-text-body'}"
          onClick=${() => navigate('status', { section: 'activity' })}
        >
          최근 활동
        </button>
      </div>

      <div class="transition-opacity duration-300">
        ${section === 'agents'
          ? html`<${AgentsUnified} />`
          : section === 'activity'
            ? html`<${Activity} />`
            : html`<${Mission} />`}
      </div>
    </div>
  `
}
