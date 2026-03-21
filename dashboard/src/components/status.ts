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
    <div class="tab-unified">
      <div class="tab-pill-bar">
        <button
          class="tab-pill ${section === 'sessions' ? 'tab-pill--active' : ''}"
          onClick=${() => navigate('status', { section: 'sessions' })}
        >
          세션
        </button>
        <button
          class="tab-pill ${section === 'agents' ? 'tab-pill--active' : ''}"
          onClick=${() => navigate('status', { section: 'agents' })}
        >
          에이전트
        </button>
        <button
          class="tab-pill ${section === 'activity' ? 'tab-pill--active' : ''}"
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
