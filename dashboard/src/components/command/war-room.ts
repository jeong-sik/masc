import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import type {
  CommandPlaneSwarmLane,
  CommandPlaneSwarmWorker,
  CommandPlaneSurface,
  OperatorRecommendedAction,
  OperatorWorkerCard,
  PendingConfirmation,
} from '../../types'
import {
  commandPlaneChainSummary,
  commandPlaneSwarm,
  commandPlaneSwarmLoading,
  setCommandPlaneSurface,
} from '../../command-store'
import {
  operatorLoading,
  operatorSessionDigest,
  operatorSnapshot,
  refreshOperatorSessionDigest,
  refreshOperatorSnapshot,
} from '../../operator-store'
import { navigate } from '../../router'
import { PanelSemanticDetails } from '../common/semantic-layer'
import {
  currentCommandPlaneSummary,
  deadlineLabel,
  displayStatus,
  formatElapsed,
  formatPercent,
  hasSwarmActivity,
  pickWarRoomSession,
  prettyJson,
  relativeTime,
  sessionStatusTone,
  surfaceRouteParams,
  toneClass,
} from './helpers'
import { SwarmBlockerCard, SwarmHealthBar, SwarmStoryboard } from './swarm'
import { TraceRow } from './topology'

type WarRoomWorkerView = {
  key: string
  name: string
  role: string
  lane: string
  status: string
  source: 'swarm' | 'session'
  task: string
  heartbeat: string
  detail: string
  markers: string[]
  note?: string | null
}

function swarmWorkerView(worker: CommandPlaneSwarmWorker): WarRoomWorkerView {
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
    task: worker.current_task ?? worker.bound_task_title ?? worker.bound_task_id ?? 'none',
    heartbeat:
      worker.heartbeat_age_sec != null
        ? `${Math.round(worker.heartbeat_age_sec)}s`
        : worker.heartbeat_fresh
          ? 'clean'
          : 'n/a',
    detail: [
      worker.bound_task_status ?? null,
      worker.detachment_member ? 'detachment' : null,
      worker.squad_member ? 'squad' : null,
    ].filter(Boolean).join(' · ') || 'live swarm worker',
    markers,
    note: worker.last_message?.content ?? null,
  }
}

function operatorWorkerView(worker: OperatorWorkerCard, index: number): WarRoomWorkerView {
  const name = worker.actor ?? worker.spawn_role ?? `worker-${index + 1}`
  const role = worker.spawn_role ?? worker.worker_class ?? worker.spawn_agent ?? 'worker'
  const lane = worker.lane_id ?? worker.capsule_mode ?? worker.control_domain ?? 'session'
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
    task: worker.task_profile ?? worker.runtime_pool ?? 'session lane',
    heartbeat: worker.last_turn_ts_iso ? relativeTime(worker.last_turn_ts_iso) : 'n/a',
    detail: [
      worker.spawn_agent ?? null,
      worker.spawn_model ?? null,
      worker.routing_confidence != null ? formatPercent(worker.routing_confidence) : null,
    ].filter(Boolean).join(' · ') || 'session worker',
    markers,
    note: worker.routing_reason ?? null,
  }
}

function warRoomRecommendationTone(item: OperatorRecommendedAction): string {
  return toneClass(item.severity)
}

function WarRoomWorkerCard({ worker }: { worker: WarRoomWorkerView }) {
  return html`
    <article class="command-card compact warroom-worker-card ${toneClass(sessionStatusTone(worker.status))}">
      <div class="command-card-head">
        <div>
          <strong>${worker.name}</strong>
          <div class="command-card-sub">${worker.role} · ${worker.lane}</div>
        </div>
        <span class="command-chip ${toneClass(sessionStatusTone(worker.status))}">${worker.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Source</span><span>${worker.source}</span>
        <span>Task</span><span>${worker.task}</span>
        <span>Heartbeat</span><span>${worker.heartbeat}</span>
        <span>Detail</span><span>${worker.detail}</span>
      </div>
      <div class="command-tag-row">
        ${worker.markers.map(marker => html`<span class="command-tag">${marker}</span>`)}
      </div>
      ${worker.note
        ? html`<div class="command-card-foot">${worker.note}</div>`
        : null}
    </article>
  `
}

function WarRoomJumpButton({
  label,
  surface,
  params = {},
}: {
  label: string
  surface?: CommandPlaneSurface
  params?: Record<string, string>
}) {
  return html`
    <button
      class="control-btn ghost"
      onClick=${() => {
        if (surface) {
          setCommandPlaneSurface(surface)
          navigate('command', { ...surfaceRouteParams(surface), ...params })
          return
        }
        navigate('intervene')
      }}
    >
      ${label}
    </button>
  `
}

export function WarRoomSurface() {
  const summary = currentCommandPlaneSummary()
  const swarm = commandPlaneSwarm.value
  const snapshot = operatorSnapshot.value
  const sessionDigest = operatorSessionDigest.value
  const selectedSession = pickWarRoomSession()
  const chainOverlay = swarm?.operation
    ? commandPlaneChainSummary.value?.operations.find(
        overlay => overlay.operation.operation_id === swarm.operation?.operation_id,
      ) ?? null
    : null
  const swarmWorkers = swarm?.workers ?? []
  const sessionWorkers = sessionDigest?.worker_cards ?? []
  const workers =
    swarmWorkers.length > 0
      ? swarmWorkers.map(swarmWorkerView)
      : sessionWorkers.map(operatorWorkerView)
  const hasLiveRun = hasSwarmActivity()
  const pendingApprovals = summary?.decisions.summary?.pending ?? 0
  const pendingConfirms = snapshot?.pending_confirms ?? []
  const blockers = swarm?.blockers ?? []
  const recommendedActions = sessionDigest?.recommended_actions ?? []
  const attentionItems = sessionDigest?.attention_items ?? []
  const latestMessage = swarm?.recent_messages[0]?.timestamp ?? null
  const latestTrace = swarm?.recent_trace_events[0]?.timestamp ?? null
  const latestSignal = latestMessage ?? latestTrace ?? null
  const sessionSummary = selectedSession?.summary as Record<string, unknown> | undefined
  const workerExpected =
    swarm?.summary?.expected_workers
    ?? (typeof sessionSummary?.planned_worker_count === 'number' ? sessionSummary.planned_worker_count : undefined)
    ?? sessionDigest?.worker_cards.length
    ?? 0
  const workerJoined =
    swarm?.summary?.joined_workers
    ?? (typeof sessionSummary?.active_agent_count === 'number' ? sessionSummary.active_agent_count : undefined)
    ?? workers.length
  const stickyTone =
    blockers.length > 0 || pendingApprovals > 0 || pendingConfirms.length > 0
      ? 'warn'
      : hasLiveRun || selectedSession
        ? 'ok'
        : 'warn'
  const liveLanes = summary?.swarm_status?.lanes.filter((lane: CommandPlaneSwarmLane) => lane.present) ?? []

  useEffect(() => {
    void refreshOperatorSnapshot()
  }, [])

  useEffect(() => {
    if (!selectedSession?.session_id) return
    void refreshOperatorSessionDigest(selectedSession.session_id)
  }, [selectedSession?.session_id, snapshot, swarm?.detachment?.session_id])

  if (!hasLiveRun && !selectedSession) {
    if (commandPlaneSwarmLoading.value || operatorLoading.value) {
      return html`<div class="empty-state">live war room 불러오는 중…</div>`
    }
    return html`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">라이브 워룸</div>
          <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>현재 live run 없음</strong>
          <p>활성 operation 또는 team session이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${WarRoomJumpButton} label="작전 보기" surface="operations" />
          <${WarRoomJumpButton} label="스웜 보기" surface="swarm" />
          <${WarRoomJumpButton} label="개입 열기" />
          <${WarRoomJumpButton} label="제어 보기" surface="control" />
        </div>
      </section>
    `
  }

  return html`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${toneClass(stickyTone)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${swarm?.operation?.objective ?? selectedSession?.session_id ?? 'active run'}</strong>
            <div class="command-card-sub">
              ${swarm?.operation?.operation_id ?? 'operation 없음'}
              ${selectedSession?.session_id ? ` · session ${selectedSession.session_id}` : ''}
              ${swarm?.detachment?.detachment_id ? ` · detachment ${swarm.detachment.detachment_id}` : ''}
            </div>
          </div>
          <div class="command-action-row">
            <${WarRoomJumpButton}
              label="스웜 상세"
              surface="swarm"
              params=${{
                ...(swarm?.operation?.operation_id ? { operation_id: swarm.operation.operation_id } : {}),
                ...(swarm?.run_id ? { run_id: swarm.run_id } : {}),
              }}
            />
            <${WarRoomJumpButton} label="트레이스" surface="trace" />
            ${chainOverlay
              ? html`<${WarRoomJumpButton}
                  label="체인"
                  surface="chains"
                  params=${{ operation: chainOverlay.operation.operation_id }}
                />`
              : null}
            <${WarRoomJumpButton} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${workerJoined ?? 0}/${workerExpected ?? 0}</strong>
            <small>${swarm?.summary?.completed_workers ?? 0} 완료 · ${workers.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${swarm?.provider?.runtime_blocker ? 'blocked' : swarm?.provider?.provider_reachable ? 'ready' : selectedSession ? displayStatus(selectedSession.status) : 'check'}</strong>
            <small>slots ${swarm?.provider?.active_slots_now ?? 0}/${swarm?.provider?.actual_slots ?? swarm?.provider?.total_slots ?? 0} · ctx ${swarm?.provider?.actual_ctx ?? swarm?.provider?.ctx_per_slot ?? 0}</small>
          </div>
          <div class="monitor-stat-card ${toneClass(blockers.length > 0 || pendingApprovals > 0 ? 'warn' : 'ok')}">
            <span>Pressure</span>
            <strong>${blockers.length + pendingApprovals + pendingConfirms.length}</strong>
            <small>blockers ${blockers.length} · approvals ${pendingApprovals} · confirms ${pendingConfirms.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${relativeTime(latestSignal)}</strong>
            <small>${latestMessage ? 'message' : latestTrace ? 'trace' : 'waiting'}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            ${liveLanes.length > 0
              ? html`
                  <${SwarmStoryboard} lanes=${liveLanes} />
                  <${SwarmHealthBar} lanes=${liveLanes} />
                `
              : selectedSession
                ? html`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${selectedSession.session_id}</strong>
                        <span class="command-chip ${toneClass(sessionStatusTone(selectedSession.status))}">${displayStatus(selectedSession.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${selectedSession.progress_pct != null ? `${selectedSession.progress_pct}%` : 'n/a'}</span>
                        <span>Elapsed</span><span>${formatElapsed(selectedSession.elapsed_sec)}</span>
                        <span>Remaining</span><span>${formatElapsed(selectedSession.remaining_sec)}</span>
                      </div>
                    </article>
                  `
                : html`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            ${workers.length > 0
              ? html`<div class="command-card-stack">
                  ${workers.map(worker => html`<${WarRoomWorkerCard} worker=${worker} />`)}
                </div>`
              : html`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            ${swarm && swarm.recent_messages.length > 0
              ? html`<div class="command-trace-stack">
                  ${swarm.recent_messages.map(message => html`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${message.from}</strong>
                          <span class="command-chip">${relativeTime(message.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${message.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${message.content}</pre>
                    </article>
                  `)}
                </div>`
              : recommendedActions.length > 0 || attentionItems.length > 0
                ? html`<div class="command-card-stack">
                    ${recommendedActions.slice(0, 4).map(item => html`
                      <article class="command-guide-card ${warRoomRecommendationTone(item)}">
                        <div class="command-guide-head">
                          <strong>${item.action_type}</strong>
                          <span class="command-chip ${warRoomRecommendationTone(item)}">${item.target_type}</span>
                        </div>
                        <p>${item.reason}</p>
                      </article>
                    `)}
                    ${attentionItems.slice(0, 3).map(item => html`
                      <article class="command-alert ${toneClass(item.severity)}">
                        <div class="command-card-head">
                          <strong>${item.kind}</strong>
                          <span class="command-chip ${toneClass(item.severity)}">${item.severity}</span>
                        </div>
                        <p>${item.summary}</p>
                      </article>
                    `)}
                  </div>`
                : selectedSession?.recent_events && selectedSession.recent_events.length > 0
                  ? html`<div class="command-trace-stack">
                      ${selectedSession.recent_events.slice(0, 6).map((event, index) => html`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${index + 1}</strong>
                              <span class="command-chip">${selectedSession.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${prettyJson(event)}</pre>
                        </article>
                      `)}
                    </div>`
                  : html`<div class="empty-state">메시지나 attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Trace Feed</div>
              <${PanelSemanticDetails} panelId="command.trace" compact=${true} />
            </div>
            ${swarm && swarm.recent_trace_events.length > 0
              ? html`<div class="command-trace-stack">
                  ${swarm.recent_trace_events.map(event => html`<${TraceRow} event=${event} />`)}
                </div>`
              : html`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Pressure</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            <div class="command-card-stack">
              ${blockers.length > 0
                ? blockers.map(blocker => html`<${SwarmBlockerCard} blocker=${blocker} />`)
                : html`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${pendingApprovals > 0
                ? html`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${pendingApprovals}</span>
                      </div>
                      <p>strict action이 묶여 있습니다. 실제 승인 처리는 control 표면에서 합니다.</p>
                    </article>
                  `
                : null}
              ${pendingConfirms.length > 0
                ? html`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending confirms</strong>
                        <span class="command-chip warn">${pendingConfirms.length}</span>
                      </div>
                      <p>operator preview가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${pendingConfirms.slice(0, 3).map((item: PendingConfirmation) => html`<span class="command-tag">${item.confirm_token}</span>`)}
                      </div>
                    </article>
                  `
                : null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Focus Detail</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            <div class="command-card-stack">
              ${swarm?.operation
                ? html`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${swarm.operation.objective}</strong>
                          <div class="command-card-sub">${swarm.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${toneClass(sessionStatusTone(swarm.operation.status))}">${swarm.operation.status}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Unit</span><span>${swarm.operation.assigned_unit_id}</span>
                        <span>Trace</span><span>${swarm.operation.trace_id}</span>
                        <span>Autonomy</span><span>${swarm.operation.autonomy_level ?? 'n/a'}</span>
                        <span>Updated</span><span>${relativeTime(swarm.operation.updated_at)}</span>
                      </div>
                    </article>
                  `
                : null}
              ${swarm?.detachment
                ? html`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${swarm.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${swarm.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${toneClass(sessionStatusTone(swarm.detachment.status))}">${swarm.detachment.status ?? 'active'}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${swarm.detachment.leader_id ?? 'unassigned'}</span>
                        <span>Roster</span><span>${swarm.detachment.roster.length}</span>
                        <span>Session</span><span>${swarm.detachment.session_id ?? 'none'}</span>
                        <span>Heartbeat</span><span>${deadlineLabel(swarm.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `
                : null}
              ${selectedSession
                ? html`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${selectedSession.session_id}</strong>
                          <div class="command-card-sub">team session focus</div>
                        </div>
                        <span class="command-chip ${toneClass(sessionStatusTone(selectedSession.status))}">${displayStatus(selectedSession.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${selectedSession.progress_pct != null ? `${selectedSession.progress_pct}%` : 'n/a'}</span>
                        <span>Elapsed</span><span>${formatElapsed(selectedSession.elapsed_sec)}</span>
                        <span>Remaining</span><span>${formatElapsed(selectedSession.remaining_sec)}</span>
                        <span>Done delta</span><span>${selectedSession.done_delta_total ?? 0}</span>
                      </div>
                    </article>
                  `
                : null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `
}
