import { html } from 'htm/preact'
import { ActionButton } from '../common/button'
import { StatusChip } from '../common/status-chip'
import type {
  Agent,
  CommandPlaneChainOverlay,
  CommandPlaneSurface,
  CommandPlaneSwarmWorker,
  Keeper,
  OperatorLinkedAutoresearch,
  OperatorRecommendedAction,
  OperatorResidentJudgeRuntime,
  OperatorWorkerCard,
} from '../../types'
import { setCommandPlaneSurface } from '../../command-store'
import { navigate } from '../../router'
import {
  displayStatus,
  formatElapsed,
  formatPercent,
  historySummary,
  prettyJson,
  relativeTime,
  sessionStatusTone,
  surfaceRouteParams,
  toneClass,
} from './helpers'
import {
  runtimeJudgeLabel,
  runtimeJudgeTone,
} from '../ops/helpers'
import type { WarRoomWorkerView, WarRoomPresenceView, WarRoomFeedItem } from './war-room-panels'
import { truncate } from '../../lib/truncate'

export { truncate }

export function timestampSortValue(iso?: string | null): number {
  if (!iso) return 0
  const parsed = Date.parse(iso)
  return Number.isNaN(parsed) ? 0 : parsed
}

export function secondsAgoLabel(seconds?: number | null): string {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds)) return '정보 없음'
  if (seconds < 60) return `${Math.round(seconds)}초 전`
  if (seconds < 3600) return `${Math.round(seconds / 60)}분 전`
  return `${Math.round(seconds / 3600)}시간 전`
}

export function summarizeSessionEvent(event: Record<string, unknown>): {
  timestamp?: string | null
  title: string
  detail: string
} {
  const timestamp =
    typeof event.timestamp === 'string'
      ? event.timestamp
      : typeof event.created_at === 'string'
        ? event.created_at
        : typeof event.at === 'string'
          ? event.at
          : null
  const title =
    typeof event.title === 'string'
      ? event.title
      : typeof event.kind === 'string'
        ? event.kind
        : typeof event.event === 'string'
          ? event.event
          : '세션 이벤트'
  const detail =
    typeof event.detail === 'string'
      ? event.detail
      : typeof event.summary === 'string'
        ? event.summary
        : prettyJson(event)
  return {
    timestamp,
    title,
    detail: truncate(detail, 220),
  }
}

export function swarmWorkerView(worker: CommandPlaneSwarmWorker): WarRoomWorkerView {
  const markers = [
    worker.current_task_matches_run ? 'current' : 'drift',
    worker.claim_marker_seen ? 'claim' : 'no-claim',
    worker.done_marker_seen ? 'done' : 'no-done',
    worker.final_marker_seen ? 'final' : 'no-final',
  ]
  return {
    key: `swarm:${worker.name}`,
    name: worker.name,
    role: worker.role,
    lane: worker.lane,
    status: worker.status,
    source: 'swarm',
    task: worker.current_task ?? worker.bound_task_title ?? worker.bound_task_id ?? '할당 없음',
    heartbeat:
      worker.heartbeat_age_sec != null
        ? `${Math.round(worker.heartbeat_age_sec)}초`
        : worker.heartbeat_fresh
          ? '정상'
          : '정보 없음',
    detail: [
      worker.bound_task_status ?? null,
      worker.detachment_member ? '분견대 소속' : null,
      worker.squad_member ? '분대 소속' : null,
    ].filter(Boolean).join(' · ') || '스웜 실시간 카드',
    markers,
    note: worker.last_message?.content ?? null,
  }
}

export function operatorWorkerView(worker: OperatorWorkerCard, index: number): WarRoomWorkerView {
  const name = worker.actor ?? worker.spawn_role ?? `워커-${index + 1}`
  const role = worker.spawn_role ?? worker.worker_class ?? worker.spawn_agent ?? '워커'
  const lane = worker.lane_id ?? worker.capsule_mode ?? worker.control_domain ?? '세션'
  const markers = [
    worker.has_turn ? 'turn' : 'silent',
    worker.empty_note_turn_count > 0 ? `empty:${worker.empty_note_turn_count}` : 'noted',
    worker.turn_count > 0 ? `turns:${worker.turn_count}` : 'turns:0',
  ]
  return {
    key: `session:${name}:${index}`,
    name,
    role,
    lane,
    status: worker.status,
    source: 'session',
    task: worker.task_profile ?? worker.runtime_pool ?? '세션 레인',
    heartbeat: worker.last_turn_ts_iso ? relativeTime(worker.last_turn_ts_iso) : '정보 없음',
    detail: [
      worker.spawn_agent ?? null,
      worker.spawn_model ?? null,
      worker.routing_confidence != null ? formatPercent(worker.routing_confidence) : null,
    ].filter(Boolean).join(' · ') || '세션 요약 카드',
    markers,
    note: worker.routing_reason ?? null,
  }
}

export function agentPresenceView(agent: Agent): WarRoomPresenceView {
  return {
    key: `agent:${agent.name}`,
    name: agent.name,
    role: agent.agent_type ?? 'agent',
    source: 'agent',
    status: displayStatus(agent.status),
    tone: toneClass(sessionStatusTone(agent.status)) as 'ok' | 'warn' | 'bad',
    task: agent.current_task ?? '대기 중',
    signal: relativeTime(agent.last_seen),
    detail: [
      agent.model ?? null,
      agent.capabilities?.slice(0, 2).join(', ') || null,
    ].filter(Boolean).join(' · ') || '글로벌 agent roster',
    chips: [
      agent.context_ratio != null ? `ctx ${Math.round(agent.context_ratio * 100)}%` : 'ctx n/a',
      agent.status ?? '(unknown)',
    ],
    note: agent.personalityHint ?? null,
  }
}

export function keeperPresenceView(keeper: Keeper): WarRoomPresenceView {
  const tone =
    keeper.status === 'offline' || keeper.status === 'inactive'
      ? 'bad'
      : keeper.status === 'active' || keeper.status === 'healthy'
        ? 'ok'
        : 'warn'
  return {
    key: `keeper:${keeper.name}`,
    name: keeper.name,
    role: keeper.runtime_class ?? 'keeper',
    source: 'keeper',
    status: displayStatus(keeper.status),
    tone,
    task:
      keeper.active_goal_ids?.[0]
      ?? keeper.last_proactive_reason
      ?? keeper.agent?.current_task
      ?? 'standby',
    signal: keeper.last_heartbeat ? relativeTime(keeper.last_heartbeat) : secondsAgoLabel(keeper.last_turn_ago_s),
    detail: [
      keeper.autonomy_level ?? null,
      keeper.active_model ?? keeper.primary_model ?? keeper.model ?? null,
      keeper.keepalive_running ? 'keepalive on' : null,
    ].filter(Boolean).join(' · ') || '글로벌 keeper roster',
    chips: [
      keeper.context_ratio != null ? `ctx ${Math.round(keeper.context_ratio * 100)}%` : 'ctx n/a',
      keeper.latest_tool_call_count != null ? `tools ${keeper.latest_tool_call_count}` : 'tools n/a',
    ],
    note: keeper.diagnostic?.summary ?? keeper.last_proactive_preview ?? keeper.recent_output_preview ?? null,
  }
}

export function residentPresenceView(runtime: OperatorResidentJudgeRuntime): WarRoomPresenceView {
  return {
    key: `resident:${runtime.keeper_name ?? 'judge'}`,
    name: runtime.keeper_name ?? 'resident-judge',
    role: 'resident judge',
    source: 'resident',
    status: runtimeJudgeLabel(runtime),
    tone: runtimeJudgeTone(runtime),
    task: runtime.judge_online ? 'live guidance' : 'standby',
    signal: runtime.generated_at ? relativeTime(runtime.generated_at) : '정보 없음',
    detail: [
      runtime.model_used ?? null,
      runtime.last_error ? 'error' : null,
    ].filter(Boolean).join(' · ') || 'resident runtime',
    chips: [
      runtime.enabled ? 'enabled' : 'disabled',
      runtime.judge_online ? 'online' : 'offline',
    ],
    note: runtime.last_error ?? null,
  }
}

export function recommendationTone(item: OperatorRecommendedAction): 'ok' | 'warn' | 'bad' {
  return toneClass(item.severity) as 'ok' | 'warn' | 'bad'
}

export function buildFeedItems({
  swarmMessages,
  traceEvents,
  chainOverlay,
  linkedAutoresearch,
  selectedSession,
  activeRecommendedActions,
  attentionItems,
}: {
  swarmMessages: Array<{ seq: number; from: string; content: string; timestamp: string }>
  traceEvents: Array<{ event_id: string; event_type: string; actor?: string | null; source?: string; timestamp?: string; detail?: unknown }>
  chainOverlay: CommandPlaneChainOverlay | null
  linkedAutoresearch?: OperatorLinkedAutoresearch | null
  selectedSession?: { session_id: string; recent_events?: Record<string, unknown>[] } | null
  activeRecommendedActions: OperatorRecommendedAction[]
  attentionItems: Array<{ kind: string; severity: string; summary: string; target_type: string; target_id?: string | null }>
}): WarRoomFeedItem[] {
  const feed: WarRoomFeedItem[] = []

  for (const message of swarmMessages.slice(0, 8)) {
    feed.push({
      key: `message:${message.seq}`,
      title: message.from,
      detail: truncate(message.content, 280),
      meta: `메시지 · seq ${message.seq}`,
      source: 'swarm',
      tone: 'ok',
      timestamp: message.timestamp,
      sortTs: timestampSortValue(message.timestamp),
    })
  }

  for (const event of traceEvents.slice(0, 8)) {
    feed.push({
      key: `trace:${event.event_id}`,
      title: event.event_type,
      detail: truncate(prettyJson(event.detail), 280),
      meta: [event.actor ?? null, event.source ?? null].filter(Boolean).join(' · ') || 'trace',
      source: 'trace',
      tone: event.event_type.includes('error') || event.event_type.includes('fail') ? 'bad' : 'warn',
      timestamp: event.timestamp,
      sortTs: timestampSortValue(event.timestamp),
    })
  }

  if (chainOverlay?.history) {
    feed.push({
      key: `chain:${chainOverlay.operation.operation_id}:${chainOverlay.history.event}`,
      title: `Chain · ${chainOverlay.history.event}`,
      detail: truncate(historySummary(chainOverlay.history), 260),
      meta: chainOverlay.history.chain_id ?? chainOverlay.operation.operation_id,
      source: 'chain',
      tone: chainOverlay.history.event.includes('error') || chainOverlay.history.event.includes('fail') ? 'bad' : 'warn',
      timestamp: chainOverlay.history.timestamp,
      sortTs: timestampSortValue(chainOverlay.history.timestamp),
    })
  }

  if (linkedAutoresearch) {
    const detailParts = [
      linkedAutoresearch.last_decision ?? null,
      linkedAutoresearch.target_file ? `target ${linkedAutoresearch.target_file}` : null,
      linkedAutoresearch.error ?? null,
    ].filter(Boolean)
    feed.push({
      key: `autoresearch:${linkedAutoresearch.loop_id ?? selectedSession?.session_id ?? 'session'}`,
      title: `Autoresearch · ${linkedAutoresearch.status ?? 'unknown'}`,
      detail: truncate(detailParts.join(' · ') || 'linked autoresearch context', 260),
      meta: [
        linkedAutoresearch.loop_id ? `loop ${linkedAutoresearch.loop_id}` : null,
        linkedAutoresearch.current_cycle != null ? `cycle ${linkedAutoresearch.current_cycle}` : null,
        linkedAutoresearch.best_score != null ? `best ${linkedAutoresearch.best_score}` : null,
      ].filter(Boolean).join(' · ') || 'linked autoresearch',
      source: 'autoresearch',
      tone: linkedAutoresearch.error ? 'bad' : linkedAutoresearch.status === 'running' ? 'warn' : 'ok',
      timestamp: null,
      sortTs: 0,
    })
  }

  for (const item of activeRecommendedActions.slice(0, 4)) {
    feed.push({
      key: `recommendation:${item.action_type}:${item.target_type}:${item.target_id ?? 'session'}`,
      title: `${item.action_type} · ${item.target_type}`,
      detail: truncate(item.reason, 240),
      meta: item.target_id ?? 'operator recommendation',
      source: 'recommendation',
      tone: recommendationTone(item),
      timestamp: null,
      sortTs: 0,
    })
  }

  for (const item of attentionItems.slice(0, 4)) {
    feed.push({
      key: `attention:${item.kind}:${item.target_id ?? 'session'}`,
      title: `${item.kind} · ${item.target_type}`,
      detail: truncate(item.summary, 240),
      meta: item.target_id ?? 'attention',
      source: 'attention',
      tone: toneClass(item.severity) as 'ok' | 'warn' | 'bad',
      timestamp: null,
      sortTs: 0,
    })
  }

  for (const [index, rawEvent] of (selectedSession?.recent_events ?? []).slice(0, 4).entries()) {
    const event = summarizeSessionEvent(rawEvent)
    feed.push({
      key: `session:${selectedSession?.session_id ?? 'unknown'}:${index}`,
      title: event.title,
      detail: event.detail,
      meta: selectedSession?.session_id ?? 'session',
      source: 'session',
      tone: 'warn',
      timestamp: event.timestamp,
      sortTs: timestampSortValue(event.timestamp),
    })
  }

  return feed
    .sort((a, b) => b.sortTs - a.sortTs || a.title.localeCompare(b.title))
    .slice(0, 14)
}

export function WarRoomJumpButton({
  label,
  surface,
  params = {},
}: {
  label: string
  surface?: CommandPlaneSurface
  params?: Record<string, string>
}) {
  return html`
    <${ActionButton}
      variant="ghost"
      onClick=${() => {
        if (surface) {
          setCommandPlaneSurface(surface)
          navigate('operations', { ...surfaceRouteParams(surface), ...params })
          return
        }
        navigate('operations', { section: 'intervene' })
      }}
    >
      ${label}
    <//>
  `
}

export function WarRoomOrchestrationRail({
  chainOverlay,
  linkedAutoresearch,
}: {
  chainOverlay: CommandPlaneChainOverlay | null
  linkedAutoresearch?: OperatorLinkedAutoresearch | null
}) {
  if (!chainOverlay && !linkedAutoresearch) {
    return html`<div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card"><p>이 세션에 붙은 chain/autoresearch 오버레이가 아직 없습니다.</p></div>`
  }

  return html`
    <div class="grid grid-cols-1 gap-3">
      ${chainOverlay
        ? html`
            <article class="cmd-card rounded-xl cmd-orch-card min-h-[220px]">
              <div class="cmd-card rounded-xl-head">
                <div>
                  <strong>Chain Orchestration</strong>
                  <div class="cmd-card rounded-xl-sub">${chainOverlay.operation.operation_id}</div>
                </div>
                <${StatusChip} label=${displayStatus(chainOverlay.operation.status)} tone=${toneClass(sessionStatusTone(chainOverlay.operation.status))} />
              </div>
              <div class="cmd-card rounded-xl-grid">
                <span>Chain</span><span>${chainOverlay.runtime?.chain_id ?? chainOverlay.preview_run?.chain_id ?? 'n/a'}</span>
                <span>Progress</span><span>${formatPercent(chainOverlay.runtime?.progress)}</span>
                <span>Elapsed</span><span>${formatElapsed(chainOverlay.runtime?.elapsed_sec)}</span>
                <span>최근 이벤트</span><span>${historySummary(chainOverlay.history)}</span>
              </div>
              <div class="flex gap-3 flex-wrap mt-3">
                <${WarRoomJumpButton}
                  label="체인 상세"
                  surface="chains"
                  params=${{ operation: chainOverlay.operation.operation_id }}
                />
              </div>
            </article>
          `
        : null}
      ${linkedAutoresearch
        ? html`
            <article class="cmd-card rounded-xl cmd-orch-card min-h-[220px]">
              <div class="cmd-card rounded-xl-head">
                <div>
                  <strong>Autoresearch Loop</strong>
                  <div class="cmd-card rounded-xl-sub">${linkedAutoresearch.loop_id ?? linkedAutoresearch.session_id ?? 'linked session'}</div>
                </div>
                <${StatusChip} label=${linkedAutoresearch.status ?? 'unknown'} tone=${linkedAutoresearch.error ? 'bad' : linkedAutoresearch.status === 'running' ? 'warn' : 'ok'} />
              </div>
              <div class="cmd-card rounded-xl-grid">
                <span>Cycle</span><span>${linkedAutoresearch.current_cycle ?? 0}</span>
                <span>Best score</span><span>${linkedAutoresearch.best_score ?? 'n/a'}</span>
                <span>Target</span><span>${linkedAutoresearch.target_file ?? 'n/a'}</span>
                <span>Last decision</span><span>${linkedAutoresearch.last_decision ?? linkedAutoresearch.error ?? '기록 없음'}</span>
              </div>
              <div class="flex gap-3 flex-wrap mt-3">
                <${WarRoomJumpButton} label="세션 개입" />
                ${linkedAutoresearch.operation_id
                  ? html`<${WarRoomJumpButton}
                      label="작전 상세"
                      surface="operations"
                      params=${{ operation_id: linkedAutoresearch.operation_id }}
                    />`
                  : null}
              </div>
            </article>
          `
        : null}
    </div>
  `
}
