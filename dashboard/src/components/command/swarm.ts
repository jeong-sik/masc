import { html } from 'htm/preact'
import type {
  CommandPlaneRunResolutionRecommendation,
  CommandPlaneRunResolutionState,
  CommandPlaneSwarmBlocker,
  CommandPlaneSwarmChecklistItem,
  CommandPlaneSwarmFlag,
  CommandPlaneSwarmGap,
  CommandPlaneSwarmLane,
  CommandPlaneSwarmProof,
  CommandPlaneSwarmResponse,
  CommandPlaneSwarmTimelineEvent,
  CommandPlaneSwarmWorker,
} from '../../types'
import {
  commandPlaneSwarm,
  commandPlaneSwarmError,
  commandPlaneSwarmLoading,
} from '../../command-store'
import {
  confirmOperatorPendingAction,
  dispatchOperatorAction,
  operatorActionBusy,
  operatorSnapshot,
} from '../../operator-store'
import { route } from '../../router'
import { PanelSemanticDetails } from '../common/semantic-layer'
import { workflowContextForRoute } from '../../workflow-context'
import { ProvenanceChip } from '../common/provenance-strip'
import {
  currentCommandPlaneSummary,
  dashboardActorName,
  dashboardSwarmOperationId,
  dashboardSwarmRunId,
  relativeTime,
  swarmFocusKey,
  toneClass,
} from './helpers'
import { formatMessageContent } from '../ops/helpers'
import { TraceRow } from './topology'

function previewText(value: unknown): string {
  if (typeof value === 'string') return value
  if (value == null) return ''
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

function runResolutionTone(
  recommendation: CommandPlaneRunResolutionRecommendation | null | undefined,
  resolution: CommandPlaneRunResolutionState | null | undefined,
): string {
  if (resolution?.status === 'abandoned') return 'warn'
  if (recommendation?.recommended_kind === 'continue') return 'warn'
  if (recommendation?.recommended_kind === 'rerun') return 'bad'
  return 'ok'
}

function runResolutionLabel(kind?: string | null): string {
  switch (kind) {
    case 'continue':
    case 'continued':
      return '계속'
    case 'rerun':
      return '재실행'
    case 'abandon':
    case 'abandoned':
      return '포기'
    default:
      return kind?.trim() || '결정'
  }
}

export function SwarmRunResolutionCard({ swarm }: { swarm: CommandPlaneSwarmResponse }) {
  const runId = swarm.run_id
  const recommendation = swarm.resolution_recommendation
  const resolution = swarm.run_resolution
  if (!runId || (!recommendation && !resolution)) return null

  const actor = dashboardActorName() ?? 'dashboard'
  const pendingConfirm =
    operatorSnapshot.value?.pending_confirms.find(item =>
      item.target_type === 'swarm_run' && item.target_id === runId,
    ) ?? null
  const tone = runResolutionTone(recommendation, resolution)
  const operationId = swarm.operation?.operation_id ?? swarm.operation_id ?? undefined
  const basePayload: Record<string, unknown> = {
    run_id: runId,
  }
  if (operationId) basePayload.operation_id = operationId
  if (recommendation?.reason) basePayload.reason = recommendation.reason

  const previewAction = async (actionType: 'swarm_run_continue' | 'swarm_run_rerun' | 'swarm_run_abandon') => {
    await dispatchOperatorAction({
      actor,
      action_type: actionType,
      target_type: 'swarm_run',
      target_id: runId,
      payload: basePayload,
    })
  }

  const confirmPending = async (decision: 'confirm' | 'deny') => {
    if (!pendingConfirm) return
    await confirmOperatorPendingAction(actor, pendingConfirm.confirm_token, decision)
  }

  return html`
    <article class="command-guide-card ${toneClass(tone)}">
      <div class="command-guide-head">
        <strong>Run Resolution</strong>
        <span class="command-chip ${toneClass(tone)}">
          ${runResolutionLabel(resolution?.status ?? recommendation?.recommended_kind ?? null)}
        </span>
      </div>
      <p>
        ${resolution?.status === 'abandoned'
          ? `이 run은 ${resolution.decided_by}가 ${relativeTime(resolution.decided_at)}에 soft abandon 처리했습니다. ${resolution.reason}`
          : recommendation?.reason ?? '이 run에 대한 별도 resolution recommendation은 아직 없습니다.'}
      </p>
      <div class="command-card-grid">
        <span>Run</span><span>${runId}</span>
        <span>Provenance</span><span><${ProvenanceChip} item=${{ kind: recommendation?.provenance ?? 'recorded' }} /></span>
        <span>Engine</span><span>${recommendation?.decision_engine ?? 'operator_record'}</span>
        <span>Authoritative</span><span>${recommendation?.authoritative ? 'yes' : 'no'}</span>
      </div>
      ${recommendation?.evidence
        ? html`
            <div class="command-tag-row">
              <span class="command-tag">joined ${recommendation.evidence.joined_workers ?? 0}</span>
              <span class="command-tag">trace ${recommendation.evidence.trace_events ?? 0}</span>
              <span class="command-tag">message ${recommendation.evidence.message_events ?? 0}</span>
              ${recommendation.evidence.runtime_blocker
                ? html`<span class="command-tag ${toneClass('bad')}">${recommendation.evidence.runtime_blocker}</span>`
                : null}
            </div>
          `
        : null}
      ${pendingConfirm
        ? html`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${pendingConfirm.confirm_token}</span>
              </div>
              ${pendingConfirm.preview ? html`<pre class="command-trace-detail">${previewText(pendingConfirm.preview)}</pre>` : null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${() => { void confirmPending('confirm') }} disabled=${operatorActionBusy.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${() => { void confirmPending('deny') }} disabled=${operatorActionBusy.value}>취소</button>
              </div>
            </div>
          `
        : recommendation
          ? html`
              <div class="command-action-row">
                ${recommendation.continue_available
                  ? html`<button class="control-btn ghost" onClick=${() => { void previewAction('swarm_run_continue') }} disabled=${operatorActionBusy.value}>Continue</button>`
                  : null}
                ${recommendation.rerun_available
                  ? html`<button class="control-btn" onClick=${() => { void previewAction('swarm_run_rerun') }} disabled=${operatorActionBusy.value}>Rerun</button>`
                  : null}
                ${recommendation.abandon_available
                  ? html`<button class="control-btn ghost" onClick=${() => { void previewAction('swarm_run_abandon') }} disabled=${operatorActionBusy.value}>Abandon</button>`
                  : null}
              </div>
            `
          : null}
    </article>
  `
}

function swarmLaneTone(lane: CommandPlaneSwarmLane): string {
  if (lane.motion_state === 'stalled') return 'bad'
  if (lane.hard_flags.some(flag => flag.severity === 'bad')) return 'bad'
  if (lane.motion_state === 'waiting') return 'warn'
  if (lane.hard_flags.some(flag => flag.severity === 'warn')) return 'warn'
  return 'ok'
}

export function SwarmHealthBar({ lanes }: { lanes: CommandPlaneSwarmLane[] }) {
  const counts = { moving: 0, waiting: 0, stalled: 0, terminal: 0 }
  for (const lane of lanes) {
    const m = lane.motion_state as keyof typeof counts
    if (m in counts) counts[m]++
    else counts.waiting++
  }
  const total = lanes.length
  if (total === 0) return null

  const segments: Array<{ key: string; count: number; color: string }> = [
    { key: 'moving', count: counts.moving, color: 'var(--ok)' },
    { key: 'waiting', count: counts.waiting, color: 'var(--warn)' },
    { key: 'stalled', count: counts.stalled, color: 'var(--bad)' },
    { key: 'terminal', count: counts.terminal, color: '#556' },
  ]

  return html`
    <div>
      <div class="swarm-health-bar">
        ${segments.filter(s => s.count > 0).map(s => html`
          <div class="swarm-health-seg ${s.key}" style="flex: ${s.count}"></div>
        `)}
      </div>
      <div class="swarm-health-labels">
        ${segments.filter(s => s.count > 0).map(s => html`
          <span class="swarm-health-label">
            <span class="swarm-health-swatch" style="background: ${s.color}"></span>
            ${s.count} ${s.key}
          </span>
        `)}
      </div>
    </div>
  `
}

function SwarmWorkerGrid({ total }: { total: number }) {
  const maxDots = 20
  const present = Math.min(total, maxDots)
  const overflow = total > maxDots ? total - maxDots : 0
  const dots = Array.from({ length: present })

  return html`
    <div class="swarm-worker-grid">
      ${dots.map(() => html`<span class="swarm-worker-dot present"></span>`)}
      ${overflow > 0 ? html`<span class="swarm-worker-count">+${overflow}</span>` : null}
      <span class="swarm-worker-count">(워커 ${total})</span>
    </div>
  `
}

function SwarmLaneStrip({ lane }: { lane: CommandPlaneSwarmLane }) {
  const counts = lane.counts ?? {}
  const tone = swarmLaneTone(lane)
  const totalWorkers = counts.workers ?? 0
  const ops = counts.operations ?? 0
  const dets = counts.detachments ?? 0
  const totalOps = ops + dets
  const progressPercent =
    lane.motion_state === 'moving'
      ? 84
      : lane.motion_state === 'waiting'
        ? 58
        : lane.motion_state === 'terminal'
          ? 100
          : 26

  return html`
    <article class="swarm-lane-strip ${toneClass(tone)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${lane.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${lane.kind} · ${lane.source_of_truth}</span>
            <strong>${lane.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${toneClass(tone)}">${lane.phase}</span>
          <span class="command-chip ${toneClass(tone)}">${lane.motion_state}</span>
          <span class="command-chip">${relativeTime(lane.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${lane.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${toneClass(tone)}" style=${`width:${progressPercent}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${lane.current_step}</span>
        </div>
        ${totalWorkers > 0
          ? html`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${SwarmWorkerGrid} total=${totalWorkers} />
              </div>
            `
          : null}
        ${totalOps > 0
          ? html`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">흐름</span>
                <div class="swarm-mini-bar">
                  <div class="swarm-mini-bar-fill" style="width: ${totalOps > 0 ? Math.round((ops / totalOps) * 100) : 0}%; background: var(--${tone === 'bad' ? 'bad' : tone === 'warn' ? 'warn' : 'ok'})"></div>
                </div>
                <span class="swarm-worker-count">작전 ${ops} · 실행체 ${dets}</span>
              </div>
            `
          : null}
      </div>
      ${lane.blockers.length > 0
        ? html`<div class="swarm-lane-blockers">막힘: ${lane.blockers.join(' · ')}</div>`
        : null}
      ${lane.hard_flags.length > 0
        ? html`
            <div class="swarm-lane-flags">
              ${lane.hard_flags.map((flag: CommandPlaneSwarmFlag) => html`<span class="command-chip ${toneClass(flag.severity)}">${flag.code}</span>`)}
            </div>
          `
        : null}
    </article>
  `
}

export function SwarmStoryboard({ lanes }: { lanes: CommandPlaneSwarmLane[] }) {
  const featured = lanes.slice(0, 4)
  if (featured.length === 0) return null
  return html`
    <div class="swarm-storyboard">
      ${featured.map(lane => {
        const tone = swarmLaneTone(lane)
        const workers = lane.counts.workers ?? 0
        const operations = lane.counts.operations ?? 0
        const detachments = lane.counts.detachments ?? 0
        return html`
          <article class="swarm-story-card ${toneClass(tone)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${toneClass(tone)}">${lane.motion_state}</span>
              <span class="command-chip">${lane.phase}</span>
            </div>
            <strong>${lane.label}</strong>
            <p>${lane.current_step}</p>
            <div class="swarm-story-strip">
              <span>워커 ${workers}</span>
              <span>작전 ${operations}</span>
              <span>실행체 ${detachments}</span>
            </div>
            <small>${lane.movement_reason}</small>
          </article>
        `
      })}
    </div>
  `
}

function SwarmEventNode({ event }: { event: CommandPlaneSwarmTimelineEvent }) {
  const ts = event.timestamp ? new Date(event.timestamp) : null
  const validTs = ts && !isNaN(ts.getTime()) ? ts : null
  const timeStr = validTs ? `${String(validTs.getHours()).padStart(2, '0')}:${String(validTs.getMinutes()).padStart(2, '0')}` : ''
  return html`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${toneClass(event.tone)}"></span>
      <span class="swarm-event-time">${timeStr}</span>
      <div class="swarm-event-body">
        <strong>${event.title}</strong>
        <span class="swarm-event-kind">${event.kind}</span>
        ${event.detail ? html`<div class="command-card-sub">${event.detail}</div>` : null}
      </div>
    </div>
  `
}

function SwarmGapDot({ gap }: { gap: CommandPlaneSwarmGap }) {
  return html`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${toneClass(gap.severity)}">${gap.code} (${gap.count})</span>
      <span class="command-card-sub">${gap.summary}</span>
    </div>
  `
}

function SwarmProofPanel({ proof }: { proof?: CommandPlaneSwarmProof }) {
  const tone =
    proof?.status === 'missing'
      ? 'warn'
      : proof?.pass === false
        ? 'bad'
        : proof?.pass === true
          ? 'ok'
          : 'warn'
  return html`
    <div class="command-guide-card ${toneClass(tone)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${toneClass(tone)}">${proof?.status ?? 'missing'}</span>
        </div>
      ${proof
        ? html`
            <div class="command-card-grid">
              <span>소스</span><span>${proof.source}</span>
              <span>런</span><span>${proof.run_id ?? 'n/a'}</span>
              <span>수집 시각</span><span>${relativeTime(proof.captured_at)}</span>
              <span>통과</span><span>${proof.pass == null ? 'n/a' : proof.pass ? '예' : '아니오'}</span>
              <span>최대 Hot Slots</span><span>${proof.peak_hot_slots ?? 'n/a'}</span>
              <span>Ctx / Slot</span><span>${proof.ctx_per_slot ?? 'n/a'}</span>
              <span>워커 증거</span><span>${proof.workers.expected ?? 'n/a'} 예상 · ${proof.workers.done ?? 'n/a'} 완료 · ${proof.workers.final ?? 'n/a'} 최종</span>
            </div>
            ${proof.artifact_ref
              ? html`<div class="command-card-foot">${proof.artifact_ref}</div>`
              : null}
            ${proof.missing_reason
              ? html`<p>${proof.missing_reason}</p>`
              : null}
          `
        : html`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `
}

function SwarmPanel() {
  const summary = currentCommandPlaneSummary()
  const workflowContext = workflowContextForRoute(route.value)
  const focusKey = swarmFocusKey(workflowContext)
  const swarm = summary?.swarm_status
  const proof = summary?.swarm_proof
  const lanes = swarm?.lanes.filter(lane => lane.present) ?? []
  const gaps = swarm?.gaps.items ?? []
  const timeline = swarm?.timeline.slice(0, 8) ?? []
  const overview = swarm?.overview
  const recommendation = swarm?.recommended_next_action
  const compactLayout = lanes.length <= 1

  return html`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
      </div>
      ${swarm
        ? html`
            <${SwarmStoryboard} lanes=${lanes} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${overview?.active_lanes ?? 0}</strong><small>${overview?.moving_lanes ?? 0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${overview?.stalled_lanes ?? 0}</strong><small>${overview?.projected_lanes ?? 0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${relativeTime(overview?.last_movement_at)}</strong><small>${swarm.generated_at ? `스냅샷 ${relativeTime(swarm.generated_at)}` : '방금 스냅샷'}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${recommendation?.label ?? '운영자 상태 확인'}</strong><small>${recommendation?.tool ?? 'masc_operator_snapshot'}</small></div>
            </div>

            ${lanes.length > 0 ? html`<${SwarmHealthBar} lanes=${lanes} />` : null}

            <div class="command-swarm-layout ${compactLayout ? 'compact' : ''}">
              <div class="command-card-stack">
                ${lanes.length > 0
                  ? lanes.map(lane => html`<${SwarmLaneStrip} lane=${lane} />`)
                  : html`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight ${focusKey === 'recommendation' ? 'focus' : ''}">
                  <div class="command-guide-head">
                    <strong>${recommendation?.label ?? '운영자 상태 확인'}</strong>
                    <span class="command-chip">${recommendation?.lane_id ?? '전체'}</span>
                  </div>
                  <p>${recommendation?.reason ?? '보이는 활성 스웜 레인이 아직 없습니다.'}</p>
                  <div class="command-card-foot">${recommendation?.tool ?? 'masc_operator_snapshot'}</div>
                </div>

                <${SwarmProofPanel} proof=${proof} />

                <div class="command-guide-card ${gaps.length > 0 ? 'warn' : 'ok'} ${focusKey === 'gaps' ? 'focus' : ''}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${toneClass(gaps.some(gap => gap.severity === 'bad') ? 'bad' : gaps.length > 0 ? 'warn' : 'ok')}">${gaps.length}</span>
                  </div>
                  ${gaps.length > 0
                    ? html`<div class="swarm-event-rail">${gaps.slice(0, 4).map(gap => html`<${SwarmGapDot} gap=${gap} />`)}</div>`
                    : html`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${timeline.length}</span>
                  </div>
                  ${timeline.length > 0
                    ? html`<div class="swarm-event-rail">${timeline.map(event => html`<${SwarmEventNode} event=${event} />`)}</div>`
                    : html`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `
        : html`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `
}

export function SwarmChecklistCard({ item }: { item: CommandPlaneSwarmChecklistItem }) {
  return html`
    <article class="command-guide-card ${toneClass(item.status)}">
      <div class="command-guide-head">
        <strong>${item.title}</strong>
        <span class="command-chip ${toneClass(item.status)}">${item.status}</span>
      </div>
      <p>${item.detail}</p>
      <div class="command-card-foot">Next tool: ${item.next_tool}</div>
    </article>
  `
}

export function SwarmBlockerCard({ blocker }: { blocker: CommandPlaneSwarmBlocker }) {
  return html`
    <article class="command-alert ${toneClass(blocker.severity)}">
      <div class="command-card-head">
        <strong>${blocker.title}</strong>
        <span class="command-chip ${toneClass(blocker.severity)}">${blocker.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${blocker.code}</span>
        <span>next ${blocker.next_tool}</span>
      </div>
      <p>${blocker.detail}</p>
    </article>
  `
}

export function SwarmWorkerCard({ worker }: { worker: CommandPlaneSwarmWorker }) {
  return html`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${worker.name}</strong>
          <div class="command-card-sub">${worker.role} · ${worker.lane}</div>
        </div>
        <span class="command-chip ${toneClass(worker.joined ? (worker.heartbeat_fresh ? 'ok' : 'warn') : 'bad')}">
          ${worker.status}
        </span>
      </div>
      <div class="command-card-grid">
        <span>Joined</span><span>${worker.joined ? 'yes' : 'no'}</span>
        <span>Live</span><span>${worker.live_presence ? 'yes' : 'no'}</span>
        <span>Completed</span><span>${worker.completed ? 'yes' : 'no'}</span>
        <span>Task</span><span>${worker.current_task ?? worker.bound_task_id ?? 'none'}</span>
        <span>Task Title</span><span>${worker.bound_task_title ?? 'n/a'}</span>
        <span>Task Status</span><span>${worker.bound_task_status ?? 'n/a'}</span>
        <span>Heartbeat</span><span>${worker.heartbeat_age_sec != null ? `${Math.round(worker.heartbeat_age_sec)}s` : worker.heartbeat_fresh ? 'completed-cleanly' : 'n/a'}</span>
        <span>Squad</span><span>${worker.squad_member ? 'yes' : 'no'}</span>
        <span>Detachment</span><span>${worker.detachment_member ? 'yes' : 'no'}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${worker.lane}</span>
        <span class="command-tag ${worker.current_task_matches_run ? 'ok' : 'warn'}">current_task</span>
        <span class="command-tag ${worker.claim_marker_seen ? 'ok' : 'warn'}">claim</span>
        <span class="command-tag ${worker.done_marker_seen ? 'ok' : 'warn'}">done</span>
        <span class="command-tag ${worker.final_marker_seen ? 'ok' : 'warn'}">final</span>
      </div>
      ${worker.last_message
        ? html`<div class="command-card-foot">${relativeTime(worker.last_message.timestamp)} · ${worker.last_message.content}</div>`
        : null}
    </article>
  `
}

export function SwarmSurface() {
  const swarm = commandPlaneSwarm.value
  const runId = dashboardSwarmRunId()
  const operationId = dashboardSwarmOperationId()
  const runtimeState = swarm?.provider?.runtime_blocker
    ? 'blocked'
    : swarm?.provider?.provider_reachable
      ? 'ready'
      : 'check'
  const actualSlots = swarm?.provider?.actual_slots ?? swarm?.provider?.total_slots ?? 0
  const expectedSlots = swarm?.provider?.expected_slots ?? 'n/a'
  const actualCtx = swarm?.provider?.actual_ctx ?? swarm?.provider?.ctx_per_slot ?? 0
  const expectedCtx = swarm?.provider?.expected_ctx ?? 'n/a'
  return html`
    <div class="command-section-stack">
      <${SwarmPanel} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
          </div>
          ${commandPlaneSwarmLoading.value
            ? html`<div class="empty-state">Loading swarm live state…</div>`
            : commandPlaneSwarmError.value
              ? html`<div class="empty-state error">${commandPlaneSwarmError.value}</div>`
              : swarm
                ? html`
                    <div class="command-tag-row">
                      <span class="command-tag">experimental</span>
                      <${ProvenanceChip} item=${{ kind: 'derived', label: 'derived read-model' }} />
                      <span class="command-tag ${swarm.run_resolution || swarm.resolution_recommendation ? 'warn' : 'ok'}">
                        ${swarm.run_resolution || swarm.resolution_recommendation ? 'operator resolution aware' : 'no resolution advice'}
                      </span>
                    </div>
                    <div class="command-card-sub">
                      이 화면은 swarm-live의 사회 truth 자체가 아니라, 실험적 오케스트레이션을 읽기 위한 파생 관찰면입니다.
                    </div>
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${swarm.run_id ?? runId ?? 'swarm-live'}</strong><small>${swarm.room_id ?? 'room 정보 없음'}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${swarm.summary?.joined_workers ?? 0}/${swarm.summary?.expected_workers ?? 0}</strong><small>${swarm.summary?.live_workers ?? 0}개 가동 · ${swarm.summary?.completed_workers ?? 0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${runtimeState}</strong><small>slots ${actualSlots}/${expectedSlots} · ctx ${actualCtx}/${expectedCtx}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${swarm.summary?.pass_hot_concurrency ? '통과' : '확인 필요'}</strong><small>${swarm.provider?.slot_url ?? 'slot 정보 없음'}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${swarm.summary?.pass_end_to_end ? '통과' : '확인 필요'}</strong><small>${swarm.recommended_next_tool ?? 'masc_observe_traces'}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${swarm.operation?.operation_id ?? operationId ?? '없음'}</span>
                      <span>분대</span><span>${swarm.squad?.label ?? '없음'}</span>
                      <span>실행체</span><span>${swarm.detachment?.detachment_id ?? '없음'}</span>
                      <span>예상 워커</span><span>${swarm.summary?.expected_workers ?? 0}명</span>
                      <span>최종 마커</span><span>${swarm.summary?.final_markers_seen ?? 0}</span>
                      <span>런타임 막힘</span><span>${swarm.provider?.runtime_blocker ?? '없음'}</span>
                      <span>추천 도구</span><span>${swarm.recommended_next_tool ?? 'masc_observe_traces'}</span>
                    </div>
                    ${swarm.truth_notes.length > 0
                      ? html`<div class="command-tag-row">
                          ${swarm.truth_notes.map(note => html`<span class="command-tag">${note}</span>`)}
                        </div>`
                      : null}
                    <${SwarmRunResolutionCard} swarm=${swarm} />
                  `
                : html`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
          </div>
          ${swarm && swarm.checklist.length > 0
            ? html`<div class="command-card-stack">
                ${swarm.checklist.map(item => html`<${SwarmChecklistCard} item=${item} />`)}
              </div>`
            : html`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
          </div>
          ${swarm && swarm.workers.length > 0
            ? html`<div class="command-card-stack">
                ${swarm.workers.map(worker => html`<${SwarmWorkerCard} worker=${worker} />`)}
              </div>`
            : html`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
          </div>
          ${swarm?.provider
            ? html`
                <div class="command-card-grid">
                  <span>Provider</span><span>${swarm.provider.provider_base_url ?? 'n/a'}</span>
                  <span>Provider Reachable</span><span>${swarm.provider.provider_reachable == null ? 'n/a' : swarm.provider.provider_reachable ? 'yes' : 'no'}</span>
                  <span>Requested Model</span><span>${swarm.provider.provider_model_id ?? 'n/a'}</span>
                  <span>Actual Model</span><span>${swarm.provider.actual_model_id ?? 'n/a'}</span>
                  <span>Slot URL</span><span>${swarm.provider.slot_url ?? 'n/a'}</span>
                  <span>Expected Slots</span><span>${swarm.provider.expected_slots ?? 'n/a'}</span>
                  <span>Actual Slots</span><span>${swarm.provider.actual_slots ?? swarm.provider.total_slots ?? 0}</span>
                  <span>Expected Ctx</span><span>${swarm.provider.expected_ctx ?? 'n/a'}</span>
                  <span>Actual Ctx</span><span>${swarm.provider.actual_ctx ?? swarm.provider.ctx_per_slot ?? 0}</span>
                  <span>Active Now</span><span>${swarm.provider.active_slots_now ?? 0}</span>
                  <span>Peak Active</span><span>${swarm.provider.peak_active_slots ?? 0}</span>
                  <span>Sample Count</span><span>${swarm.provider.sample_count ?? 0}</span>
                  <span>Last Sample</span><span>${swarm.provider.last_sample_at ? relativeTime(swarm.provider.last_sample_at) : 'n/a'}</span>
                  <span>런타임 막힘</span><span>${swarm.provider.runtime_blocker ?? 'none'}</span>
                  <span>Doctor Checked</span><span>${swarm.provider.checked_at ? relativeTime(swarm.provider.checked_at) : 'n/a'}</span>
                </div>
                ${swarm.provider.detail
                  ? html`<div class="command-card-sub">${swarm.provider.detail}</div>`
                  : null}
                ${swarm.provider.timeline.length > 0
                  ? html`<div class="command-trace-stack">
                      ${swarm.provider.timeline.slice(-12).map(sample => html`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${sample.active_slots} active</strong>
                              <span class="command-chip">${relativeTime(sample.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${sample.active_slot_ids.join(', ') || 'none'}</div>
                          </div>
                        </article>
                      `)}
                    </div>`
                  : html`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `
            : html`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
          </div>
          ${swarm && swarm.blockers.length > 0
            ? html`<div class="command-card-stack">
                ${swarm.blockers.map(blocker => html`<${SwarmBlockerCard} blocker=${blocker} />`)}
              </div>`
            : html`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${swarm?.recommended_next_tool ?? 'masc_observe_traces'} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
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
                    <pre class="command-trace-detail">${formatMessageContent(message.content)}</pre>
                  </article>
                `)}
              </div>`
            : html`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${PanelSemanticDetails} panelId="command.trace" compact=${true} />
          </div>
          ${swarm && swarm.recent_trace_events.length > 0
            ? html`<div class="command-trace-stack">
                ${swarm.recent_trace_events.map(event => html`<${TraceRow} event=${event} />`)}
              </div>`
            : html`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `
}
