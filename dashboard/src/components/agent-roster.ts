// MASC Dashboard — Unified Agent Roster
// All entities are agents. Keeper = agent with persistent runtime.
// Keeper state (CTX gauge, generation, autonomy) shown inline on the card.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { agents, keepers } from '../store'
import { missionSnapshot } from '../mission-store'
import { navigate } from '../router'
import { AgentAvatar } from './overview/agent-avatar'
import { formatDuration } from './mission-utils'

type StatusFilter = 'all' | 'active' | 'idle' | 'offline'

function statusCategory(status: string): StatusFilter {
  const s = status.toLowerCase()
  if (s === 'active' || s === 'busy' || s === 'listening' || s === 'working') return 'active'
  if (s === 'offline' || s === 'inactive') return 'offline'
  return 'idle'
}

function statusLabel(status: string): string {
  const labels: Record<string, string> = {
    active: '활성', busy: '처리 중', listening: '대기', working: '작업 중',
    idle: '유휴', offline: '오프라인', inactive: '비활성',
  }
  return labels[status.toLowerCase()] ?? status
}

function statusBadgeClass(status: string): string {
  const cat = statusCategory(status)
  if (cat === 'active') return 'roster-badge--active'
  if (cat === 'offline') return 'roster-badge--offline'
  return 'roster-badge--idle'
}

function pressureClass(ratio: number | null | undefined): string {
  if (ratio == null) return ''
  const pct = ratio * 100
  if (pct < 50) return 'pressure--ok'
  if (pct < 70) return 'pressure--amber'
  if (pct < 85) return 'pressure--orange'
  return 'pressure--red'
}

interface KeeperInfo {
  generation?: number | null
  context_ratio?: number | null
  model?: string | null
  current_work?: string | null
  last_turn_ago_s?: number | null
  autonomy_level?: string | null
}

function findKeeper(agentName: string, keeperList: any[], keeperBriefs: any[]): KeeperInfo | null {
  // Try keeper briefs first (richer data from mission snapshot)
  for (const kb of keeperBriefs) {
    if (kb.name === agentName || kb.agent_name === agentName
        || agentName.includes(kb.name) || kb.name?.includes(agentName)) {
      return kb
    }
  }
  // Fallback to keeper signal store
  for (const k of keeperList) {
    if (k.name === agentName || k.agent_name === agentName
        || agentName.includes(k.name) || k.name?.includes(agentName)) {
      return k
    }
  }
  return null
}

export function AgentRoster() {
  const [filter, setFilter] = useState<StatusFilter>('all')
  const [search, setSearch] = useState('')

  const agentList = agents.value
  const keeperList = keepers.value
  const snap = missionSnapshot.value
  const briefs = snap?.agent_briefs ?? []
  const keeperBriefs = snap?.keeper_briefs ?? []

  const briefMap = new Map(briefs.map(b => [b.name, b]))

  const filtered = agentList
    .filter((a: { name: string; status: string }) => {
      if (filter !== 'all' && statusCategory(a.status) !== filter) return false
      if (search && !a.name.toLowerCase().includes(search.toLowerCase())) return false
      return true
    })
    .sort((a: { status: string; name: string }, b: { status: string; name: string }) => {
      const order: Record<string, number> = { active: 0, busy: 0, listening: 0, working: 0, idle: 1, offline: 2, inactive: 2 }
      const aOrder = order[a.status.toLowerCase()] ?? 1
      const bOrder = order[b.status.toLowerCase()] ?? 1
      if (aOrder !== bOrder) return aOrder - bOrder
      return a.name.localeCompare(b.name)
    })

  const counts = {
    all: agentList.length,
    active: agentList.filter((a: { status: string }) => statusCategory(a.status) === 'active').length,
    idle: agentList.filter((a: { status: string }) => statusCategory(a.status) === 'idle').length,
    offline: agentList.filter((a: { status: string }) => statusCategory(a.status) === 'offline').length,
  }

  return html`
    <div class="roster-page agent-page">
      <div class="roster-header">
        <h2 class="roster-title">에이전트 (${agentList.length})</h2>
        <p class="agent-page__subtitle">등록된 에이전트 — keeper 런타임이 있으면 컨텍스트 게이지 표시</p>
        <div class="roster-controls">
          <input
            type="text"
            class="roster-search"
            placeholder="이름 검색..."
            value=${search}
            onInput=${(e: Event) => setSearch((e.target as HTMLInputElement).value)}
          />
          <div class="roster-filters">
            ${(['all', 'active', 'idle', 'offline'] as StatusFilter[]).map(f => html`
              <button
                key=${f}
                class="roster-filter-btn ${filter === f ? 'active' : ''}"
                onClick=${() => setFilter(f)}
              >
                ${f === 'all' ? '전체' : f === 'active' ? '활성' : f === 'idle' ? '유휴' : '오프라인'} ${counts[f]}
              </button>
            `)}
          </div>
        </div>
      </div>

      <div class="roster-list">
        ${filtered.map((agent: { name: string; status: string; current_task?: string; traits?: string[] }) => {
          const brief = briefMap.get(agent.name)
          const keeper = findKeeper(agent.name, keeperList, keeperBriefs)
          const isKeeper = keeper != null
          const currentWork = keeper?.current_work ?? brief?.current_work ?? agent.current_task ?? null
          const lastActivity = keeper?.last_turn_ago_s ?? brief?.last_turn_ago_s ?? null
          const ctxPct = keeper?.context_ratio != null ? Math.round(keeper.context_ratio * 100) : null

          return html`
            <div
              class="roster-card ${isKeeper ? 'roster-card--keeper' : ''}"
              key=${agent.name}
              onClick=${() => navigate('execution', { agent: agent.name })}
              role="button"
              tabindex="0"
            >
              <div class="roster-card__avatar">
                <${AgentAvatar}
                  name=${agent.name}
                  status=${agent.status}
                  traits=${agent.traits}
                  size="xl"
                  currentWork=${currentWork}
                  activityAge=${lastActivity}
                />
              </div>
              <div class="roster-card__info">
                <div class="roster-card__header">
                  <strong class="roster-card__name">${agent.name}</strong>
                  ${isKeeper ? html`
                    <span class="roster-card__keeper-tag">keeper</span>
                  ` : null}
                  ${keeper?.generation != null ? html`
                    <span class="roster-card__gen">G${keeper.generation}</span>
                  ` : null}
                  <span class="roster-badge ${statusBadgeClass(agent.status)}">
                    ${statusLabel(agent.status)}
                  </span>
                </div>

                ${isKeeper && ctxPct != null ? html`
                  <div class="roster-card__gauge">
                    <div class="roster-card__gauge-track">
                      <div
                        class="roster-card__gauge-bar ${pressureClass(keeper.context_ratio)}"
                        style=${{ width: `${ctxPct}%` }}
                      />
                    </div>
                    <span class="roster-card__gauge-label">ctx ${ctxPct}%</span>
                  </div>
                ` : null}

                ${currentWork ? html`
                  <div class="roster-card__work">${currentWork}</div>
                ` : html`
                  <div class="roster-card__work roster-card__work--empty">작업 없음</div>
                `}
                <div class="roster-card__meta">
                  ${lastActivity != null ? html`
                    <span>${formatDuration(lastActivity)} 전</span>
                  ` : null}
                  ${(keeper?.model ?? brief?.model) ? html`
                    <span class="roster-card__model">${keeper?.model ?? brief?.model}</span>
                  ` : null}
                </div>
              </div>
            </div>
          `
        })}
        ${filtered.length === 0 ? html`
          <div class="roster-empty">조건에 맞는 에이전트가 없습니다.</div>
        ` : null}
      </div>
    </div>
  `
}
