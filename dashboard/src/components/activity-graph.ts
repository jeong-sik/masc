// Activity graph surface — runtime event graph + timeline

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { GraphView } from './activity-graph-view'
import { fetchActivityGraph } from '../api'
import type { ActivityGraphResponse, ActivityGraphNode, ActivityGraphTimelineEvent } from '../types'

const graphData = signal<ActivityGraphResponse | null>(null)
const graphError = signal<string | null>(null)
const graphLoading = signal(false)

async function loadGraph() {
  if (graphLoading.value) return
  graphLoading.value = true
  graphError.value = null
  try {
    graphData.value = await fetchActivityGraph()
  } catch (err) {
    graphError.value = err instanceof Error ? err.message : String(err)
  } finally {
    graphLoading.value = false
  }
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
  return html`
    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">노드</div>
        <div class="stat-value">${s.node_count}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">엣지</div>
        <div class="stat-value">${s.edge_count}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">에이전트</div>
        <div class="stat-value">${s.agent_count}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">활성</div>
        <div class="stat-value" class="text-[var(--ok)]">${s.active_agents}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">작업</div>
        <div class="stat-value">${s.task_count}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">이벤트</div>
        <div class="stat-value">${s.event_count}</div>
      </div>
    </div>
  `
}

function ActivityFeed({ events }: { events: ActivityGraphTimelineEvent[] }) {
  if (events.length === 0) {
    return html`<div class="empty-state">최근 실행 이벤트가 없습니다.</div>`
  }
  return html`
    <div class="monitor-list">
      ${events.map(event => {
        const actor = eventActor(event)
        return html`
          <div class="monitor-row p-3.5 ok" key=${event.seq}>
            <div class="monitor-row-header">
              <div class="min-w-0">
                <div class="monitor-name-line">
                  <span class="monitor-title">${actor || '(unknown)'}</span>
                  <span class="monitor-sub">${eventKindLabel(event.kind)}</span>
                </div>
                <div class="monitor-note">${eventSummary(event)}</div>
              </div>
              <span class="monitor-pill ok">${eventKindLabel(event.kind)}</span>
            </div>
            <div class="monitor-meta">
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

function NodeLeaderboard({ nodes }: { nodes: ActivityGraphNode[] }) {
  const agentNodes = nodes
    .filter(n => n.kind === 'agent')
    .sort((a, b) => b.weight - a.weight)
    .slice(0, 15)

  if (agentNodes.length === 0) {
    return html`<div class="empty-state">활동 집계에 포함된 에이전트가 없습니다.</div>`
  }

  const maxWeight = agentNodes[0]?.weight ?? 1

  return html`
    <div class="activity-graph-leaderboard">
      ${agentNodes.map((node, i) => {
        const pct = maxWeight > 0 ? (node.weight / maxWeight) * 100 : 0
        return html`
          <div class="activity-graph-leaderboard-row" key=${node.id}>
            <span class="activity-graph-leaderboard-rank">${i + 1}</span>
            <div class="activity-graph-leaderboard-info">
              <span class="activity-graph-leaderboard-name">${node.label}</span>
              <div class="activity-graph-leaderboard-bar-wrap">
                <div class="activity-graph-leaderboard-bar" style="width:${pct}%"></div>
              </div>
            </div>
            <span class="activity-graph-leaderboard-weight">${node.weight}</span>
            <span class="activity-graph-leaderboard-status ${node.status === 'offline' || node.status === 'retired' ? 'inactive' : 'active'}">${node.status}</span>
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
    return html`<div class="empty-state">분석할 노드 종류가 없습니다.</div>`
  }

  return html`
    <div class="activity-graph-kind-breakdown">
      ${sorted.map(([kind, count]) => html`
        <div class="activity-graph-kind-chip" key=${kind}>
          <span class="activity-graph-kind-label">${kindLabel(kind)}</span>
          <span class="activity-graph-kind-count">${count}</span>
        </div>
      `)}
    </div>
  `
}

function EmptyActivityGraph() {
  return html`
    <div class="agents-monitor">
      <${Card} title="활동 그래프" class="section" testId="activity_graph.graph">
        <div class="mb-3.5">
          <h2 class="monitor-headline">활동 그래프가 비어 있습니다</h2>
          <p class="monitor-subheadline">이 뷰는 런타임 실행 이벤트를 읽어 그래프를 그립니다. 지금은 기록된 이벤트가 없어 화면이 비어 있습니다.</p>
        </div>
        <div class="empty-state">
          아직 claim, broadcast, team-session, board 같은 실행 이벤트가 activity feed에 기록되지 않았습니다.
        </div>
      <//>
    </div>
  `
}

export { loadGraph as refreshActivityGraph }

export function ActivityGraphSurface() {
  useEffect(() => { loadGraph() }, [])

  const data = graphData.value
  const error = graphError.value
  const loading = graphLoading.value

  if (loading && !data) {
    return html`<div class="loading-indicator">활동 그래프 불러오는 중...</div>`
  }

  if (error && !data) {
    return html`
      <div class="agents-monitor">
        <${Card} title="오류" class="section" testId="activity_graph.error">
          <div class="empty-state">활동 그래프를 불러올 수 없습니다: ${error}</div>
          <button class="control-btn ghost" onClick=${loadGraph}>다시 시도</button>
        <//>
      </div>
    `
  }

  if (!data) {
    return html`<div class="empty-state">활동 데이터가 없습니다.</div>`
  }

  if ((data.stats.event_count ?? 0) === 0) {
    return html`<${EmptyActivityGraph} />`
  }

  return html`
    <div class="agents-monitor">

      <${Card} title="활동 그래프" class="section" testId="activity_graph.graph">
        <div class="mb-3.5">
          <h2 class="monitor-headline">실행 이벤트 관계 그래프</h2>
          <p class="monitor-subheadline">에이전트, 작업, 결정, 운영 이벤트 간의 연결을 최근 실행 이벤트 기준으로 시각화합니다. 노드 크기는 활동 빈도를 반영합니다.</p>
        </div>
        <${StatsRow} data=${data} />
        <${GraphView} data=${data} />
        <div class="monitor-meta" class="mt-2">
          <span>생성 시각: ${data.generated_at}</span>
          <span>데이터 범위: 최근 ${data.window.limit}건 이벤트</span>
          ${data.window.room_id ? html`<span>room: ${data.window.room_id}</span>` : null}
        </div>
      <//>

      <div class="agents-workbench">
        <${Card} title="활동 주체 순위" class="section" testId="activity_graph.leaderboard">
          <div class="mb-3.5">
            <h2 class="monitor-headline">활동 주체 순위</h2>
            <p class="monitor-subheadline">그래프 이벤트 빈도(weight)를 기준으로 정렬한 최근 활동 주체 순위입니다.</p>
          </div>
          <${NodeLeaderboard} nodes=${data.nodes} />
        <//>

        <${Card} title="노드 종류 분포" class="section" testId="activity_graph.kinds">
          <div class="mb-3.5">
            <h2 class="monitor-headline">노드 종류</h2>
            <p class="monitor-subheadline">그래프에 포함된 노드를 종류별로 분류합니다.</p>
          </div>
          <${KindBreakdown} nodes=${data.nodes} />
        <//>

        <${Card} title="최근 실행 이벤트" class="section" testId="activity_graph.timeline">
          <div class="mb-3.5">
            <h2 class="monitor-headline">타임라인</h2>
            <p class="monitor-subheadline">가장 최근의 실행 이벤트를 시간순으로 보여줍니다.</p>
          </div>
          <${ActivityFeed} events=${[...data.timeline].reverse().slice(0, 30)} />
        <//>
      </div>
    </div>
  `
}
