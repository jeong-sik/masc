// Activity graph surface — runtime event graph + timeline

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { EmptyState, LoadingState } from './common/feedback-state'
import { ActionButton } from './common/button'
import { TimeAgo } from './common/time-ago'
import { Sparkline } from './common/sparkline'
import { GraphView } from './activity-graph-view'
import { ActivitySwimlane } from './activity-swimlane'
import { ActivityHeatmap } from './activity-heatmap'
import { CollapsibleSection } from './common/collapsible'
import { fetchActivityGraph } from '../api'
import { registerActivityRefresh } from '../sse-store'
import type { ActivityGraphResponse, ActivityGraphNode, ActivityGraphTimelineEvent } from '../types'

const graphData = signal<ActivityGraphResponse | null>(null)
const graphError = signal<string | null>(null)
const graphLoading = signal(false)
export const selectedTimeRange = signal<string>('all')

const TIME_RANGES: Array<{ value: string; label: string }> = [
  { value: '1h', label: '1시간' },
  { value: '6h', label: '6시간' },
  { value: '24h', label: '24시간' },
  { value: '7d', label: '7일' },
  { value: 'all', label: '전체' },
]

async function loadGraph() {
  if (graphLoading.value) return
  graphLoading.value = true
  graphError.value = null
  try {
    const since = selectedTimeRange.value !== 'all' ? selectedTimeRange.value : undefined
    graphData.value = await fetchActivityGraph(since)
  } catch (err) {
    graphError.value = err instanceof Error ? err.message : String(err)
  } finally {
    graphLoading.value = false
  }
}

function TimeRangeSelector() {
  const current = selectedTimeRange.value
  return html`
    <div class="flex gap-1.5 mb-3">
      ${TIME_RANGES.map(({ value, label }) => html`
        <button type="button" key=${value}
          class="px-3 py-1 text-xs rounded-full border cursor-pointer transition-all duration-150 ${
            current === value
              ? 'border-[rgba(200,168,78,0.5)] bg-[rgba(200,168,78,0.12)] text-[#e8d48b]'
              : 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)] hover:bg-[var(--white-8)]'
          }"
          onClick=${() => { selectedTimeRange.value = value; loadGraph() }}
        >${label}</button>
      `)}
    </div>
  `
}

function kindLabel(kind: string): string {
  switch (kind) {
    case 'agent': return '에이전트'
    case 'task': return '작업'
    case 'decision': return '결정'
    case 'operation': return '작전'
    case 'debate': return '토론'
    case 'post': return '게시글'
    case 'comment': return '댓글'
    default: return kind
  }
}

function eventKindLabel(kind: string): string {
  switch (kind) {
    case 'agent.joined': return '입장'
    case 'agent.left': return '퇴장'
    case 'message.broadcast': return '브로드캐스트'
    case 'message.mentioned': return '멘션'
    case 'task.created': return '작업 생성'
    case 'task.claimed': return '작업 점유'
    case 'task.started': return '작업 시작'
    case 'task.done': return '작업 완료'
    case 'task.released': return '작업 반환'
    case 'task.cancelled': return '작업 취소'
    case 'board.posted': return '게시'
    case 'board.commented': return '댓글'
    case 'board.voted': return '투표'
    case 'operation.started': return '세션 시작'
    case 'operation.resumed': return '세션 재개'
    case 'operation.finalized': return '세션 종료'
    case 'team.turn': return '팀 턴'
    case 'team.turn_failed': return '팀 턴 실패'
    default: return kind
  }
}

function eventActor(event: ActivityGraphTimelineEvent): string {
  const actor = event.actor as Record<string, unknown>
  if (actor?.id) return actor.id as string
  const payload = event.payload as Record<string, unknown>
  return (payload.agent as string) ?? (payload.author as string) ?? (payload.from as string) ?? ''
}

function eventSummary(event: ActivityGraphTimelineEvent): string {
  const payload = event.payload as Record<string, unknown>
  const message = (payload.message as string) ?? (payload.content as string) ?? ''
  if (message) return message.length > 80 ? `${message.slice(0, 77)}...` : message
  const taskTitle = payload.task_title as string | undefined
  if (taskTitle) return taskTitle
  const reason = payload.reason as string | undefined
  if (reason) return reason
  if (event.subject?.id) return `-> ${event.subject.id}`
  return event.kind
}

function StatsRow({ data }: { data: ActivityGraphResponse }) {
  const s = data.stats
  const h = data.stats_history ?? []
  const evSeries = h.map(b => b.events)
  const agSeries = h.map(b => b.active_agents)
  const tdSeries = h.map(b => b.tasks_done)

  function statCard(label: string, value: number, series: number[], color: string, highlight = false) {
    return html`
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] py-[15px] px-3.5">
        <div class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">${label}</div>
        <div class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums ${highlight ? 'text-[var(--ok)]' : ''}">${value}</div>
        ${series.length >= 2 ? html`<div class="mt-2"><${Sparkline} values=${series} color=${color} /></div>` : null}
      </div>
    `
  }

  return html`
    <div class="stats-grid grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-3 mb-4">
      ${statCard('노드', s.node_count ?? 0, evSeries, '#94a3b8')}
      ${statCard('엣지', s.edge_count ?? 0, evSeries, '#64748b')}
      ${statCard('에이전트', s.agent_count ?? 0, agSeries, '#22d3ee')}
      ${statCard('활성', s.active_agents ?? 0, agSeries, '#4ade80', true)}
      ${statCard('작업', s.task_count ?? 0, tdSeries, '#fbbf24')}
      ${statCard('이벤트', s.event_count ?? 0, evSeries, '#a78bfa')}
    </div>
  `
}

function ActivityFeed({ events }: { events: ActivityGraphTimelineEvent[] }) {
  if (events.length === 0) {
    return html`<${EmptyState} message="최근 실행 이벤트가 없습니다." compact />`
  }
  return html`
    <div class="flex flex-col gap-3">
      ${events.map(event => {
        const actor = eventActor(event)
        return html`
          <div class="monitor-row rounded-xl p-4 ok" key=${event.seq}>
            <div class="monitor-row rounded-xl-header">
              <div class="min-w-0">
                <div class="flex items-center gap-2 flex-wrap">
                  <span class="monitor-title">${actor || '(unknown)'}</span>
                  <span class="monitor-sub">${eventKindLabel(event.kind)}</span>
                </div>
                <div class="monitor-note">${eventSummary(event)}</div>
              </div>
              <span class="monitor-pill ok inline-flex items-center rounded-full px-2 py-[3px] text-[11px] uppercase tracking-[0.06em]">${eventKindLabel(event.kind)}</span>
            </div>
            <div class="flex flex-wrap gap-x-3 gap-y-2 mt-3 text-[var(--text-muted)] text-[13px]">
              <span>${event.room_id}</span>
              ${event.ts_iso ? html`<span><${TimeAgo} timestamp=${event.ts_iso} /></span>` : null}
              ${event.tags.length > 0 ? html`<span>${event.tags.join(', ')}</span>` : null}
            </div>
          </div>
        `
      })}
    </div>
  `
}

function nodeScore(node: ActivityGraphNode): number {
  return node.semantic_weight ?? node.weight
}

function NodeLeaderboard({ nodes }: { nodes: ActivityGraphNode[] }) {
  const agentNodes = nodes
    .filter(n => n.kind === 'agent')
    .sort((a, b) => nodeScore(b) - nodeScore(a))
    .slice(0, 15)

  if (agentNodes.length === 0) {
    return html`<${EmptyState} message="활동 집계에 포함된 에이전트가 없습니다." compact />`
  }

  const maxScore = nodeScore(agentNodes[0]!) || 1

  return html`
    <div class="flex flex-col gap-1.5">
      ${agentNodes.map((node, i) => {
        const score = nodeScore(node)
        const pct = maxScore > 0 ? (score / maxScore) * 100 : 0
        return html`
          <div class="flex items-center gap-[10px] py-2 px-3 rounded-[10px] bg-[rgba(15,23,42,0.5)] border border-solid border-[var(--slate-gray-8)]" key=${node.id}>
            <span class="w-[22px] text-center text-sm font-bold text-text-slate">${i + 1}</span>
            <div class="flex-1 flex flex-col gap-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="text-base font-semibold text-[var(--text-near-white)] whitespace-nowrap overflow-hidden text-ellipsis">${node.label}</span>
                <span class="text-[11px] text-[var(--text-muted)]">${node.weight}회</span>
              </div>
              <div class="h-1 rounded-sm bg-[var(--slate-gray-10)] overflow-hidden">
                <div class="h-full rounded-sm bg-[var(--cyan)] transition-[width] duration-300 ease-in-out" style="width:${pct}%"></div>
              </div>
            </div>
            <span class="text-sm font-semibold text-text-slate-light min-w-[32px] text-right">${score.toFixed(1)}</span>
            <span class="text-[11px] py-0.5 px-[7px] rounded-md ${node.status === 'offline' || node.status === 'retired' ? 'text-[var(--text-slate)] bg-[var(--slate-gray-10)]' : 'text-[var(--ok)] bg-[var(--ok-10)]'}">${node.status}</span>
          </div>
        `
      })}
    </div>
  `
}

function KindBreakdown({ nodes }: { nodes: ActivityGraphNode[] }) {
  const counts = new Map<string, number>()
  for (const node of nodes) {
    counts.set(node.kind, (counts.get(node.kind) ?? 0) + 1)
  }
  const sorted = [...counts.entries()].sort((a, b) => b[1] - a[1])

  if (sorted.length === 0) {
    return html`<${EmptyState} message="분석할 노드 종류가 없습니다." compact />`
  }

  return html`
    <div class="flex flex-wrap gap-2">
      ${sorted.map(([kind, count]) => html`
        <div class="flex items-center gap-1.5 py-1.5 px-3 bg-[var(--panel-dark-60)] border border-[var(--slate-gray-12)] rounded-lg" key=${kind}>
          <span class="text-sm text-text-slate-light">${kindLabel(kind)}</span>
          <span class="text-base font-bold text-[var(--text-near-white)]">${count}</span>
        </div>
      `)}
    </div>
  `
}

function EmptyActivityGraph() {
  return html`
    <div class="flex flex-col gap-5">
      <${Card} title="활동 그래프" class="section mb-4" testId="activity_graph.graph">
        <div class="mb-4">
          <h2 class="monitor-headline">활동 그래프가 비어 있습니다</h2>
          <p class="monitor-subheadline">이 뷰는 런타임 실행 이벤트를 읽어 그래프를 그립니다. 지금은 기록된 이벤트가 없어 화면이 비어 있습니다.</p>
        </div>
        <${EmptyState} message="아직 claim, broadcast, team-session, board 같은 실행 이벤트가 activity feed에 기록되지 않았습니다." compact />
      <//>
    </div>
  `
}

export { loadGraph as refreshActivityGraph }

export function ActivityGraphSurface() {
  useEffect(() => {
    loadGraph()
    registerActivityRefresh(loadGraph)
  }, [])

  const data = graphData.value
  const error = graphError.value
  const loading = graphLoading.value

  if (loading && !data) {
    return html`<${LoadingState}>활동 그래프 불러오는 중...<//>`
  }

  if (error && !data) {
    return html`
      <div class="flex flex-col gap-5">
        <${Card} title="오류" class="section mb-4" testId="activity_graph.error">
          <${EmptyState} message=${'활동 그래프를 불러올 수 없습니다: ' + error} compact />
          <${ActionButton} variant="ghost" onClick=${loadGraph}>다시 시도<//>
        <//>
      </div>
    `
  }

  if (!data) {
    return html`<${EmptyState} message="활동 데이터가 없습니다." compact />`
  }

  if ((data.stats.event_count ?? 0) === 0) {
    return html`<${EmptyActivityGraph} />`
  }

  return html`
    <div class="flex flex-col gap-5">

      <${Card} title="활동 그래프" class="section mb-4" testId="activity_graph.graph">
        <div class="mb-4">
          <h2 class="monitor-headline">실행 이벤트 관계 그래프</h2>
          <p class="monitor-subheadline">에이전트, 작업, 결정, 운영 이벤트 간의 연결을 시각화합니다. 노드 크기는 의미적 중요도를 반영합니다. 노드를 클릭하면 상세 정보를 확인할 수 있습니다.</p>
        </div>
        <${TimeRangeSelector} />
        <${StatsRow} data=${data} />
        <${GraphView} data=${data} />
        <div class="flex flex-wrap gap-x-3 gap-y-2 mt-3 text-[var(--text-muted)] text-[13px]">
          <span>생성 시각: ${data.generated_at}</span>
          <span>데이터 범위: 최근 ${data.window.limit}건 이벤트</span>
          ${selectedTimeRange.value !== 'all' ? html`<span>필터: ${TIME_RANGES.find(r => r.value === selectedTimeRange.value)?.label}</span>` : null}
          ${data.window.room_id ? html`<span>room: ${data.window.room_id}</span>` : null}
        </div>
      <//>

      <${CollapsibleSection} title="에이전트 타임라인" open=${true}>
        <${ActivitySwimlane} />
      <//>

      <div class="grid grid-cols-[minmax(0,1.08fr)_minmax(0,0.96fr)_minmax(0,0.88fr)] gap-4">
        <${Card} title="활동 주체 순위" class="section mb-4" testId="activity_graph.leaderboard">
          <div class="mb-4">
            <h2 class="monitor-headline">활동 주체 순위</h2>
            <p class="monitor-subheadline">의미적 중요도 기준 정렬입니다. 작업 완료, 의사결정, 핸드오프가 단순 입퇴장보다 높게 평가됩니다.</p>
          </div>
          <${NodeLeaderboard} nodes=${data.nodes} />
        <//>

        <${Card} title="노드 종류 분포" class="section mb-4" testId="activity_graph.kinds">
          <div class="mb-4">
            <h2 class="monitor-headline">노드 종류</h2>
            <p class="monitor-subheadline">그래프에 포함된 노드를 종류별로 분류합니다.</p>
          </div>
          <${KindBreakdown} nodes=${data.nodes} />
        <//>

        <${Card} title="최근 실행 이벤트" class="section mb-4" testId="activity_graph.timeline">
          <div class="mb-4">
            <h2 class="monitor-headline">타임라인</h2>
            <p class="monitor-subheadline">가장 최근의 실행 이벤트를 시간순으로 보여줍니다.</p>
          </div>
          <${ActivityFeed} events=${[...data.timeline].reverse().slice(0, 30)} />
        <//>
      </div>

      ${data.timeline.length > 0 ? html`
        <${CollapsibleSection} title="활동 히트맵" open=${false}>
          <${ActivityHeatmap} data=${data} />
        <//>
      ` : null}
    </div>
  `
}
