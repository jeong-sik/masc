// Execution surface — live worker and keeper continuity monitoring

import { html } from 'htm/preact'
import { Card } from './common/card'
import { SurfaceSemanticIntro } from './common/semantic-layer'
import { StatusBadge } from './common/status-badge'
import { MitosisRing } from './common/mitosis-ring'
import { TimeAgo } from './common/time-ago'
import type { AgentMotionSnapshot } from './common/agent-motion'
import { openKeeperDetail } from './keeper-detail'
import { openAgentDetail } from './agent-detail'
import {
  agents,
  keepers,
  keeperLifecycles,
  staleKeepers,
  agentMotionMap,
} from '../store'
import type { Agent, Keeper, KeeperLifecycleState } from '../types'

const QUIET_AGENT_MS = 10 * 60 * 1000
const STALE_AGENT_MS = 20 * 60 * 1000
const HOT_KEEPER_RATIO = 0.8

type MonitorTone = 'ok' | 'warn' | 'bad'
type AgentMonitorState = 'working' | 'watching' | 'quiet' | 'offline'
type KeeperMonitorState = 'healthy' | 'warning' | 'critical'

interface AgentMonitorRow {
  agent: Agent
  motion: AgentMotionSnapshot
  lastSignalAt: string | null
  activeTaskCount: number
  state: AgentMonitorState
  tone: MonitorTone
  focus: string
  note: string
}

interface KeeperMonitorRow {
  keeper: Keeper
  lifecycle: KeeperLifecycleState | 'idle'
  state: KeeperMonitorState
  tone: MonitorTone
  focus: string
  note: string
}

type AttentionItem =
  | {
      kind: 'agent'
      key: string
      tone: MonitorTone
      title: string
      subtitle: string
      timestamp: string | null
      agent: Agent
    }
  | {
      kind: 'keeper'
      key: string
      tone: MonitorTone
      title: string
      subtitle: string
      timestamp: string | null
      keeper: Keeper
    }

function toEpoch(value: string | number | null | undefined): number {
  if (value == null) return 0
  const parsed = typeof value === 'number' ? value : Date.parse(value)
  return Number.isNaN(parsed) ? 0 : parsed
}

function toneRank(tone: MonitorTone): number {
  switch (tone) {
    case 'bad': return 2
    case 'warn': return 1
    default: return 0
  }
}

function agentStateLabel(state: AgentMonitorState): string {
  switch (state) {
    case 'working': return '작업 중'
    case 'watching': return '대기 중'
    case 'quiet': return '조용함'
    case 'offline': return '오프라인'
  }
}

function keeperStateLabel(state: KeeperMonitorState): string {
  switch (state) {
    case 'critical': return '위험'
    case 'warning': return '주의'
    default: return '정상'
  }
}

function formatContext(value?: number | null): string {
  if (typeof value !== 'number' || Number.isNaN(value)) return '—'
  return `${Math.round(value * 100)}%`
}

function keeperFocus(keeper: Keeper): string {
  return keeper.agent?.current_task?.trim()
    || keeper.skill_primary?.trim()
    || keeper.last_proactive_reason?.trim()
    || '현재 포커스 없음'
}

function keeperContinuity(keeper: Keeper): string {
  const pieces = [
    `Gen ${keeper.generation ?? '—'}`,
    `Turns ${keeper.turn_count ?? 0}`,
    `Handoffs ${keeper.handoff_count_total ?? 0}`,
  ]
  if ((keeper.compaction_count ?? 0) > 0) {
    pieces.push(`Compactions ${keeper.compaction_count}`)
  }
  return pieces.join(' · ')
}

function buildAgentRow(agent: Agent): AgentMonitorRow {
  const motion = agentMotionMap.value.get(agent.name.trim().toLowerCase())
    ?? { activeAssignedCount: 0, lastActivityAt: null, lastActivityText: null }
  const lastSignalAt = motion.lastActivityAt ?? agent.last_seen ?? null
  const signalAgeMs = lastSignalAt ? Math.max(0, Date.now() - toEpoch(lastSignalAt)) : Number.POSITIVE_INFINITY
  const hasWork = Boolean(agent.current_task?.trim()) || motion.activeAssignedCount > 0

  let state: AgentMonitorState = 'watching'
  let tone: MonitorTone = 'ok'
  let note = 'Healthy live signal'

  if (agent.status === 'offline' || agent.status === 'inactive') {
    state = 'offline'
    tone = 'bad'
    note = lastSignalAt ? 'Offline or inactive' : 'No recent presence'
  } else if (signalAgeMs > STALE_AGENT_MS) {
    state = 'quiet'
    tone = 'bad'
    note = hasWork ? 'Working without a fresh signal' : 'No fresh agent signal'
  } else if (hasWork) {
    state = 'working'
    tone = signalAgeMs > QUIET_AGENT_MS ? 'warn' : 'ok'
    note = signalAgeMs > QUIET_AGENT_MS ? 'Execution looks quiet for too long' : 'Task and live signal aligned'
  } else if (signalAgeMs > QUIET_AGENT_MS) {
    state = 'quiet'
    tone = 'warn'
    note = 'Quiet but still reachable'
  } else if (agent.status === 'idle') {
    state = 'watching'
    tone = 'ok'
    note = 'Standing by for the next task'
  }

  return {
    agent,
    motion,
    lastSignalAt,
    activeTaskCount: motion.activeAssignedCount,
    state,
    tone,
    focus:
      agent.current_task?.trim()
      || (motion.activeAssignedCount > 0
        ? `${motion.activeAssignedCount} claimed tasks waiting for explicit current_task`
        : motion.lastActivityText
          ?? 'Idle / waiting for assignment'),
    note,
  }
}

function buildKeeperRow(keeper: Keeper): KeeperMonitorRow {
  const lifecycle = keeperLifecycles.value.get(keeper.name) ?? 'idle'
  const isStale = staleKeepers.value.has(keeper.name)
  const ratio = keeper.context_ratio ?? 0

  let state: KeeperMonitorState = 'healthy'
  let tone: MonitorTone = 'ok'
  let note = '하트비트와 컨텍스트 상태가 안정적입니다'

  if (keeper.status === 'offline' || isStale || lifecycle === 'handoff-imminent') {
    state = 'critical'
    tone = 'bad'
    note = isStale
      ? '하트비트 지연'
      : lifecycle === 'handoff-imminent'
        ? '핸드오프 임박'
        : 'keeper 오프라인'
  } else if (
    lifecycle === 'preparing'
    || lifecycle === 'compacting'
    || ratio >= HOT_KEEPER_RATIO
  ) {
    state = 'warning'
    tone = 'warn'
    note = ratio >= HOT_KEEPER_RATIO
      ? '컨텍스트 압력이 높습니다'
      : lifecycle === 'compacting'
        ? '컴팩팅 진행 중'
        : '핸드오프 준비 중'
  }

  return {
    keeper,
    lifecycle,
    state,
    tone,
    focus: keeperFocus(keeper),
    note,
  }
}

function MonitorStat({
  label,
  value,
  color,
  caption,
}: {
  label: string
  value: string | number
  color?: string
  caption?: string
}) {
  return html`
    <div class="stat-card">
      <div class="stat-label">${label}</div>
      <div class="stat-value" style=${color ? `color:${color}` : ''}>${value}</div>
      ${caption ? html`<div class="monitor-stat-caption">${caption}</div>` : null}
    </div>
  `
}

function AttentionRow({ item }: { item: AttentionItem }) {
  const onClick =
    item.kind === 'agent'
      ? () => openAgentDetail(item.agent.name)
      : () => openKeeperDetail(item.keeper)

  return html`
    <button class="monitor-alert ${item.tone}" onClick=${onClick}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${item.title}</div>
        <div class="monitor-alert-subtitle">${item.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${item.tone}">
          ${item.kind === 'agent' ? '에이전트' : 'keeper'}
        </span>
        ${item.timestamp ? html`<span><${TimeAgo} timestamp=${item.timestamp} /></span>` : html`<span>신호 없음</span>`}
      </div>
    </button>
  `
}

function AgentWatchRow({ row }: { row: AgentMonitorRow }) {
  const { agent, motion } = row

  return html`
    <button class="monitor-row ${row.tone} state-${row.state}" onClick=${() => openAgentDetail(agent.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${agent.emoji ?? ''}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${agent.name}</span>
            ${agent.koreanName ? html`<span class="monitor-sub">${agent.koreanName}</span>` : null}
          </div>
          <div class="monitor-note">${row.note}</div>
        </div>
        <${MitosisRing} ratio=${agent.context_ratio} size=${34} stroke=${4} />
        <${StatusBadge} status=${agent.status} />
        <span class="monitor-pill ${row.tone} state-${row.state}">${agentStateLabel(row.state)}</span>
      </div>

      <div class="monitor-meta">
        ${row.lastSignalAt ? html`<span>신호 <${TimeAgo} timestamp=${row.lastSignalAt} /></span>` : html`<span>최근 신호 없음</span>`}
        <span>${row.activeTaskCount > 0 ? `활성 작업 ${row.activeTaskCount}개` : '활성 작업 없음'}</span>
        ${agent.model ? html`<span>${agent.model}</span>` : null}
        ${agent.last_seen ? html`<span>마지막 감지 <${TimeAgo} timestamp=${agent.last_seen} /></span>` : null}
      </div>

      <div class="monitor-focus">${row.focus}</div>
      ${motion.lastActivityText && motion.lastActivityText !== row.focus
        ? html`<div class="monitor-footnote">최근 상세: ${motion.lastActivityText}</div>`
        : null}
    </button>
  `
}

function KeeperWatchRow({ row }: { row: KeeperMonitorRow }) {
  const { keeper } = row

  return html`
    <button class="monitor-row ${row.tone} state-${row.state}" onClick=${() => openKeeperDetail(keeper)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${keeper.emoji ?? ''}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${keeper.name}</span>
            ${keeper.koreanName ? html`<span class="monitor-sub">${keeper.koreanName}</span>` : null}
          </div>
          <div class="monitor-note">${row.note}</div>
        </div>
        <${MitosisRing} ratio=${keeper.context_ratio} size=${34} stroke=${4} />
        <${StatusBadge} status=${keeper.status} />
        <span class="monitor-pill ${row.tone}">${keeperStateLabel(row.state)}</span>
      </div>

      <div class="monitor-meta">
        ${keeper.last_heartbeat ? html`<span>하트비트 <${TimeAgo} timestamp=${keeper.last_heartbeat} /></span>` : html`<span>하트비트 없음</span>`}
        <span>${keeperContinuity(keeper)}</span>
        <span>라이프사이클 ${row.lifecycle}</span>
        <span>컨텍스트 ${formatContext(keeper.context_ratio)}</span>
        ${keeper.model ? html`<span>${keeper.model}</span>` : null}
      </div>

      <div class="monitor-focus">${row.focus}</div>
      ${keeper.skill_reason ? html`<div class="monitor-footnote">스킬 라우팅: ${keeper.skill_reason}</div>` : null}
    </button>
  `
}

export function Execution() {
  const agentRows = [...agents.value]
    .map(buildAgentRow)
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      const taskDiff = b.activeTaskCount - a.activeTaskCount
      if (taskDiff !== 0) return taskDiff
      return toEpoch(b.lastSignalAt) - toEpoch(a.lastSignalAt)
    })

  const keeperRows = [...keepers.value]
    .map(buildKeeperRow)
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      const ratioDiff = (b.keeper.context_ratio ?? 0) - (a.keeper.context_ratio ?? 0)
      if (ratioDiff !== 0) return ratioDiff
      return toEpoch(b.keeper.last_heartbeat) - toEpoch(a.keeper.last_heartbeat)
    })

  const aliveRows = agentRows.filter(r => r.state !== 'offline')
  const offlineRows = agentRows.filter(r => r.state === 'offline')

  const onlineAgents = aliveRows.length
  const workingAgents = agentRows.filter(row => row.state === 'working').length
  const freshSignals = agentRows.filter(row => row.lastSignalAt && (Date.now() - toEpoch(row.lastSignalAt)) <= 120_000).length
  const agentAlerts = agentRows.filter(row => row.tone !== 'ok')
  const keeperAlerts = keeperRows.filter(row => row.tone !== 'ok')

  const attentionItems: AttentionItem[] = [
    ...keeperAlerts.map(row => ({
      kind: 'keeper' as const,
      key: `keeper-${row.keeper.name}`,
      tone: row.tone,
      title: row.keeper.name,
      subtitle: `${row.note} · ${row.focus}`,
      timestamp: row.keeper.last_heartbeat ?? null,
      keeper: row.keeper,
    })),
    ...agentAlerts.map(row => ({
      kind: 'agent' as const,
      key: `agent-${row.agent.name}`,
      tone: row.tone,
      title: row.agent.name,
      subtitle: `${row.note} · ${row.focus}`,
      timestamp: row.lastSignalAt,
      agent: row.agent,
    })),
  ]
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      return toEpoch(b.timestamp) - toEpoch(a.timestamp)
    })
    .slice(0, 8)

  return html`
    <div class="agents-monitor">
      <${SurfaceSemanticIntro} surfaceId="execution" />
      <div class="stats-grid">
        <${MonitorStat} label="온라인 worker" value=${onlineAgents} color="#4ade80" caption="활성 + 대기 실행 주체" />
        <${MonitorStat} label="지금 작업 중" value=${workingAgents} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${MonitorStat} label="신선한 신호" value=${freshSignals} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${MonitorStat} label="worker 경고" value=${agentAlerts.length} color=${agentAlerts.length > 0 ? '#fb7185' : '#4ade80'} caption="실행 주체 경고" />
        <${MonitorStat} label="연속성 경고" value=${keeperAlerts.length} color=${keeperAlerts.length > 0 ? '#fb7185' : '#4ade80'} caption="keeper 연속성 경고" />
      </div>

      <${Card} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">지금 실행 관점에서 먼저 봐야 할 대상</h2>
          <p class="monitor-subheadline">worker 드리프트와 keeper 연속성 위험은 여기서 함께 우선순위를 매기고, 아래 섹션에서 각각 따로 진단합니다.</p>
        </div>
        <div class="monitor-alert-list">
          ${attentionItems.length === 0
            ? html`<div class="empty-state">지금은 실행 경고가 없습니다</div>`
            : attentionItems.map(item => html`<${AttentionRow} key=${item.key} item=${item} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${Card} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">단기 실행 모니터</h2>
            <p class="monitor-subheadline">현재 살아 있는 worker를 먼저 묶어서, 누가 일을 잃었는지 오프라인 이력보다 먼저 보이게 합니다.</p>
          </div>
          <div class="monitor-list">
            ${aliveRows.length === 0
              ? html`<div class="empty-state">보이는 활성 worker가 없습니다</div>`
              : aliveRows.map(row => html`<${AgentWatchRow} key=${row.agent.name} row=${row} />`)}
          </div>
        <//>

        <${Card} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">장기 keeper 연속성</h2>
            <p class="monitor-subheadline">하트비트, 컨텍스트 압력, 핸드오프 상태를 worker 실행 드리프트와 분리해서 봅니다.</p>
          </div>
          <div class="monitor-list">
            ${keeperRows.length === 0
              ? html`<div class="empty-state">활성 keeper가 없습니다</div>`
              : keeperRows.map(row => html`<${KeeperWatchRow} key=${row.keeper.name} row=${row} />`)}
          </div>
        <//>

        <${Card} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">라이브 루프에서 빠진 worker</h2>
            <p class="monitor-subheadline">오프라인 row를 분리해서, 활성 실행 모니터가 묻히지 않게 합니다.</p>
          </div>
          <div class="monitor-list">
            ${offlineRows.length === 0
              ? html`<div class="empty-state">지금은 오프라인 worker가 없습니다</div>`
              : offlineRows.map(row => html`<${AgentWatchRow} key=${row.agent.name} row=${row} />`)}
          </div>
        <//>
      </div>
    </div>
  `
}

export const Agents = Execution
