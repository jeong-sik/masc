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
import { formatDuration, trimText } from './mission-utils'

type StatusFilter = 'all' | 'active' | 'idle' | 'offline'

function statusCategory(status: string | undefined): StatusFilter {
  if (!status) return 'idle'
  const s = status.toLowerCase()
  if (s === 'active' || s === 'busy' || s === 'listening' || s === 'working') return 'active'
  if (s === 'offline' || s === 'inactive') return 'offline'
  return 'idle'
}

function statusLabel(status: string | undefined): string {
  if (!status) return '상태 미수집'
  const labels: Record<string, string> = {
    active: '온라인', busy: '처리 중', listening: '응답 대기', working: '작업 실행 중',
    idle: '작업 없음', offline: '연결 끊김', inactive: '중지됨',
  }
  return labels[status.toLowerCase()] ?? status
}

function statusDescription(status: string | undefined): string {
  if (!status) return '런타임 상태를 아직 받지 못했습니다.'
  const descriptions: Record<string, string> = {
    active: '연결되어 있고 요청을 받을 수 있는 상태입니다.',
    busy: '지금 응답이나 작업을 처리하고 있습니다.',
    listening: '연결된 상태에서 입력이나 다음 지시를 기다리고 있습니다.',
    working: '현재 작업을 수행 중입니다.',
    idle: '연결은 유지되지만 지금 표시할 작업은 없습니다.',
    offline: '현재 런타임이 보이지 않거나 하트비트가 없습니다.',
    inactive: '등록은 남아 있지만 현재는 내려간 상태입니다.',
  }
  return descriptions[status.toLowerCase()] ?? '정의되지 않은 상태값입니다.'
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

const FILTER_META: Record<StatusFilter, { label: string; description: string }> = {
  all: {
    label: '전체 보기',
    description: '등록된 런타임 전체를 보여줍니다.',
  },
  active: {
    label: '온라인',
    description: 'active, busy, listening, working 상태를 묶어 보여줍니다.',
  },
  idle: {
    label: '작업 없음',
    description: '연결은 살아 있지만 현재 잡힌 작업이 없는 상태입니다.',
  },
  offline: {
    label: '연결 끊김',
    description: 'offline, inactive 상태를 묶어 보여줍니다.',
  },
}

function matchesKeeperFilter(
  agentName: string,
  keeperList: Keeper[],
  keeperBriefs: DashboardMissionKeeperBrief[],
  keeperFilter: KeeperFilterMode,
): boolean {
  if (keeperFilter === 'all') return true
  const isKeeper = findKeeper(agentName, keeperList, keeperBriefs) != null
  return keeperFilter === 'keeper-only' ? isKeeper : !isKeeper
}

export function scopeAgentsByKeeperFilter(
  agentList: Agent[],
  keeperList: Keeper[],
  keeperBriefs: DashboardMissionKeeperBrief[],
  keeperFilter: KeeperFilterMode,
): Agent[] {
  return agentList.filter((agent: Agent) =>
    matchesKeeperFilter(agent.name, keeperList, keeperBriefs, keeperFilter))
}

export function countAgentsByStatus(agentList: Agent[]): Record<StatusFilter, number> {
  return {
    all: agentList.length,
    active: agentList.filter((agent: Agent) => statusCategory(agent.status) === 'active').length,
    idle: agentList.filter((agent: Agent) => statusCategory(agent.status) === 'idle').length,
    offline: agentList.filter((agent: Agent) => statusCategory(agent.status) === 'offline').length,
  }
}

export function AgentRoster({ keeperFilter = 'all' }: { keeperFilter?: KeeperFilterMode } = {}) {
  const [filter, setFilter] = useState<StatusFilter>('all')
  const [search, setSearch] = useState('')

  const agentList = agents.value
  const keeperList = keepers.value
  const briefs = missionAgentBriefs.value
  const keeperBriefs = missionKeeperBriefs.value

  const briefMap = new Map(briefs.map(b => [b.agent_name, b]))
  const hasKeeperRuntime = keeperFilter !== 'agent-only' && (keeperList.length > 0 || keeperBriefs.length > 0)
  const scopedAgents = scopeAgentsByKeeperFilter(agentList, keeperList, keeperBriefs, keeperFilter)
  const pageTitle = keeperFilter === 'keeper-only'
    ? '키퍼 런타임'
    : keeperFilter === 'agent-only'
      ? '일반 에이전트'
      : '에이전트 목록'
  const pageDescription = keeperFilter === 'keeper-only'
    ? '장기 컨텍스트를 유지하는 상주 런타임만 보여줍니다.'
    : keeperFilter === 'agent-only'
      ? '키퍼가 연결되지 않은 일반 에이전트만 보여줍니다.'
      : '등록된 모든 런타임을 보여줍니다. 키퍼는 장기 컨텍스트를 유지하는 상주 런타임입니다.'

  const filtered = scopedAgents
    .filter((a: Agent) => {
      if (filter !== 'all' && statusCategory(a.status) !== filter) return false
      if (search && !a.name.toLowerCase().includes(search.toLowerCase())) return false
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

  const counts = countAgentsByStatus(scopedAgents)
  const resultCountLabel = filtered.length === scopedAgents.length
    ? `${filtered.length}개 표시 중`
    : `${filtered.length} / ${scopedAgents.length}개 표시 중`

  return html`
    <div class="p-[var(--space-lg,24px)] max-w-[1200px] agent-page">
      <div class="mb-6">
        <div class="flex flex-wrap items-center gap-3 mb-[var(--space-md,16px)]">
          <h2 class="m-0 text-[20px] font-semibold text-[var(--ff-gold-bright)] tracking-[0.5px] [text-shadow:0_1px_4px_rgba(212,169,75,0.2)]">${pageTitle}</h2>
          <span class="inline-flex items-center rounded-full border border-[rgba(200,168,78,0.22)] bg-[rgba(200,168,78,0.12)] px-2.5 py-1 text-[11px] font-medium text-[#e8d48b]">${resultCountLabel}</span>
        </div>
        <p class="text-[13px] text-[var(--white-30)] mt-1">${pageDescription}</p>
        <div class="flex gap-4 items-center flex-wrap">
          <input
            type="text"
            class="py-1.5 px-3 border border-[var(--ff-border-subtle)] bg-[var(--ff-navy)] text-[var(--white-90)] text-base w-[200px] rounded transition-colors duration-200 focus:outline-none focus:border-[var(--ff-gold)] focus:shadow-[0_0_0_2px_var(--ff-gold-dim)] placeholder:text-[var(--white-25)]"
            placeholder="에이전트 이름으로 찾기"
            value=${search}
            onInput=${(e: Event) => setSearch((e.target as HTMLInputElement).value)}
          />
          <div class="flex gap-1.5">
            ${(['all', 'active', 'idle', 'offline'] as StatusFilter[]).map(f => html`
              <button type="button"
                key=${f}
                title=${FILTER_META[f].description}
                class="px-2.5 py-1 text-[11px] rounded-xl border cursor-pointer transition-all duration-150 ${filter === f
                  ? 'border-[rgba(200,168,78,0.5)] bg-[rgba(200,168,78,0.12)] text-[#e8d48b]'
                  : 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:border-[rgba(200,168,78,0.4)]'}"
                onClick=${() => setFilter(f)}
              >
                ${FILTER_META[f].label} ${counts[f]}
              </button>
            `)}
          </div>
        </div>
        <div class="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
          <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-3">
            <div class="text-[11px] font-semibold text-[var(--text-strong)]">온라인</div>
            <p class="mt-1 text-[12px] leading-[1.5] text-[var(--text-muted)]">응답을 받을 수 있는 연결 상태입니다. active, busy, listening, working 값을 한데 묶습니다.</p>
          </div>
          <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-3">
            <div class="text-[11px] font-semibold text-[var(--text-strong)]">작업 없음</div>
            <p class="mt-1 text-[12px] leading-[1.5] text-[var(--text-muted)]">연결은 살아 있지만 지금 카드에 보여줄 현재 작업이 없는 상태입니다.</p>
          </div>
          <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-3">
            <div class="text-[11px] font-semibold text-[var(--text-strong)]">연결 끊김</div>
            <p class="mt-1 text-[12px] leading-[1.5] text-[var(--text-muted)]">하트비트가 없거나 런타임이 내려간 상태입니다.</p>
          </div>
          ${hasKeeperRuntime ? html`
            <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-3">
              <div class="text-[11px] font-semibold text-[var(--text-strong)]">세대 / 컨텍스트 사용량</div>
              <p class="mt-1 text-[12px] leading-[1.5] text-[var(--text-muted)]">세대는 키퍼 핸드오프가 일어날 때 올라가는 런타임 번호입니다. 컨텍스트 사용량은 현재 창을 얼마나 쓰고 있는지 보여줍니다.</p>
            </div>
          ` : null}
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
          const workPreview = trimText(currentWork, 140) ?? '표시할 작업 정보가 없습니다.'
          const lastActivityLabel = lastActivity != null ? `${formatDuration(lastActivity)} 전` : '활동 기록 없음'

          return html`
            <div
              class="group flex flex-col gap-4 p-5 bg-[var(--bg-1)] border border-[var(--card-border)] rounded-2xl hover:border-[var(--accent-soft)] hover:bg-[var(--bg-0)] transition-all duration-200 shadow-sm cursor-pointer"
              key=${agent.name}
              onClick=${() => openAgentDetail(agent.name)}
              role="button"
              tabindex="0"
            >
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
                </div>
                
                <div class="flex flex-col min-w-0 flex-1 justify-center py-1">
                  <div class="flex items-center gap-2 flex-wrap mb-1">
                    <strong class="text-[17px] text-[var(--text-strong)] font-semibold break-all leading-[1.35] group-hover:text-[var(--accent)] transition-colors">${agent.name}</strong>
                    <span class="roster-badge ${statusBadgeClass(agent.status)}" title=${statusDescription(agent.status)}>${statusLabel(agent.status)}</span>
                  </div>
                  
                  <div class="flex items-center gap-1.5 flex-wrap mt-1">
                    <span class="text-[11px] text-[var(--text-muted)] bg-[var(--white-4)] border border-[var(--card-border)] px-2 py-0.5 rounded-full">${isKeeper ? '키퍼 런타임' : '일반 에이전트'}</span>
                    ${keeper?.model ? html`<span class="font-mono text-[10px] text-[var(--text-muted)] bg-[var(--white-4)] border border-[var(--card-border)] px-1.5 py-px rounded">${keeper.model}</span>` : null}
                    ${keeper?.generation != null ? html`<span class="text-[11px] text-[var(--accent)] font-medium bg-[var(--accent-10)] px-1.5 py-px rounded border border-[rgba(71,184,255,0.15)]" title="키퍼 핸드오프가 일어날 때 올라가는 런타임 세대입니다.">세대 ${keeper.generation}</span>` : null}
                  </div>
                </div>
              </div>

              <div class="flex flex-col gap-3 pt-3 border-t border-[var(--border-slate-12)]">
                <div class="rounded-xl border border-[var(--white-6)] bg-[var(--white-2)] px-3 py-3">
                  <div class="text-[10px] font-semibold tracking-[0.08em] uppercase text-[var(--text-muted)]">현재 하는 일</div>
                  <p class="mt-1 text-[13px] leading-[1.5] text-[var(--text-strong)] break-words" title=${currentWork ?? ''}>${workPreview}</p>
                </div>

                <div class="flex flex-wrap gap-2">
                  <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-2)] px-2.5 py-1 text-[11px] text-[var(--text-muted)]">
                    최근 활동 ${lastActivityLabel}
                  </span>
                  ${isKeeper ? html`
                    <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-2)] px-2.5 py-1 text-[11px] text-[var(--text-muted)]">
                      컨텍스트 ${ctxPct != null ? `${ctxPct}% 사용` : '수집 전'}
                    </span>
                  ` : null}
                </div>

                ${isKeeper ? html`
                  <div class="rounded-xl border border-[var(--white-6)] bg-[var(--white-2)] px-3 py-3">
                    <div class="mb-2 flex items-center justify-between gap-3 text-[11px]">
                      <span class="text-[var(--text-muted)]">컨텍스트 사용량</span>
                      <strong class="text-[var(--text-strong)]">${ctxPct != null ? `${ctxPct}%` : '수집 전'}</strong>
                    </div>
                    <div class="h-2 overflow-hidden rounded-full bg-[var(--white-6)]">
                      <div
                        class="h-full rounded-full bg-linear-to-r from-[var(--accent)] to-[var(--ok)]"
                        style=${{ width: `${ctxPct ?? 0}%` }}
                      ></div>
                    </div>
                    <p class="mt-2 text-[11px] leading-[1.45] text-[var(--text-muted)]">키퍼가 현재 컨텍스트 창을 얼마나 쓰고 있는지 보여줍니다.</p>
                  </div>
                ` : null}
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
