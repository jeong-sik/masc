import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type {
  CommandPlaneSwarmLane,
} from '../../types'
import {
  commandPlaneChainSummary,
  commandPlaneSwarm,
  commandPlaneSwarmLoading,
  refreshCommandPlaneChainSummary,
  refreshCommandPlaneSwarm,
} from '../../command-store'
import {
  operatorLoading,
  operatorSessionDigest,
  operatorSnapshot,
  refreshOperatorSessionDigest,
  refreshOperatorSnapshot,
} from '../../operator-store'
import { agents, keepers } from '../../store'
import {
  currentCommandPlaneSummary,
  hasSwarmActivity,
  pickWarRoomSession,
} from './helpers'
import { selectPendingConfirmState } from '../../pending-confirm'
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
} from './war-room-metrics'
import { WarRoomHeroStrip } from './war-room-hero'
import { WarRoomBodyGrid } from './war-room-body'

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
      <section class="card min-h-[240px] command-warroom-empty ${wallboard ? 'wallboard' : ''}">
        <div class="card-title-row">
          <div class="card-title">실시간 워룸</div>
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
      <${WarRoomHeroStrip}
        wallboard=${wallboard}
        stickyTone=${stickyTone}
        heroTitle=${heroTitle}
        heroSummary=${heroSummary}
        swarmHasEvidence=${swarmHasEvidence}
        swarm=${swarm}
        selectedSession=${selectedSession}
        activeLane=${activeLane}
        activeSummary=${activeSummary}
        guidanceLayer=${guidanceLayer}
        fullscreenActive=${fullscreenActive}
        workerJoined=${workerJoined}
        workerExpected=${workerExpected}
        workerCardCount=${workers.length}
        blockersCount=${blockers.length}
        pendingApprovals=${pendingApprovals}
        pendingConfirmTotal=${pendingConfirmTotal}
        pendingConfirmVisible=${pendingConfirmVisible}
        pendingConfirmHidden=${pendingConfirmHidden}
        residentRuntime=${residentRuntime}
        latestSignal=${latestSignal}
        latestMessage=${latestMessage}
        latestTrace=${latestTrace}
        chainOverlay=${chainOverlay}
        onRefresh=${refreshWallboard}
        onToggleFullscreen=${toggleFullscreen}
      />
      <${WarRoomBodyGrid}
        wallboard=${wallboard}
        liveLanes=${liveLanes}
        selectedSession=${selectedSession}
        chainOverlay=${chainOverlay}
        linkedAutoresearch=${linkedAutoresearch}
        workers=${workers}
        feedItems=${feedItems}
        swarm=${swarm}
        agentViews=${agentViews}
        keeperViews=${keeperViews}
        swarmHasEvidence=${swarmHasEvidence}
        blockers=${blockers}
        pendingApprovals=${pendingApprovals}
        pendingConfirmTotal=${pendingConfirmTotal}
        pendingConfirmVisible=${pendingConfirmVisible}
        pendingConfirmHidden=${pendingConfirmHidden}
        pendingConfirms=${pendingConfirms}
        activeLane=${activeLane}
      />
    </div>
  `
}
