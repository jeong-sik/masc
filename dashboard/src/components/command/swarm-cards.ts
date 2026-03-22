import { html } from 'htm/preact'
import type {
  CommandPlaneSwarmBlocker,
  CommandPlaneSwarmChecklistItem,
  CommandPlaneSwarmGap,
  CommandPlaneSwarmProof,
  CommandPlaneSwarmTimelineEvent,
  CommandPlaneSwarmWorker,
} from '../../types'
import { alertBorderTone, relativeTime, toneClass } from './helpers'

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
    <article class="command-alert ${toneClass(blocker.severity)} ${alertBorderTone(toneClass(blocker.severity))}">
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
    <article class="command-card p-3">
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

export function SwarmWorkerGrid({ total }: { total: number }) {
  const maxDots = 20
  const present = Math.min(total, maxDots)
  const overflow = total > maxDots ? total - maxDots : 0
  const dots = Array.from({ length: present })

  return html`
    <div class="swarm-worker-grid flex flex-wrap gap-[3px] items-center">
      ${dots.map(() => html`<span class="swarm-worker-dot present"></span>`)}
      ${overflow > 0 ? html`<span class="swarm-worker-count">+${overflow}</span>` : null}
      <span class="swarm-worker-count">(워커 ${total})</span>
    </div>
  `
}

export function SwarmEventNode({ event }: { event: CommandPlaneSwarmTimelineEvent }) {
  const ts = event.timestamp ? new Date(event.timestamp) : null
  const validTs = ts && !isNaN(ts.getTime()) ? ts : null
  const timeStr = validTs ? `${String(validTs.getHours()).padStart(2, '0')}:${String(validTs.getMinutes()).padStart(2, '0')}` : ''
  return html`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${toneClass(event.tone)}"></span>
      <span class="swarm-event-time">${timeStr}</span>
      <div class="swarm-event-body min-w-0 flex-1">
        <strong>${event.title}</strong>
        <span class="swarm-event-kind">${event.kind}</span>
        ${event.detail ? html`<div class="command-card-sub">${event.detail}</div>` : null}
      </div>
    </div>
  `
}

export function SwarmGapDot({ gap }: { gap: CommandPlaneSwarmGap }) {
  return html`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${toneClass(gap.severity)}">${gap.code} (${gap.count})</span>
      <span class="command-card-sub">${gap.summary}</span>
    </div>
  `
}

export function SwarmProofPanel({ proof }: { proof?: CommandPlaneSwarmProof }) {
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
