import { html } from 'htm/preact'
import type {
  CommandPlaneRunResolutionRecommendation,
  CommandPlaneRunResolutionState,
  CommandPlaneSwarmFlag,
  CommandPlaneSwarmLane,
  CommandPlaneSwarmResponse,
} from '../../types'
import {
  confirmOperatorPendingAction,
  operatorActionBusy,
  operatorSnapshot,
} from '../../operator-store'
import { ProvenanceChip } from '../common/provenance-strip'
import { relativeTime, toneClass } from './helpers'
import { SwarmWorkerGrid } from './swarm-cards'
import { actorName } from '../ops/helpers'

function swarmLaneTone(lane: CommandPlaneSwarmLane): string {
  if (lane.motion_state === 'stalled') return 'bad'
  if (lane.hard_flags.some(flag => flag.severity === 'bad')) return 'bad'
  if (lane.motion_state === 'waiting') return 'warn'
  if (lane.hard_flags.some(flag => flag.severity === 'warn')) return 'warn'
  return 'ok'
}

export function SwarmLaneStrip({ lane }: { lane: CommandPlaneSwarmLane }) {
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
    <article class="swarm-lane-strip transition-colors duration-200 ${toneClass(tone)}">
      <div class="swarm-lane-head flex items-center justify-between gap-2">
        <div class="swarm-lane-head-left flex items-center gap-2 min-w-0">
          <span class="swarm-motion-dot inline-block rounded-full shrink-0 w-2.5 h-2.5 ${lane.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${lane.kind} · ${lane.source_of_truth}</span>
            <strong>${lane.label}</strong>
          </div>
        </div>
        <div class="command-tag rounded-full-row">
          <span class="command-chip rounded-full ${toneClass(tone)}">${lane.phase}</span>
          <span class="command-chip rounded-full ${toneClass(tone)}">${lane.motion_state}</span>
          <span class="command-chip rounded-full">${relativeTime(lane.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${lane.movement_reason}</p>
      <div class="swarm-lane-track rounded-full">
        <span class="${toneClass(tone)}" style=${`width:${progressPercent}%`}></span>
      </div>
      <div class="swarm-lane-details flex flex-col gap-1.5 mt-2">
        <div class="swarm-lane-row flex items-center gap-1.5">
          <span class="swarm-lane-row-label">Step</span>
          <span>${lane.current_step}</span>
        </div>
        ${totalWorkers > 0
          ? html`
              <div class="swarm-lane-row flex items-center gap-1.5">
                <span class="swarm-lane-row-label">워커</span>
                <${SwarmWorkerGrid} total=${totalWorkers} />
              </div>
            `
          : null}
        ${totalOps > 0
          ? html`
              <div class="swarm-lane-row flex items-center gap-1.5">
                <span class="swarm-lane-row-label">흐름</span>
                <div class="swarm-mini-bar flex-1 h-1 rounded-sm overflow-hidden">
                  <div class="swarm-mini-bar-fill" style="width: ${totalOps > 0 ? Math.round((ops / totalOps) * 100) : 0}%; background: var(--${tone === 'bad' ? 'bad' : tone === 'warn' ? 'warn' : 'ok'})"></div>
                </div>
                <span class="swarm-worker-count">작전 ${ops} · 실행체 ${dets}</span>
              </div>
            `
          : null}
      </div>
      ${lane.blockers.length > 0
        ? html`<div class="swarm-lane-blockers rounded-md">막힘: ${lane.blockers.join(' · ')}</div>`
        : null}
      ${lane.hard_flags.length > 0
        ? html`
            <div class="swarm-lane-flags flex flex-wrap gap-1 mt-1">
              ${lane.hard_flags.map((flag: CommandPlaneSwarmFlag) => html`<span class="command-chip rounded-full ${toneClass(flag.severity)}">${flag.code}</span>`)}
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
          <article class="swarm-story-card rounded-xl ${toneClass(tone)}">
            <div class="swarm-story-topline flex justify-between gap-1.5 flex-wrap">
              <span class="command-chip rounded-full ${toneClass(tone)}">${lane.motion_state}</span>
              <span class="command-chip rounded-full">${lane.phase}</span>
            </div>
            <strong>${lane.label}</strong>
            <p>${lane.current_step}</p>
            <div class="swarm-story-strip flex gap-2 flex-wrap">
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
      <div class="swarm-health-bar flex h-2 rounded overflow-hidden">
        ${segments.filter(s => s.count > 0).map(s => html`
          <div class="swarm-health-seg ${s.key}" style="flex: ${s.count}"></div>
        `)}
      </div>
      <div class="swarm-health-labels flex gap-4">
        ${segments.filter(s => s.count > 0).map(s => html`
          <span class="swarm-health-label flex items-center gap-1">
            <span class="swarm-health-swatch w-2 h-2 rounded-sm inline-block" style="background: ${s.color}"></span>
            ${s.count} ${s.key}
          </span>
        `)}
      </div>
    </div>
  `
}

// ── Run Resolution ────────────────────────

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

  const pendingConfirm =
    operatorSnapshot.value?.pending_confirms.find(item =>
      item.target_type === 'swarm_run' && item.target_id === runId,
    ) ?? null
  const tone = runResolutionTone(recommendation, resolution)
  const hasAdvisoryResolutionOnly =
    Boolean(
      recommendation
      && (recommendation.continue_available
        || recommendation.rerun_available
        || recommendation.abandon_available),
    )

  const confirmPending = async (decision: 'confirm' | 'deny') => {
    if (!pendingConfirm) return
    const actor = actorName.value.trim() || 'dashboard'
    await confirmOperatorPendingAction(actor, pendingConfirm.confirm_token, decision)
  }

  return html`
    <article class="command-guide-card rounded-xl ${toneClass(tone)}">
      <div class="command-guide-head">
        <strong>Run Resolution</strong>
        <span class="command-chip rounded-full ${toneClass(tone)}">
          ${runResolutionLabel(resolution?.status ?? recommendation?.recommended_kind ?? null)}
        </span>
      </div>
      <p>
        ${resolution?.status === 'abandoned'
          ? `이 run은 ${resolution.decided_by}가 ${relativeTime(resolution.decided_at)}에 soft abandon 처리했습니다. ${resolution.reason}`
          : recommendation?.reason ?? '이 run에 대한 별도 resolution recommendation은 아직 없습니다.'}
      </p>
      <div class="command-card rounded-xl-grid">
        <span>Run</span><span>${runId}</span>
        <span>Provenance</span><span><${ProvenanceChip} item=${{ kind: recommendation?.provenance ?? 'recorded' }} /></span>
        <span>Engine</span><span>${recommendation?.decision_engine ?? 'operator_record'}</span>
        <span>Authoritative</span><span>${recommendation?.authoritative ? 'yes' : 'no'}</span>
      </div>
      ${recommendation?.evidence
        ? html`
            <div class="command-tag rounded-full-row">
              <span class="command-tag rounded-full">joined ${recommendation.evidence.joined_workers ?? 0}</span>
              <span class="command-tag rounded-full">trace ${recommendation.evidence.trace_events ?? 0}</span>
              <span class="command-tag rounded-full">message ${recommendation.evidence.message_events ?? 0}</span>
              ${recommendation.evidence.runtime_blocker
                ? html`<span class="command-tag rounded-full ${toneClass('bad')}">${recommendation.evidence.runtime_blocker}</span>`
                : null}
            </div>
          `
        : null}
      ${pendingConfirm
        ? html`
            <div class="command-guide-card rounded-xl warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip rounded-full warn">${pendingConfirm.confirm_token}</span>
              </div>
              ${pendingConfirm.preview ? html`<pre class="command-trace-detail">${previewText(pendingConfirm.preview)}</pre>` : null}
              <div class="command-action-row">
                <button class="control-btn rounded-lg" onClick=${() => { void confirmPending('confirm') }} disabled=${operatorActionBusy.value}>확인 실행</button>
                <button class="control-btn rounded-lg ghost" onClick=${() => { void confirmPending('deny') }} disabled=${operatorActionBusy.value}>취소</button>
              </div>
            </div>
          `
        : hasAdvisoryResolutionOnly
          ? html`
              <p>
                Run resolution은 현재 operator action surface에서 직접 실행되지 않습니다.
                이 카드는 recommendation과 recorded resolution만 보여줍니다.
              </p>
            `
          : null}
    </article>
  `
}
