// 소셜 표면 — 에이전트 관계 그래프와 활동 흐름

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { GraphView } from './social/graph-view'
import { fetchSocialGraph } from '../api'
import type { SocialGraphResponse, SocialGraphNode, SocialGraphTimelineEvent } from '../types'

const graphData = signal<SocialGraphResponse | null>(null)
const graphError = signal<string | null>(null)
const graphLoading = signal(false)

async function loadGraph() {
  if (graphLoading.value) return
  graphLoading.value = true
  graphError.value = null
  try {
    graphData.value = await fetchSocialGraph()
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
    default: return kind
  }
}

function eventKindLabel(kind: string): string {
  switch (kind) {
    case 'agent_joined': return '입장'
    case 'agent_left': return '퇴장'
    case 'broadcast': return '방송'
    case 'task_update': return '작업 변경'
    case 'board_post': return '게시'
    case 'board_comment': return '댓글'
    case 'board_vote': return '투표'
    case 'keeper_heartbeat': return '하트비트'
    case 'keeper_handoff': return '세대 교체'
    case 'mention': return '멘션'
    default: return kind
  }
}

function eventActor(event: SocialGraphTimelineEvent): string {
  const actor = event.actor as Record<string, unknown>
  if (actor?.id) return actor.id as string
  const payload = event.payload as Record<string, unknown>
  return (payload.agent as string) ?? (payload.author as string) ?? (payload.from as string) ?? ''
}

function eventSummary(event: SocialGraphTimelineEvent): string {
  const payload = event.payload as Record<string, unknown>
  const message = (payload.message as string) ?? (payload.content as string) ?? ''
  if (message) return message.length > 80 ? message.slice(0, 77) + '...' : message
  if (event.subject?.id) return `-> ${event.subject.id}`
  return event.kind
}

function StatsRow({ data }: { data: SocialGraphResponse }) {
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

function ActivityFeed({ events }: { events: SocialGraphTimelineEvent[] }) {
  if (events.length === 0) {
    return html`<div class="empty-state">최근 활동 이벤트가 없습니다.</div>`
  }
  return html`
    <div class="monitor-list">
      ${events.map(event => {
        const actor = eventActor(event)
        return html`
          <div class="monitor-row ok" key=${event.seq}>
            <div class="monitor-row-header">
              <div class="monitor-row-title">
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

function NodeLeaderboard({ nodes }: { nodes: SocialGraphNode[] }) {
  const agentNodes = nodes
    .filter(n => n.kind === 'agent')
    .sort((a, b) => b.weight - a.weight)
    .slice(0, 15)

  if (agentNodes.length === 0) {
    return html`<div class="empty-state">에이전트 노드가 없습니다.</div>`
  }

  const maxWeight = agentNodes[0]?.weight ?? 1

  return html`
    <div class="social-leaderboard">
      ${agentNodes.map((node, i) => {
        const pct = maxWeight > 0 ? (node.weight / maxWeight) * 100 : 0
        return html`
          <div class="social-leaderboard-row" key=${node.id}>
            <span class="social-leaderboard-rank">${i + 1}</span>
            <div class="social-leaderboard-info">
              <span class="social-leaderboard-name">${node.label}</span>
              <div class="social-leaderboard-bar-wrap">
                <div class="social-leaderboard-bar" style="width:${pct}%"></div>
              </div>
            </div>
            <span class="social-leaderboard-weight">${node.weight}</span>
            <span class="social-leaderboard-status ${node.status === 'offline' || node.status === 'retired' ? 'inactive' : 'active'}">${node.status}</span>
          </div>
        `
      })}
    </div>
  `
}

function KindBreakdown({ nodes }: { nodes: SocialGraphNode[] }) {
  const counts = new Map<string, number>()
  for (const node of nodes) {
    counts.set(node.kind, (counts.get(node.kind) ?? 0) + 1)
  }
  const sorted = [...counts.entries()].sort((a, b) => b[1] - a[1])

  return html`
    <div class="social-kind-breakdown">
      ${sorted.map(([kind, count]) => html`
        <div class="social-kind-chip" key=${kind}>
          <span class="social-kind-label">${kindLabel(kind)}</span>
          <span class="social-kind-count">${count}</span>
        </div>
      `)}
    </div>
  `
}

export { loadGraph as refreshSocial }

export function Social() {
  useEffect(() => { loadGraph() }, [])

  const data = graphData.value
  const error = graphError.value
  const loading = graphLoading.value

  if (loading && !data) {
    return html`<div class="loading-indicator">소셜 그래프 불러오는 중...</div>`
  }

  if (error && !data) {
    return html`
      <div class="agents-monitor">
        <${Card} title="오류" class="section" testId="social.error">
          <div class="empty-state">소셜 그래프를 불러올 수 없습니다: ${error}</div>
          <button class="control-btn ghost" onClick=${loadGraph}>다시 시도</button>
        <//>
      </div>
    `
  }

  if (!data) {
    return html`<div class="empty-state">데이터가 없습니다.</div>`
  }

  return html`
    <div class="agents-monitor">

      <${Card} title="소셜 그래프" class="section" semanticId="social.graph" testId="social.graph">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">에이전트 관계 그래프</h2>
          <p class="monitor-subheadline">에이전트, 작업, 결정 간의 상호작용을 시각화합니다. 노드 크기는 활동 빈도를 반영합니다.</p>
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
        <${Card} title="에이전트 활동 순위" class="section" semanticId="social.leaderboard" testId="social.leaderboard">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">에이전트 활동 순위</h2>
            <p class="monitor-subheadline">그래프 이벤트 빈도(weight)를 기준으로 정렬한 에이전트 순위입니다.</p>
          </div>
          <${NodeLeaderboard} nodes=${data.nodes} />
        <//>

        <${Card} title="노드 종류 분포" class="section" semanticId="social.kinds" testId="social.kinds">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">노드 종류</h2>
            <p class="monitor-subheadline">그래프에 포함된 노드를 종류별로 분류합니다.</p>
          </div>
          <${KindBreakdown} nodes=${data.nodes} />
        <//>

        <${Card} title="최근 활동" class="section" semanticId="social.timeline" testId="social.timeline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">타임라인</h2>
            <p class="monitor-subheadline">가장 최근의 소셜 이벤트를 시간순으로 보여줍니다.</p>
          </div>
          <${ActivityFeed} events=${[...data.timeline].reverse().slice(0, 30)} />
        <//>
      </div>
    </div>
  `
}
