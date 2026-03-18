import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type {
  CommandPlaneSwarmLane,
  PendingConfirmation,
} from '../../types'
import {
  commandPlaneChainSummary,
  commandPlaneSwarm,
  commandPlaneSwarmLoading,
  refreshCommandPlaneChainSummary,
  refreshCommandPlaneSwarm,
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
import { agents, keepers } from '../../store'
import { PanelSemanticDetails } from '../common/semantic-layer'
import {
  currentCommandPlaneSummary,
  deadlineLabel,
  displayStatus,
  formatElapsed,
  hasSwarmActivity,
  pickWarRoomSession,
  relativeTime,
  sessionStatusTone,
  surfaceRouteParams,
  toneClass,
} from './helpers'
import { selectPendingConfirmState } from '../../pending-confirm'
import {
  guidanceFreshnessLabel,
  guidanceLayerLabel,
  guidanceLayerTone,
  runtimeJudgeLabel,
} from '../ops/helpers'
import { SwarmBlockerCard, SwarmHealthBar, SwarmRunResolutionCard, SwarmStoryboard } from './swarm'
import { TraceRow } from './topology'
import { WarRoomWorkerCard, WarRoomPresenceCard, WarRoomFeedCard } from './war-room-panels'
import type { WarRoomPresenceView } from './war-room-panels'
import {
  agentPresenceView,
  buildFeedItems,
  keeperPresenceView,
  operatorWorkerView,
  residentPresenceView,
  swarmWorkerView,
  timestampSortValue,
  WarRoomJumpButton,
  WarRoomOrchestrationRail,
} from './war-room-metrics'

export function WarRoomSurface({ wallboard = false }: { wallboard?: boolean }) {
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
  const linkedAutoresearch = selectedSession?.linked_autoresearch ?? null
  const swarmHasEvidence = hasSwarmActivity()
  const swarmWorkers = swarm?.workers ?? []
  const sessionWorkers = sessionDigest?.worker_cards ?? []
  const workers =
    swarmHasEvidence && swarmWorkers.length > 0
      ? swarmWorkers.map(swarmWorkerView)
      : sessionWorkers.map(operatorWorkerView)
  const liveAgents = agents.value.filter(agent =>
    agent.status === 'active'
    || agent.status === 'busy'
    || agent.status === 'listening'
    || agent.status === 'idle',
  )
  const liveKeepers = keepers.value
    .filter(keeper => keeper.status !== 'offline' || keeper.keepalive_running || keeper.last_heartbeat)
    .sort((left, right) => timestampSortValue(right.last_heartbeat) - timestampSortValue(left.last_heartbeat))
  const hasLiveRun = swarmHasEvidence
  const pendingApprovals = summary?.decisions.summary?.pending ?? 0
  const pendingState = selectPendingConfirmState(snapshot)
  const pendingConfirms = pendingState.items
  const pendingConfirmTotal = pendingState.total_count
  const pendingConfirmVisible = pendingState.visible_count
  const pendingConfirmHidden = pendingState.hidden_count
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
    blockers.length > 0 || pendingApprovals > 0 || pendingConfirmTotal > 0
      ? 'warn'
      : hasLiveRun || selectedSession
        ? 'ok'
        : 'warn'
  const liveLanes =
    swarmHasEvidence
      ? (summary?.swarm_status?.lanes.filter((lane: CommandPlaneSwarmLane) => lane.present) ?? [])
      : []
  const activeLaneId =
    summary?.swarm_status?.narrative?.lane_id
    ?? summary?.swarm_status?.recommended_next_action?.lane_id
    ?? liveLanes[0]?.lane_id
    ?? null
  const activeLane = activeLaneId
    ? liveLanes.find(lane => lane.lane_id === activeLaneId) ?? null
    : liveLanes[0] ?? null
  const presenceViews: WarRoomPresenceView[] = [
    ...(residentRuntime ? [residentPresenceView(residentRuntime)] : []),
    ...liveAgents.slice(0, wallboard ? 8 : 5).map(agentPresenceView),
    ...liveKeepers.slice(0, wallboard ? 8 : 5).map(keeperPresenceView),
  ]
  const agentViews = presenceViews.filter(item => item.source === 'agent')
  const keeperViews = presenceViews.filter(item => item.source === 'keeper' || item.source === 'resident')
  const feedItems = buildFeedItems({
    swarmMessages: swarm?.recent_messages ?? [],
    traceEvents: swarm?.recent_trace_events ?? [],
    chainOverlay,
    linkedAutoresearch,
    selectedSession,
    activeRecommendedActions,
    attentionItems,
  })
  const heroTitle =
    swarm?.operation?.objective
    ?? summary?.swarm_status?.narrative?.active_work
    ?? selectedSession?.session_id
    ?? '가동 중인 워룸'
  const heroSummary =
    [
      activeSummary?.summary ?? null,
      summary?.swarm_status?.narrative?.state ?? null,
      summary?.swarm_status?.narrative?.active_work ?? null,
      activeLane ? `${activeLane.label} · ${activeLane.current_step}` : null,
    ].filter(Boolean).join(' · ')
    || '실제 실행, 메시지, 트레이스, 상주 판단을 한 장에서 읽는 wallboard입니다.'

  const [fullscreenActive, setFullscreenActive] = useState(
    typeof document !== 'undefined' && !!document.fullscreenElement,
  )

  useEffect(() => {
    void refreshOperatorSnapshot()
  }, [])

  useEffect(() => {
    if (!selectedSession?.session_id) return
    void refreshOperatorSessionDigest(selectedSession.session_id)
  }, [selectedSession?.session_id, snapshot, swarm?.detachment?.session_id])

  useEffect(() => {
    if (!wallboard) return
    const sync = () => {
      setFullscreenActive(!!document.fullscreenElement)
    }
    document.addEventListener('fullscreenchange', sync)
    sync()
    return () => {
      document.removeEventListener('fullscreenchange', sync)
    }
  }, [wallboard])

  const toggleFullscreen = () => {
    if (typeof document === 'undefined') return
    if (document.fullscreenElement) {
      void document.exitFullscreen?.()
      return
    }
    void document.documentElement.requestFullscreen?.()
  }

  const refreshWallboard = () => {
    void refreshOperatorSnapshot()
    void refreshCommandPlaneSwarm()
    void refreshCommandPlaneChainSummary()
    if (selectedSession?.session_id) {
      void refreshOperatorSessionDigest(selectedSession.session_id)
    }
  }

  if (!hasLiveRun && !selectedSession) {
    if (commandPlaneSwarmLoading.value || operatorLoading.value) {
      return html`<div class="empty-state">실시간 워룸 불러오는 중…</div>`
    }
    return html`
      <section class="card command-section command-warroom-empty ${wallboard ? 'wallboard' : ''}">
        <div class="card-title-row">
          <div class="card-title">실시간 워룸</div>
          <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
        </div>
        <div class="command-warroom-empty-copy">
          <span class="command-hero-kicker">Narrative Playback</span>
          <strong>지금 붙잡을 live swarm 또는 team session이 없습니다</strong>
          <p>chain, autoresearch, worker wallboard는 활성 작전 또는 세션이 생기면 자동으로 붙습니다. 지금은 drill-down surface로 이동하는 편이 맞습니다.</p>
        </div>
        <div class="command-action-row">
          <${WarRoomJumpButton} label="작전 보기" surface="operations" />
          <${WarRoomJumpButton} label="스웜 보기" surface="swarm" />
          <${WarRoomJumpButton} label="체인 보기" surface="chains" />
          <${WarRoomJumpButton} label="개입 열기" />
        </div>
      </section>
    `
  }

  return html`
    <div class="command-section-stack ${wallboard ? 'wallboard' : ''}">
      <section class="command-warroom-strip ${toneClass(stickyTone)} ${wallboard ? 'wallboard' : ''}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">${wallboard ? 'War Room Wallboard' : '실시간 워룸'}</span>
            <strong>${heroTitle}</strong>
            <div class="command-card-sub">
              ${swarmHasEvidence ? (swarm?.operation?.operation_id ?? '작전 정보 없음') : '세션 기준값'}
              ${selectedSession?.session_id ? ` · 세션 ${selectedSession.session_id}` : ''}
              ${swarmHasEvidence && swarm?.detachment?.detachment_id ? ` · 분견대 ${swarm.detachment.detachment_id}` : ''}
              ${activeLane ? ` · 대표 레인 ${activeLane.label}` : ''}
            </div>
            <div class="command-warroom-summary">${heroSummary}</div>
            ${activeSummary?.summary
              ? html`<div class="command-warroom-guidance ${guidanceLayerTone(guidanceLayer)}">
                  <strong>${guidanceLayerLabel(guidanceLayer)}</strong>
                  <span>${activeSummary.summary}</span>
                </div>`
              : null}
          </div>
          <div class="command-warroom-hero-actions">
            <button class="control-btn ghost" onClick=${refreshWallboard}>새로고침</button>
            ${wallboard
              ? html`
                  <button class="control-btn ghost" onClick=${toggleFullscreen}>
                    ${fullscreenActive ? '전체 화면 해제' : '전체 화면'}
                  </button>
                  <button
                    class="control-btn ghost"
                    onClick=${() => {
                      if (document.fullscreenElement) {
                        void document.exitFullscreen?.()
                      }
                      setCommandPlaneSurface('warroom')
                      navigate('command', surfaceRouteParams('warroom'))
                    }}
                  >
                    표준 보기
                  </button>
                `
              : null}
            <${WarRoomJumpButton}
              label="스웜 상세"
              surface="swarm"
              params=${{
                ...(swarmHasEvidence && swarm?.operation?.operation_id ? { operation_id: swarm.operation.operation_id } : {}),
                ...(swarmHasEvidence && swarm?.run_id ? { run_id: swarm.run_id } : {}),
              }}
            />
            ${chainOverlay
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
            <small>${swarmHasEvidence ? `설정 ${swarm?.provider?.configured_capacity ?? 'n/a'} · 실제 ${swarm?.provider?.actual_slots ?? swarm?.provider?.total_slots ?? 0} · hot ${swarm?.summary?.peak_hot_slots ?? swarm?.provider?.peak_active_slots ?? 0}` : `세션 워커 ${sessionDigest?.worker_cards.length ?? 0}`}</small>
          </div>
          <div class="monitor-stat-card ${toneClass(blockers.length > 0 || pendingApprovals > 0 || pendingConfirmTotal > 0 ? 'warn' : 'ok')}">
            <span>압력</span>
            <strong>${blockers.length + pendingApprovals + pendingConfirmTotal}</strong>
            <small>막힘 ${blockers.length} · 승인 ${pendingApprovals} · 확인 ${pendingConfirmVisible}${pendingConfirmHidden > 0 ? `/${pendingConfirmTotal}` : ''}</small>
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

      <div class="command-warroom-grid ${wallboard ? 'wallboard' : ''}">
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
              <div class="card-title">오케스트레이션</div>
              <${PanelSemanticDetails} panelId="command.chains" compact=${true} />
            </div>
            <${WarRoomOrchestrationRail} chainOverlay=${chainOverlay} linkedAutoresearch=${linkedAutoresearch} />
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
            ${feedItems.length > 0
              ? html`<div class="command-trace-stack">
                  ${feedItems.map(item => html`<${WarRoomFeedCard} item=${item} />`)}
                </div>`
              : html`<div class="empty-state">메시지, chain, autoresearch, attention feed가 아직 없습니다.</div>`}
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
              <div class="card-title">Agents</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            ${agentViews.length > 0
              ? html`<div class="warroom-presence-grid">
                  ${agentViews.map(item => html`<${WarRoomPresenceCard} item=${item} />`)}
                </div>`
              : html`<div class="empty-state">가시적인 active agent가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Keepers</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            ${keeperViews.length > 0
              ? html`<div class="warroom-presence-grid">
                  ${keeperViews.map(item => html`<${WarRoomPresenceCard} item=${item} />`)}
                </div>`
              : html`<div class="empty-state">가시적인 keeper/runtime 카드가 아직 없습니다.</div>`}
          </section>

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
              ${pendingConfirmTotal > 0
                ? html`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>확인 대기</strong>
                        <span class="command-chip warn">${pendingConfirmHidden > 0 ? `${pendingConfirmVisible}/${pendingConfirmTotal}` : pendingConfirmTotal}</span>
                      </div>
                      <p>
                        운영자 미리보기가 사람 확인을 기다리고 있습니다.
                        ${pendingConfirmHidden > 0 ? ` 현재 actor 기준으로는 ${pendingConfirmVisible}건만 보입니다.` : ''}
                      </p>
                      <div class="command-tag-row">
                        ${pendingConfirms.slice(0, 3).map((item: PendingConfirmation) => html`<span class="command-tag">${item.confirm_token}</span>`)}
                      </div>
                    </article>
                  `
                : null}
              ${activeLane
                ? html`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${activeLane.label}</strong>
                          <div class="command-card-sub">${activeLane.kind} · ${activeLane.phase}</div>
                        </div>
                        <span class="command-chip ${toneClass(sessionStatusTone(activeLane.motion_state))}">${displayStatus(activeLane.motion_state)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>현재 단계</span><span>${activeLane.current_step}</span>
                        <span>이동 사유</span><span>${activeLane.movement_reason}</span>
                        <span>막힘 수</span><span>${activeLane.blockers.length}</span>
                        <span>최근 이동</span><span>${relativeTime(activeLane.last_movement_at)}</span>
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
                : selectedSession
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
