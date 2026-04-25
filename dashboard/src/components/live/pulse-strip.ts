// Pulse Strip — horizontal agent bubble bar with state-driven colors and animation

import { html } from 'htm/preact'
import { agentPulses, type PulseState } from '../../live-store'
import { openAgentDetail, selectedAgentName } from '../agent-detail-state'

function pulseStateClass(state: PulseState): string {
  switch (state) {
    case 'working': return 'pulse-working'
    case 'stale': return 'border-[var(--bad-30)] opacity-60'
    default: return 'border-[var(--white-10)]'
  }
}

export function PulseStrip() {
  const pulses = agentPulses.value
  const selected = selectedAgentName.value

  if (pulses.length === 0) {
    return html`
      <div class="pulse-strip rounded" role="status" aria-label="에이전트 펄스">
        <span class="text-[var(--text-dim)] text-sm">연결된 에이전트 없음. masc_join으로 에이전트가 접속하면 여기에 표시됩니다.</span>
      </div>
    `
  }

  return html`
    <div class="pulse-strip rounded" role="region" aria-label="에이전트 펄스">
      ${pulses.map(p => html`
        <button type="button"
          key=${p.name}
          class="pulse-bubble ${pulseStateClass(p.state)} ${selected === p.name ? 'pulse-selected' : ''}"
          onClick=${() => openAgentDetail(p.name)}
          aria-pressed=${selected === p.name}
          title="${p.koreanName ? `${p.name} (${p.koreanName})` : p.name}${p.currentTask ? ` — ${p.currentTask}` : ''}"
        >
          <span class="text-[1.15rem] leading-none">${p.emoji || p.name.charAt(0).toUpperCase()}</span>
          <span class="text-[0.65rem] text-[var(--text-muted)] whitespace-nowrap overflow-hidden text-ellipsis max-w-16">${p.koreanName ?? p.name}</span>
        </button>
      `)}
    </div>
  `
}
