// MASC Dashboard — Unified Agent Roster
// All entities are agents. Keeper = agent with persistent runtime.
// Keeper state (CTX gauge, generation, autonomy) shown inline on the card.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { Agent, Keeper } from '../types'
import type { DashboardMissionKeeperBrief } from '../types/dashboard-mission'
import { agents, keepers } from '../store'
import { missionKeeperBriefs, missionAgentBriefs } from '../mission-signals'
import { AgentAvatar } from './overview/agent-avatar'
import { openAgentDetail } from './agent-detail'
import { formatDuration } from './mission-utils'

type StatusFilter = 'all' | 'active' | 'idle' | 'offline'

function statusCategory(status: string | undefined): StatusFilter {
  if (!status) return 'idle'
  const s = status.toLowerCase()
  if (s === 'active' || s === 'busy' || s === 'listening' || s === 'working') return 'active'
  if (s === 'offline' || s === 'inactive') return 'offline'
  return 'idle'
}

function statusLabel(status: string | undefined): string {
  if (!status) return '(unknown)'
  const labels: Record<string, string> = {
    active: '활성', busy: '처리 중', listening: '대기', working: '작업 중',
    idle: '유휴', offline: '오프라인', inactive: '비활성',
  }
  return labels[status.toLowerCase()] ?? status
}

function statusBadgeClass(status: string | undefined): string {
  const cat = statusCategory(status)
  if (cat === 'active') return 'roster-badge--active'
  if (cat === 'offline') return 'roster-badge--offline'
  return 'roster-badge--idle'
}

interface KeeperInfo {
  generation?: number | null
  context_ratio?: number | null
  model?: string | null
  current_work?: string | null
  last_turn_ago_s?: number | null
}

function findKeeper(agentName: string, keeperList: Keeper[], keeperBriefs: DashboardMissionKeeperBrief[]): KeeperInfo | null {
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

export type KeeperFilterMode = 'all' | 'agent-only' | 'keeper-only'

export function AgentRoster({ keeperFilter = 'all' }: { keeperFilter?: KeeperFilterMode } = {}) {
  const [filter, setFilter] = useState<StatusFilter>('all')
  const [search, setSearch] = useState('')

  const agentList = agents.value
  const keeperList = keepers.value
  const briefs = missionAgentBriefs.value
  const keeperBriefs = missionKeeperBriefs.value

  const briefMap = new Map(briefs.map(b => [b.agent_name, b]))

  const filtered = agentList
    .filter((a: Agent) => {
      if (filter !== 'all' && statusCategory(a.status) !== filter) return false
      if (search && !a.name.toLowerCase().includes(search.toLowerCase())) return false
      // Keeper filter from parent chip
      if (keeperFilter !== 'all') {
        const isKeeper = findKeeper(a.name, keeperList, keeperBriefs) != null
        if (keeperFilter === 'keeper-only' && !isKeeper) return false
        if (keeperFilter === 'agent-only' && isKeeper) return false
      }
      return true
    })
    .sort((a: Agent, b: Agent) => {
      const order: Record<StatusFilter, number> = {
        all: 0,
        active: 0,
        idle: 1,
        offline: 2,
      }
      const aOrder = order[statusCategory(a.status)]
      const bOrder = order[statusCategory(b.status)]
      if (aOrder !== bOrder) return aOrder - bOrder
      return a.name.localeCompare(b.name)
    })

  const counts = {
    all: agentList.length,
    active: agentList.filter((a: Agent) => statusCategory(a.status) === 'active').length,
    idle: agentList.filter((a: Agent) => statusCategory(a.status) === 'idle').length,
    offline: agentList.filter((a: Agent) => statusCategory(a.status) === 'offline').length,
  }

  return html`
    <div class="p-[var(--space-lg,24px)] max-w-[1200px] agent-page">
      <div class="mb-6">
        <h2 class="text-[20px] font-semibold text-[var(--ff-gold-bright)] mb-[var(--space-md,16px)] tracking-[0.5px] [text-shadow:0_1px_4px_rgba(212,169,75,0.2)]">${keeperFilter === 'keeper-only' ? '키퍼' : keeperFilter === 'agent-only' ? '에이전트' : '에이전트'} (${filtered.length})</h2>
        <p class="text-[13px] text-[var(--white-30)] mt-1">${keeperFilter === 'keeper-only' ? '키퍼 런타임이 있는 에이전트' : keeperFilter === 'agent-only' ? '키퍼 런타임이 없는 에이전트' : '등록된 에이전트 — keeper 런타임이 있으면 컨텍스트 게이지 표시'}</p>
        <div class="flex gap-4 items-center flex-wrap">
          <input
            type="text"
            class="py-1.5 px-3 border border-[var(--ff-border-subtle)] bg-[var(--ff-navy)] text-[var(--white-90)] text-base w-[200px] rounded transition-colors duration-200 focus:outline-none focus:border-[var(--ff-gold)] focus:shadow-[0_0_0_2px_var(--ff-gold-dim)] placeholder:text-[var(--white-25)]"
            placeholder="이름 검색..."
            value=${search}
            onInput=${(e: Event) => setSearch((e.target as HTMLInputElement).value)}
          />
          <div class="flex gap-1.5">
            ${(['all', 'active', 'idle', 'offline'] as StatusFilter[]).map(f => html`
              <button type="button"
                key=${f}
                class="px-2.5 py-1 text-[11px] rounded-xl border cursor-pointer transition-all duration-150 ${filter === f
                  ? 'border-[rgba(200,168,78,0.5)] bg-[rgba(200,168,78,0.12)] text-[#e8d48b]'
                  : 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:border-[rgba(200,168,78,0.4)]'}"
                onClick=${() => setFilter(f)}
              >
                ${f === 'all' ? '전체' : f === 'active' ? '활성' : f === 'idle' ? '유휴' : '오프라인'} ${counts[f]}
              </button>
            `)}
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-5">
        ${filtered.map((agent: Agent) => {
          const brief = briefMap.get(agent.name)
          const keeper = findKeeper(agent.name, keeperList, keeperBriefs)
          const isKeeper = keeper != null
          const currentWork = keeper?.current_work ?? brief?.current_work ?? agent.current_task ?? null
          const lastActivity = keeper?.last_turn_ago_s ?? brief?.last_activity_age_sec ?? null
          const ctxPct = keeper?.context_ratio != null ? Math.round(keeper.context_ratio * 100) : null

          return html`
            <div
              class="group flex flex-col gap-3 p-5 bg-[var(--bg-1)] border border-[var(--card-border)] rounded-2xl hover:border-[var(--accent-soft)] hover:bg-[var(--bg-0)] transition-all duration-200 shadow-sm cursor-pointer relative overflow-hidden"
              key=${agent.name}
              onClick=${() => openAgentDetail(agent.name)}
              role="button"
              tabindex="0"
            >
              ${isKeeper && ctxPct != null ? html`<div class="absolute bottom-0 left-0 h-1 bg-linear-to-r from-[var(--accent)] to-[var(--ok)] transition-all duration-300 opacity-80 group-hover:opacity-100" style=${{ width: ctxPct + '%' }}></div>` : null}
              
              <div class="flex items-start gap-4">
                <div class="shrink-0 relative">
                  <${AgentAvatar}
                    name=${agent.name}
                    status=${agent.status}
                    traits=${agent.traits}
                    size="xl"
                    currentWork=${currentWork}
                    activityAge=${lastActivity}
                  />
                  ${isKeeper ? html`<div class="absolute -bottom-2 left-1/2 -translate-x-1/2 text-[9px] font-bold tracking-[0.1em] text-[var(--ff-gold)] bg-[rgba(20,20,30,0.95)] border border-[var(--ff-gold-20)] px-2 py-0.5 rounded-full shadow-md z-10 uppercase">KEEPER</div>` : null}
                </div>
                
                <div class="flex flex-col min-w-0 flex-1 justify-center py-1">
                  <div class="flex items-center gap-2 flex-wrap mb-1">
                    <strong class="text-lg text-[var(--text-strong)] font-semibold truncate leading-tight group-hover:text-[var(--accent)] transition-colors">${agent.name}</strong>
                    <span class="roster-badge ${statusBadgeClass(agent.status)}">${statusLabel(agent.status)}</span>
                  </div>
                  
                  <div class="flex items-center gap-1.5 flex-wrap">
                    ${keeper?.model ? html`<span class="font-mono text-[10px] text-[var(--text-muted)] bg-[var(--white-4)] border border-[var(--card-border)] px-1.5 py-px rounded">${keeper.model}</span>` : null}
                    ${keeper?.generation != null ? html`<span class="text-[11px] text-[var(--accent)] font-medium bg-[var(--accent-10)] px-1.5 py-px rounded border border-[rgba(71,184,255,0.15)]">Lv.${keeper.generation}</span>` : null}
                  </div>
                </div>
              </div>

              <div class="flex flex-col gap-2 mt-2 pt-3 border-t border-[var(--border-slate-12)]">
                <div class="flex justify-between items-center text-[10px] text-[var(--text-muted)]">
                  <div class="flex items-center gap-1.5 truncate max-w-[65%]">
                    ${currentWork 
                      ? html`<span class="text-[12px] text-[var(--accent)] bg-[var(--accent-soft)] px-2 py-0.5 rounded-md truncate font-medium border border-[rgba(71,184,255,0.1)] shadow-sm">${currentWork}</span>`
                      : html`<span class="text-[12px] text-[var(--text-dim)] italic px-2 py-0.5 bg-[var(--white-2)] rounded-md">대기 중</span>`
                    }
                  </div>
                  
                  <div class="flex flex-col items-end gap-1">
                    ${lastActivity != null ? html`
                      <span class="flex items-center gap-1 text-[11px]">
                        ⚡ ${formatDuration(lastActivity)} 전
                      </span>
                    ` : html`<span></span>`}
                    ${isKeeper && ctxPct != null ? html`
                      <span class="font-medium text-[11px]"><span class="text-[var(--ff-gold)] mr-1">CTX</span><span class="text-[var(--text-strong)]">${ctxPct}%</span></span>
                    ` : null}
                  </div>
                </div>
              </div>
            </div>
          `
        })}
        ${filtered.length === 0 ? html`
          <div class="py-[var(--space-xl,32px)] text-center text-[var(--white-20)] text-sm border border-dashed border-[var(--ff-border-subtle)] rounded-md col-span-full">조건에 맞는 에이전트가 없습니다.</div>
        ` : null}
      </div>
    </div>
  `
}
