// Pulse Strip — horizontal agent bubble bar with state-driven colors and animation

import { html } from 'htm/preact'
import { agentPulses, type PulseState } from '../../live-store'
import { openAgentDetail, selectedAgentName } from '../agent-detail'

function pulseStateClass(state: PulseState): string {
  switch (state) {
    case 'working': return 'pulse-working'
    case 'stale': return 'border-[rgba(239,68,68,0.3)] opacity-60'
    default: return 'border-[var(--white-10)]'
  }
}

export function PulseStrip() {
  const pulses = agentPulses.value
  const selected = selectedAgentName.value

  if (pulses.length === 0) {
    return html`
      <div class="pulse-strip rounded-xl">
        <span class="text-[rgba(255,255,255,0.3)] text-[0.8rem]">연결된 에이전트 없음</span>
      </div>
    `
  }

  return html`
    <div class="pulse-strip rounded-xl">
      ${pulses.map(p => html`
        <button
          key=${p.name}
          class="pulse-bubble ${pulseStateClass(p.state)} ${selected === p.name ? 'pulse-selected' : ''}"
          onClick=${() => openAgentDetail(p.name)}
          title="${p.koreanName ? `${p.name} (${p.koreanName})` : p.name}${p.currentTask ? ` — ${p.currentTask}` : ''}"
        >
          <span class="text-[1.15rem] leading-none">${p.emoji || p.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${p.koreanName ?? p.name}</span>
        </button>
      `)}
    </div>
  `
}
