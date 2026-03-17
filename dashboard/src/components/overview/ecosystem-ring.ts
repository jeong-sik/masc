// MASC Dashboard — Ecosystem Ring (circular agent layout with status indicators)

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
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

function categorizeStatus(s: string): 'active' | 'idle' | 'offline' {
  if (s === 'active' || s === 'busy' || s === 'listening') return 'active'
  if (s === 'idle') return 'idle'
  return 'offline'
}

export function EcosystemRing({ agents, roomName, roomHealth, onAgentClick }: EcosystemRingProps) {
  const hoveredAgent = useSignal<string | null>(null)
  const total = agents.length
  const radius = 42

  const counts = { active: 0, idle: 0, offline: 0 }
  for (const a of agents) counts[categorizeStatus(a.status)]++

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
        const cat = categorizeStatus(agent.status)
        const isHovered = hoveredAgent.value === agent.name

        return html`
          <div
            class="ecosystem-ring__agent ecosystem-ring__agent--${cat}"
            key=${agent.name}
            style=${{ left: `${x}%`, top: `${y}%` }}
            onMouseEnter=${() => { hoveredAgent.value = agent.name }}
            onMouseLeave=${() => { hoveredAgent.value = null }}
          >
            <${AgentAvatar}
              name=${agent.name}
              status=${agent.status}
              traits=${agent.traits}
              size="sm"
              showName=${true}
              onClick=${onAgentClick ? () => onAgentClick(agent.name) : undefined}
            />
            ${isHovered ? html`
              <div class="ecosystem-ring__tooltip">
                <div><strong>${agent.name}</strong></div>
                <div>상태: ${agent.status}</div>
                ${agent.current_task ? html`<div>태스크: ${agent.current_task}</div>` : null}
                ${agent.model ? html`<div>모델: ${agent.model}</div>` : null}
              </div>
            ` : null}
          </div>
        `
      })}
    </div>
    <div class="ecosystem-ring__distribution">
      active ${counts.active} / idle ${counts.idle} / offline ${counts.offline}
    </div>
  `
}
