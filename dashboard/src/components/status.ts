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
    <div class="flex flex-col gap-4">
      <div class="flex gap-1 p-1 bg-[var(--white-3)] rounded-lg w-fit">
        <button
          class="px-3.5 py-1.5 rounded-md text-xs font-medium transition-all cursor-pointer border-0 ${section === 'sessions' ? 'bg-[var(--accent-soft)] text-[var(--accent)]' : 'bg-transparent text-[var(--text-muted)] hover:text-[var(--text-body)]'}"
          onClick=${() => navigate('status', { section: 'sessions' })}
        >
          세션
        </button>
        <button
          class="px-3.5 py-1.5 rounded-md text-xs font-medium transition-all cursor-pointer border-0 ${section === 'agents' ? 'bg-[var(--accent-soft)] text-[var(--accent)]' : 'bg-transparent text-[var(--text-muted)] hover:text-[var(--text-body)]'}"
          onClick=${() => navigate('status', { section: 'agents' })}
        >
          에이전트
        </button>
        <button
          class="px-3.5 py-1.5 rounded-md text-xs font-medium transition-all cursor-pointer border-0 ${section === 'activity' ? 'bg-[var(--accent-soft)] text-[var(--accent)]' : 'bg-transparent text-[var(--text-muted)] hover:text-[var(--text-body)]'}"
          onClick=${() => navigate('status', { section: 'activity' })}
        >
          활동
        </button>
      </div>

      ${section === 'agents'
        ? html`<${AgentsUnified} />`
        : section === 'activity'
          ? html`<${Activity} />`
          : html`<${Mission} />`}
    </div>
  `
}
