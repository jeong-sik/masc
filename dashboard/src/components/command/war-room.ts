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
import {
  guidanceFreshnessLabel,
  guidanceLayerLabel,
  guidanceLayerTone,
  runtimeJudgeLabel,
} from '../ops/helpers'
import { SwarmBlockerCard, SwarmHealthBar, SwarmRunResolutionCard, SwarmStoryboard } from './swarm'
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

function warRoomSourceLabel(source: WarRoomWorkerView['source']): string {
  return source === 'swarm' ? '스웜 실시간' : '세션 요약'
}

function warRoomMarkerLabel(marker: string): string {
  switch (marker) {
    case 'current':
      return '현재 과업 일치'
    case 'drift':
      return '과업 드리프트'
    case 'claim':
      return '착수 흔적 있음'
    case 'no-claim':
      return '착수 흔적 없음'
    case 'done':
      return '완료 흔적 있음'
    case 'no-done':
      return '완료 흔적 없음'
    case 'final':
      return '최종 보고 있음'
    case 'no-final':
      return '최종 보고 없음'
    case 'turn':
      return '턴 기록 있음'
    case 'silent':
      return '턴 기록 없음'
    case 'noted':
      return '노트 기록 있음'
    default:
      if (marker.startsWith('empty:')) return `빈 노트 ${marker.slice('empty:'.length)}회`
      if (marker.startsWith('turns:')) return `턴 ${marker.slice('turns:'.length)}회`
      return marker
  }
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

function operatorWorkerView(worker: OperatorWorkerCard, index: number): WarRoomWorkerView {
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
        <span class="command-chip ${toneClass(sessionStatusTone(worker.status))}">${displayStatus(worker.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${warRoomSourceLabel(worker.source)}</span>
        <span>과업</span><span>${worker.task}</span>
        <span>최근 신호</span><span>${worker.heartbeat}</span>
        <span>근거</span><span>${worker.detail}</span>
      </div>
      <div class="command-tag-row">
        ${worker.markers.map(marker => html`<span class="command-tag">${warRoomMarkerLabel(marker)}</span>`)}
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
  const swarmHasEvidence = hasSwarmActivity()
  const swarmWorkers = swarm?.workers ?? []
  const sessionWorkers = sessionDigest?.worker_cards ?? []
  const workers =
    swarmHasEvidence && swarmWorkers.length > 0
      ? swarmWorkers.map(swarmWorkerView)
      : sessionWorkers.map(operatorWorkerView)
  const hasLiveRun = swarmHasEvidence
  const pendingApprovals = summary?.decisions.summary?.pending ?? 0
  const pendingConfirms = snapshot?.pending_confirms ?? []
  const blockers = swarmHasEvidence ? (swarm?.blockers ?? []) : []
  const recommendedActions = sessionDigest?.recommended_actions ?? []
  const activeRecommendedActions =
    sessionDigest?.active_recommended_actions?.length
      ? sessionDigest.active_recommended_actions
      : recommendedActions
  const activeSummary = sessionDigest?.active_summary
  const guidanceLayer = sessionDigest?.active_guidance_layer ?? 'fallback'
  const residentRuntime = sessionDigest?.resident_judge_runtime ?? snapshot?.resident_judge_runtime
  const attentionItems = sessionDigest?.attention_items ?? []
  const latestMessage = swarm?.recent_messages[0]?.timestamp ?? null
  const latestTrace = swarm?.recent_trace_events[0]?.timestamp ?? null
  const latestSignal = swarmHasEvidence ? (latestMessage ?? latestTrace ?? null) : null
  const sessionSummary = selectedSession?.summary as Record<string, unknown> | undefined
  const workerExpected =
    (swarmHasEvidence ? swarm?.summary?.expected_workers : undefined)
    ?? (typeof sessionSummary?.planned_worker_count === 'number' ? sessionSummary.planned_worker_count : undefined)
    ?? sessionDigest?.worker_cards.length
    ?? 0
  const workerJoined =
    (swarmHasEvidence ? swarm?.summary?.joined_workers : undefined)
    ?? (typeof sessionSummary?.active_agent_count === 'number' ? sessionSummary.active_agent_count : undefined)
    ?? workers.length
  const stickyTone =
    blockers.length > 0 || pendingApprovals > 0 || pendingConfirms.length > 0
      ? 'warn'
      : hasLiveRun || selectedSession
        ? 'ok'
        : 'warn'
  const liveLanes =
    swarmHasEvidence
      ? (summary?.swarm_status?.lanes.filter((lane: CommandPlaneSwarmLane) => lane.present) ?? [])
      : []

  useEffect(() => {
    void refreshOperatorSnapshot()
  }, [])

  useEffect(() => {
    if (!selectedSession?.session_id) return
    void refreshOperatorSessionDigest(selectedSession.session_id)
  }, [selectedSession?.session_id, snapshot, swarm?.detachment?.session_id])

  if (!hasLiveRun && !selectedSession) {
    if (commandPlaneSwarmLoading.value || operatorLoading.value) {
      return html`<div class="empty-state">실시간 워룸 불러오는 중…</div>`
    }
    return html`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">실시간 워룸</div>
          <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>지금 보이는 실시간 실행이 없습니다</strong>
          <p>활성 작전이나 팀 세션이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
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
            <span class="command-hero-kicker">실시간 워룸</span>
            <strong>${swarmHasEvidence ? (swarm?.operation?.objective ?? selectedSession?.session_id ?? '가동 중인 실행') : (selectedSession?.session_id ?? '가동 중인 실행')}</strong>
            <div class="command-card-sub">
              ${swarmHasEvidence ? (swarm?.operation?.operation_id ?? '작전 정보 없음') : '세션 기준값'}
              ${selectedSession?.session_id ? ` · 세션 ${selectedSession.session_id}` : ''}
              ${swarmHasEvidence && swarm?.detachment?.detachment_id ? ` · 분견대 ${swarm.detachment.detachment_id}` : ''}
            </div>
            ${activeSummary?.summary
              ? html`<div class="command-warroom-guidance ${guidanceLayerTone(guidanceLayer)}">
                  <strong>${guidanceLayerLabel(guidanceLayer)}</strong>
                  <span>${activeSummary.summary}</span>
                </div>`
              : null}
          </div>
          <div class="command-action-row">
            <${WarRoomJumpButton}
              label="스웜 상세"
              surface="swarm"
              params=${{
                ...(swarmHasEvidence && swarm?.operation?.operation_id ? { operation_id: swarm.operation.operation_id } : {}),
                ...(swarmHasEvidence && swarm?.run_id ? { run_id: swarm.run_id } : {}),
              }}
            />
            <${WarRoomJumpButton} label="트레이스" surface="trace" />
            ${swarmHasEvidence && chainOverlay
              ? html`<${WarRoomJumpButton}
                  label="체인"
                  surface="chains"
                  params=${{ operation: chainOverlay.operation.operation_id }}
                />`
              : null}
            <${WarRoomJumpButton} label="개입" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>워커</span>
            <strong>${workerJoined ?? 0}/${workerExpected ?? 0}</strong>
            <small>${swarmHasEvidence ? (swarm?.summary?.completed_workers ?? 0) : 0} 완료 · ${workers.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>런타임</span>
            <strong>${swarmHasEvidence ? (swarm?.provider?.runtime_blocker ? '막힘' : swarm?.provider?.provider_reachable ? '준비됨' : selectedSession ? displayStatus(selectedSession.status) : '확인 필요') : (selectedSession ? displayStatus(selectedSession.status) : '확인 필요')}</strong>
            <small>${swarmHasEvidence ? `슬롯 ${swarm?.provider?.active_slots_now ?? 0}/${swarm?.provider?.actual_slots ?? swarm?.provider?.total_slots ?? 0} · 컨텍스트 ${swarm?.provider?.actual_ctx ?? swarm?.provider?.ctx_per_slot ?? 0}` : `세션 워커 ${sessionDigest?.worker_cards.length ?? 0}`}</small>
          </div>
          <div class="monitor-stat-card ${toneClass(blockers.length > 0 || pendingApprovals > 0 ? 'warn' : 'ok')}">
            <span>압력</span>
            <strong>${blockers.length + pendingApprovals + pendingConfirms.length}</strong>
            <small>막힘 ${blockers.length} · 승인 ${pendingApprovals} · 확인 ${pendingConfirms.length}</small>
          </div>
          <div class="monitor-stat-card ${toneClass(guidanceLayerTone(guidanceLayer))}">
            <span>상주 판정기</span>
            <strong>${runtimeJudgeLabel(residentRuntime)}</strong>
            <small>${guidanceFreshnessLabel(activeSummary)}${residentRuntime?.model_used ? ` · ${residentRuntime.model_used}` : ''}</small>
          </div>
          <div class="monitor-stat-card">
            <span>마지막 신호</span>
            <strong>${relativeTime(latestSignal)}</strong>
            <small>${latestMessage ? '메시지' : latestTrace ? '트레이스' : '대기 중'}</small>
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
                      <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${selectedSession.progress_pct != null ? `${selectedSession.progress_pct}%` : '정보 없음'}</span>
                        <span>경과</span><span>${formatElapsed(selectedSession.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${formatElapsed(selectedSession.remaining_sec)}</span>
                      </div>
                    </article>
                  `
                : html`<div class="empty-state">보이는 레인이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">워커 현황</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            ${workers.length > 0
              ? html`<div class="command-card-stack">
                  ${workers.map(worker => html`<${WarRoomWorkerCard} worker=${worker} />`)}
                </div>`
              : html`<div class="empty-state">활성 워커 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">상황 피드</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            ${swarm && swarm.recent_messages.length > 0
              && swarmHasEvidence
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
              : activeRecommendedActions.length > 0 || attentionItems.length > 0
                ? html`<div class="command-card-stack">
                    ${activeRecommendedActions.slice(0, 4).map(item => html`
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
                              <strong>세션 이벤트 ${index + 1}</strong>
                              <span class="command-chip">${selectedSession.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${prettyJson(event)}</pre>
                        </article>
                      `)}
                    </div>`
                  : html`<div class="empty-state">메시지나 주의 항목이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">트레이스 흐름</div>
              <${PanelSemanticDetails} panelId="command.trace" compact=${true} />
            </div>
            ${swarm && swarm.recent_trace_events.length > 0
              ? html`<div class="command-trace-stack">
                  ${swarm.recent_trace_events.map(event => html`<${TraceRow} event=${event} />`)}
                </div>`
              : html`<div class="empty-state">실행 범위 트레이스 이벤트가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">압력</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            <div class="command-card-stack">
              ${swarmHasEvidence && swarm ? html`<${SwarmRunResolutionCard} swarm=${swarm} />` : null}
              ${blockers.length > 0
                ? blockers.map(blocker => html`<${SwarmBlockerCard} blocker=${blocker} />`)
                : html`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${pendingApprovals > 0
                ? html`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>승인 대기</strong>
                        <span class="command-chip warn">${pendingApprovals}</span>
                      </div>
                      <p>엄격 액션이 묶여 있습니다. 실제 승인 처리는 제어 표면에서 합니다.</p>
                    </article>
                  `
                : null}
              ${pendingConfirms.length > 0
                ? html`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>확인 대기</strong>
                        <span class="command-chip warn">${pendingConfirms.length}</span>
                      </div>
                      <p>운영자 미리보기가 사람 확인을 기다리고 있습니다.</p>
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
              <div class="card-title">현재 초점</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            <div class="command-card-stack">
              ${swarmHasEvidence && swarm?.operation
                ? html`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${swarm.operation.objective}</strong>
                          <div class="command-card-sub">${swarm.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${toneClass(sessionStatusTone(swarm.operation.status))}">${displayStatus(swarm.operation.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>유닛</span><span>${swarm.operation.assigned_unit_id}</span>
                        <span>트레이스</span><span>${swarm.operation.trace_id}</span>
                        <span>자율성</span><span>${swarm.operation.autonomy_level ?? '정보 없음'}</span>
                        <span>최근 갱신</span><span>${relativeTime(swarm.operation.updated_at)}</span>
                      </div>
                    </article>
                  `
                : null}
              ${swarmHasEvidence && swarm?.detachment
                ? html`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${swarm.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${swarm.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${toneClass(sessionStatusTone(swarm.detachment.status))}">${displayStatus(swarm.detachment.status ?? 'active')}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>리더</span><span>${swarm.detachment.leader_id ?? '미지정'}</span>
                        <span>편성</span><span>${swarm.detachment.roster.length}</span>
                        <span>세션</span><span>${swarm.detachment.session_id ?? '연결 없음'}</span>
                        <span>하트비트</span><span>${deadlineLabel(swarm.detachment.heartbeat_deadline)}</span>
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
                          <div class="command-card-sub">현재 세션 기준</div>
                        </div>
                        <span class="command-chip ${toneClass(sessionStatusTone(selectedSession.status))}">${displayStatus(selectedSession.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${selectedSession.progress_pct != null ? `${selectedSession.progress_pct}%` : '정보 없음'}</span>
                        <span>경과</span><span>${formatElapsed(selectedSession.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${formatElapsed(selectedSession.remaining_sec)}</span>
                        <span>완료 변화량</span><span>${selectedSession.done_delta_total ?? 0}</span>
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
