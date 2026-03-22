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
      <div class="flex items-center justify-between gap-2">
        <div class="flex items-center gap-2 min-w-0">
          <span class="swarm-motion-dot inline-block rounded-full shrink-0 w-2.5 h-2.5 ${lane.motion_state}"></span>
          <div>
            <span class="block mb-1 text-[rgba(125,211,252,0.78)] text-[length:var(--fs-2xs)] tracking-[0.1em] uppercase">${lane.kind} · ${lane.source_of_truth}</span>
            <strong class="text-[color:var(--text-near-white)] text-[16px] leading-[1.25]">${lane.label}</strong>
          </div>
        </div>
        <div class="cmd-tag rounded-full-row">
          <span class="cmd-chip rounded-full ${toneClass(tone)}">${lane.phase}</span>
          <span class="cmd-chip rounded-full ${toneClass(tone)}">${lane.motion_state}</span>
          <span class="cmd-chip rounded-full">${relativeTime(lane.last_movement_at)}</span>
        </div>
      </div>
      <p class="mt-2.5 mb-0 text-[color:var(--frost-72)] leading-[1.5]">${lane.movement_reason}</p>
      <div class="swarm-lane-track rounded-full">
        <span class="${toneClass(tone)}" style=${`width:${progressPercent}%`}></span>
      </div>
      <div class="flex flex-col gap-1.5 mt-2 text-[0.82rem]">
        <div class="flex items-center gap-1.5 text-[color:var(--text-dim,var(--white-55))]">
          <span class="shrink-0 w-14 text-[0.72rem] uppercase tracking-[0.04em] opacity-60">Step</span>
          <span>${lane.current_step}</span>
        </div>
        ${totalWorkers > 0
          ? html`
              <div class="flex items-center gap-1.5 text-[color:var(--text-dim,var(--white-55))]">
                <span class="shrink-0 w-14 text-[0.72rem] uppercase tracking-[0.04em] opacity-60">워커</span>
                <${SwarmWorkerGrid} total=${totalWorkers} />
              </div>
            `
          : null}
        ${totalOps > 0
          ? html`
              <div class="flex items-center gap-1.5 text-[color:var(--text-dim,var(--white-55))]">
                <span class="shrink-0 w-14 text-[0.72rem] uppercase tracking-[0.04em] opacity-60">흐름</span>
                <div class="flex-1 h-1 rounded-sm overflow-hidden bg-[var(--white-8)]">
                  <div class="h-full rounded-sm bg-[var(--ok)] transition-[width] duration-300 ease-in-out" style="width: ${totalOps > 0 ? Math.round((ops / totalOps) * 100) : 0}%; background: var(--${tone === 'bad' ? 'bad' : tone === 'warn' ? 'warn' : 'ok'})"></div>
                </div>
                <span class="text-[0.72rem] text-[color:var(--text-dim,var(--white-50))] ml-1">작전 ${ops} · 실행체 ${dets}</span>
              </div>
            `
          : null}
      </div>
      ${lane.blockers.length > 0
        ? html`<div class="bg-[rgba(239,68,68,0.1)] border border-[rgba(239,68,68,0.25)] py-1.5 px-2.5 text-[0.78rem] text-[color:var(--bad)] mt-1 rounded-md">막힘: ${lane.blockers.join(' · ')}</div>`
        : null}
      ${lane.hard_flags.length > 0
        ? html`
            <div class="flex flex-wrap gap-1 mt-1">
              ${lane.hard_flags.map((flag: CommandPlaneSwarmFlag) => html`<span class="cmd-chip rounded-full ${toneClass(flag.severity)}">${flag.code}</span>`)}
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
    <div class="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-2.5 mb-3.5">
      ${featured.map(lane => {
        const tone = swarmLaneTone(lane)
        const workers = lane.counts.workers ?? 0
        const operations = lane.counts.operations ?? 0
        const detachments = lane.counts.detachments ?? 0
        return html`
          <article class="swarm-story-card rounded-xl ${toneClass(tone)}">
            <div class="swarm-story-topline flex justify-between gap-1.5 flex-wrap">
              <span class="cmd-chip rounded-full ${toneClass(tone)}">${lane.motion_state}</span>
              <span class="cmd-chip rounded-full">${lane.phase}</span>
            </div>
            <strong class="text-[color:var(--text-near-white)] text-[length:var(--fs-lg)] leading-[1.3]">${lane.label}</strong>
            <p class="m-0 text-[color:var(--frost-72)] leading-[1.5]">${lane.current_step}</p>
            <div class="flex gap-2 flex-wrap">
              ${[`워커 ${workers}`, `작전 ${operations}`, `실행체 ${detachments}`].map(t => html`
                <span class="inline-flex items-center py-1 px-2 bg-[var(--white-6)] text-[rgba(191,219,254,0.9)] text-[length:var(--fs-xs)]">${t}</span>
              `)}
            </div>
            <small class="m-0 text-[color:var(--frost-72)] leading-[1.5]">${lane.movement_reason}</small>
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
      <div class="flex h-2 rounded overflow-hidden bg-[var(--white-6)] mt-3">
        ${segments.filter(s => s.count > 0).map(s => html`
          <div class="swarm-health-seg ${s.key}" style="flex: ${s.count}"></div>
        `)}
      </div>
      <div class="flex gap-4 text-[0.75rem] text-[color:var(--text-dim,var(--white-50))] mt-1.5">
        ${segments.filter(s => s.count > 0).map(s => html`
          <span class="flex items-center gap-1">
            <span class="w-2 h-2 rounded-sm inline-block" style="background: ${s.color}"></span>
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
    <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-3.5 rounded-xl cmd-guide-card ${toneClass(tone)}">
      <div class="flex justify-between gap-2.5 items-start">
        <strong>Run Resolution</strong>
        <span class="cmd-chip rounded-full ${toneClass(tone)}">
          ${runResolutionLabel(resolution?.status ?? recommendation?.recommended_kind ?? null)}
        </span>
      </div>
      <p>
        ${resolution?.status === 'abandoned'
          ? `이 run은 ${resolution.decided_by}가 ${relativeTime(resolution.decided_at)}에 soft abandon 처리했습니다. ${resolution.reason}`
          : recommendation?.reason ?? '이 run에 대한 별도 resolution recommendation은 아직 없습니다.'}
      </p>
      <div class="cmd-card rounded-xl-grid">
        <span>Run</span><span>${runId}</span>
        <span>Provenance</span><span><${ProvenanceChip} item=${{ kind: recommendation?.provenance ?? 'recorded' }} /></span>
        <span>Engine</span><span>${recommendation?.decision_engine ?? 'operator_record'}</span>
        <span>Authoritative</span><span>${recommendation?.authoritative ? 'yes' : 'no'}</span>
      </div>
      ${recommendation?.evidence
        ? html`
            <div class="cmd-tag rounded-full-row">
              <span class="cmd-tag rounded-full">joined ${recommendation.evidence.joined_workers ?? 0}</span>
              <span class="cmd-tag rounded-full">trace ${recommendation.evidence.trace_events ?? 0}</span>
              <span class="cmd-tag rounded-full">message ${recommendation.evidence.message_events ?? 0}</span>
              ${recommendation.evidence.runtime_blocker
                ? html`<span class="cmd-tag rounded-full ${toneClass('bad')}">${recommendation.evidence.runtime_blocker}</span>`
                : null}
            </div>
          `
        : null}
      ${pendingConfirm
        ? html`
            <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-3.5 rounded-xl cmd-guide-card warn">
              <div class="flex justify-between gap-2.5 items-start">
                <strong>확인 대기</strong>
                <span class="cmd-chip rounded-full warn">${pendingConfirm.confirm_token}</span>
              </div>
              ${pendingConfirm.preview ? html`<pre class="m-0 p-3 rounded-[10px] bg-[rgba(9,12,20,0.75)] text-[rgba(224,242,254,0.92)] text-[length:var(--fs-sm)] leading-[1.45] max-h-[220px] overflow-auto whitespace-pre-wrap break-words [overflow-wrap:anywhere]">${previewText(pendingConfirm.preview)}</pre>` : null}
              <div class="flex gap-2.5 flex-wrap mt-3">
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
