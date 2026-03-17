// MASC Dashboard — Agent Grid (Phase 3)
// Replaces circular EcosystemRing with a responsive CSS grid.
// Sorts agents by attention count, signal truth, then name.

import { html } from 'htm/preact'
import type { Agent, DashboardMissionAgentBrief } from '../../types'
import { AgentAvatar } from './agent-avatar'

interface AgentGridProps {
  agents: Agent[]
  agentBriefs: DashboardMissionAgentBrief[]
  onAgentClick?: (name: string) => void
}

function signalTruthOrder(truth?: string): number {
  if (truth === 'live') return 0
  if (truth === 'stale') return 1
  if (truth === 'archived') return 2
  return 3
}

export function AgentGrid({ agents, agentBriefs, onAgentClick }: AgentGridProps) {
  if (agents.length === 0) {
    return html`
      <div class="agent-grid">
        <div style="color: var(--text-muted); padding: 12px;">에이전트 없음</div>
      </div>
    `
  }

  const briefMap = new Map(agentBriefs.map(b => [b.agent_name, b]))

  const sorted = [...agents].sort((a, b) => {
    const ba = briefMap.get(a.name)
    const bb = briefMap.get(b.name)

    const attA = ba?.related_attention_count ?? 0
    const attB = bb?.related_attention_count ?? 0
    if (attA !== attB) return attB - attA

    const stA = signalTruthOrder(ba?.signal_truth)
    const stB = signalTruthOrder(bb?.signal_truth)
    if (stA !== stB) return stA - stB

    return a.name.localeCompare(b.name)
  })

  const topActiveNames = new Set(
    sorted
      .filter(a => {
        const brief = briefMap.get(a.name)
        return brief?.signal_truth === 'live' && brief.current_work
      })
      .slice(0, 5)
      .map(a => a.name),
  )

  return html`
    <div class="agent-grid">
      ${sorted.map(agent => {
        const brief = briefMap.get(agent.name)
        const hasBlocker = (brief?.related_attention_count ?? 0) > 0
        const isTopActive = topActiveNames.has(agent.name)

        return html`
          <div class="agent-grid__cell" key=${agent.name}>
            <${AgentAvatar}
              name=${agent.name}
              status=${agent.status}
              traits=${agent.traits}
              size="sm"
              showName=${true}
              currentWork=${brief?.current_work ?? null}
              activityAge=${brief?.last_activity_age_sec ?? null}
              hasBlocker=${hasBlocker}
              signalTruth=${brief?.signal_truth ?? 'unknown'}
              alwaysShowBubble=${isTopActive}
              onClick=${onAgentClick ? () => onAgentClick(agent.name) : undefined}
            />
          </div>
        `
      })}
    </div>
  `
}
