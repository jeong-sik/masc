// MASC Dashboard — Ecosystem Ring (circular agent layout with pixel avatars)
// Places agents in a ring around the room center.

import { html } from 'htm/preact'
import type { Agent } from '../../types'
import { AgentAvatar } from './agent-avatar'

interface EcosystemRingProps {
  agents: Agent[]
  roomName?: string | null
  roomHealth?: string | null
  onAgentClick?: (name: string) => void
}

function healthLabel(h: string | null | undefined): string {
  if (!h) return '확인 중'
  const lower = h.toLowerCase()
  if (lower === 'healthy' || lower === 'ok' || lower === 'green') return '정상'
  if (lower === 'degraded' || lower === 'warn') return '주의'
  return '위험'
}

export function EcosystemRing({ agents, roomName, roomHealth, onAgentClick }: EcosystemRingProps) {
  const total = agents.length
  const radius = 42 // % from center

  return html`
    <div class="ecosystem-ring">
      <div class="ecosystem-ring__center">
        <span class="ecosystem-ring__room-name">${roomName ?? 'MASC'}</span>
        <span class="ecosystem-ring__room-health">${healthLabel(roomHealth)}</span>
      </div>
      ${agents.map((agent, i) => {
        const angle = (2 * Math.PI * i) / Math.max(total, 1) - Math.PI / 2
        const x = 50 + radius * Math.cos(angle)
        const y = 50 + radius * Math.sin(angle)

        return html`
          <div
            class="ecosystem-ring__agent"
            key=${agent.name}
            style=${{ left: `${x}%`, top: `${y}%` }}
          >
            <${AgentAvatar}
              name=${agent.name}
              status=${agent.status}
              traits=${agent.traits}
              size="sm"
              showName=${true}
              onClick=${onAgentClick ? () => onAgentClick(agent.name) : undefined}
            />
          </div>
        `
      })}
    </div>
  `
}
