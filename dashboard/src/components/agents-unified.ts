// MASC Dashboard — Unified Agents Tab
// Absorbs: agent-roster + execution + keeper-roster into one view with chip toggle.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { CountBadge } from './common/badge'
import { navigate, route } from '../router'
import { agents, keepers } from '../store'
import { missionKeeperBriefs } from '../mission-signals'
import { AgentRoster } from './agent-roster'
import { AgentProfile } from './agent-profile'
type AgentsView = 'all' | 'agents' | 'keepers'

const activeView = signal<AgentsView>('all')

/** Determine which agents have keeper runtime from keepers store + mission snapshot.
 *  Adds BOTH name ("dm-keeper") and agent_name ("keeper-dm-keeper-agent")
 *  so agent list filtering matches regardless of which key the agent uses. */
function keeperNameSet(): Set<string> {
  const names = new Set<string>()
  for (const k of keepers.value) {
    const typed = k as { name?: string; agent_name?: string }
    if (typed.name) names.add(typed.name)
    if (typed.agent_name) names.add(typed.agent_name)
  }
  for (const kb of missionKeeperBriefs.value) {
    const typed = kb as { name?: string; agent_name?: string }
    if (typed.name) names.add(typed.name)
    if (typed.agent_name) names.add(typed.agent_name)
  }
  return names
}

const CHIPS: { id: AgentsView; label: string; description: string }[] = [
  { id: 'all', label: '전체 보기', description: '등록된 모든 런타임을 함께 봅니다.' },
  { id: 'agents', label: '일반 에이전트', description: '키퍼가 연결되지 않은 일반 에이전트만 봅니다.' },
  { id: 'keepers', label: '키퍼 런타임', description: '장기 컨텍스트를 유지하는 상주 런타임만 봅니다.' },
]

export function AgentsUnified() {
  // If an agent name is in the route params, show the profile page
  const agentParam = route.value.params.agent as string | undefined
  if (agentParam) {
    return html`<${AgentProfile} name=${agentParam} />`
  }

  const viewParam = route.value.params.view as string | undefined
  const routeView =
    viewParam === 'keepers' || viewParam === 'agents'
      ? viewParam
      : null
  const currentView = routeView ?? activeView.value

  useEffect(() => {
    if (routeView && activeView.value !== routeView) {
      activeView.value = routeView
    }
  }, [routeView])

  // Compute counts for chip badges.
  // When agents store is empty (not yet loaded), fall back to keepers store
  // so the tab badge matches Room Pulse sidebar counts.
  const kNames = keeperNameSet()
  const agentList = agents.value
  const totalCount = agentList.length
  const keeperCountFromAgents = agentList.filter((a: { name: string }) => kNames.has(a.name)).length
  const keeperCountFallback = Math.max(keepers.value.length, missionKeeperBriefs.value.length)
  const keeperCount = totalCount > 0 ? keeperCountFromAgents : keeperCountFallback
  const agentOnlyCount = totalCount > 0 ? totalCount - keeperCountFromAgents : 0
  const currentViewMeta = CHIPS.find(chip => chip.id === currentView) ?? {
    id: 'all' as const,
    label: '전체 보기',
    description: '등록된 모든 런타임을 함께 봅니다.',
  }

  function chipCount(id: AgentsView): number | null {
    if (id === 'all') return totalCount
    if (id === 'agents') return agentOnlyCount
    if (id === 'keepers') return keeperCount
    return null
  }

  const currentViewSummary =
    currentView === 'all'
      ? `일반 에이전트 ${agentOnlyCount}개와 키퍼 런타임 ${keeperCount}개를 함께 보여줍니다.`
      : currentView === 'agents'
        ? `지속 실행용 키퍼가 없는 일반 에이전트 ${agentOnlyCount}개만 표시합니다.`
        : `장기 컨텍스트를 유지하는 키퍼 런타임 ${keeperCount}개만 표시합니다.`

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex gap-1 p-1 bg-[var(--white-3)] rounded-lg w-fit">
        ${CHIPS.map(c => html`
          <button type="button"
            key=${c.id}
            class="flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium transition-all cursor-pointer border-0 ${currentView === c.id ? 'bg-[var(--accent-soft)] text-[var(--accent)]' : 'bg-transparent text-[var(--text-muted)] hover:text-[var(--text-body)]'}"
            title=${c.description}
            onClick=${() => {
              activeView.value = c.id
              navigate('status', c.id === 'all' ? { section: 'agents' } : { section: 'agents', view: c.id })
            }}
          >
            ${c.label}
            ${chipCount(c.id) != null ? html`<${CountBadge}>${chipCount(c.id)}<//>` : null}
          </button>
        `)}
      </div>
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] px-4 py-3 text-[12px] leading-[1.5] text-[var(--text-muted)]">
        <strong class="mr-2 text-[var(--text-strong)]">${currentViewMeta.label}</strong>
        <span>${currentViewMeta.description} ${currentViewSummary}</span>
      </div>

      <${AgentRoster}
        keeperFilter=${currentView === 'keepers' ? 'keeper-only'
          : currentView === 'agents' ? 'agent-only'
          : 'all'}
      />
    </div>
  `
}
