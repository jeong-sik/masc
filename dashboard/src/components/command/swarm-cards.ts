import { html } from 'htm/preact'
import { StatusChip } from '../common/status-chip'

const timeOnlyFmt = new Intl.DateTimeFormat('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false })
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
    <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card ${toneClass(item.status)}">
      <div class="flex justify-between gap-3 items-start">
        <strong>${item.title}</strong>
        <${StatusChip} label=${item.status} tone=${toneClass(item.status)} />
      </div>
      <p>${item.detail}</p>
      <div class="cmd-card rounded-xl-foot">Next tool: ${item.next_tool}</div>
    </article>
  `
}

export function SwarmBlockerCard({ blocker }: { blocker: CommandPlaneSwarmBlocker }) {
  return html`
    <article class="cmd-alert ${toneClass(blocker.severity)} ${alertBorderTone(toneClass(blocker.severity))}">
      <div class="cmd-card rounded-xl-head">
        <strong>${blocker.title}</strong>
        <${StatusChip} label=${blocker.severity} tone=${toneClass(blocker.severity)} />
      </div>
      <div class="flex justify-between items-start">
        <span>${blocker.code}</span>
        <span>next ${blocker.next_tool}</span>
      </div>
      <p>${blocker.detail}</p>
    </article>
  `
}

export function SwarmWorkerCard({ worker }: { worker: CommandPlaneSwarmWorker }) {
  return html`
    <article class="cmd-card rounded-xl p-3">
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${worker.name}</strong>
          <div class="cmd-card rounded-xl-sub">${worker.role} · ${worker.lane}</div>
        </div>
        <${StatusChip} label=${worker.status} tone=${toneClass(worker.joined ? (worker.heartbeat_fresh ? 'ok' : 'warn') : 'bad')} />
      </div>
      <div class="cmd-card rounded-xl-grid">
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
      <div class="cmd-tag rounded-full-row">
        <span class="cmd-tag rounded-full">${worker.lane}</span>
        <span class="cmd-tag rounded-full ${worker.current_task_matches_run ? 'ok' : 'warn'}">current_task</span>
        <span class="cmd-tag rounded-full ${worker.claim_marker_seen ? 'ok' : 'warn'}">claim</span>
        <span class="cmd-tag rounded-full ${worker.done_marker_seen ? 'ok' : 'warn'}">done</span>
        <span class="cmd-tag rounded-full ${worker.final_marker_seen ? 'ok' : 'warn'}">final</span>
      </div>
      ${worker.last_message
        ? html`<div class="cmd-card rounded-xl-foot">${relativeTime(worker.last_message.timestamp)} · ${worker.last_message.content}</div>`
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
      ${dots.map(() => html`<span class="w-2 h-2 rounded-full bg-[rgba(134,160,207,0.7)]"></span>`)}
      ${overflow > 0 ? html`<span class="text-[11px] text-[var(--text-dim,var(--white-50))] ml-1">+${overflow}</span>` : null}
      <span class="text-[11px] text-[var(--text-dim,var(--white-50))] ml-1">(워커 ${total})</span>
    </div>
  `
}

export function SwarmEventNode({ event }: { event: CommandPlaneSwarmTimelineEvent }) {
  const ts = event.timestamp ? new Date(event.timestamp) : null
  const validTs = ts && !isNaN(ts.getTime()) ? ts : null
  const timeStr = validTs ? timeOnlyFmt.format(validTs) : ''
  return html`
    <div class="flex items-start gap-2 relative py-1 text-[0.82rem]">
      <span class="swarm-event-dot ${toneClass(event.tone)}"></span>
      <span class="shrink-0 w-12 text-[11px] text-[var(--text-dim,var(--white-45))]">${timeStr}</span>
      <div class="min-w-0 flex-1">
        <strong>${event.title}</strong>
        <span class="text-[11px] opacity-60 ml-1.5">${event.kind}</span>
        ${event.detail ? html`<div class="cmd-card rounded-xl-sub">${event.detail}</div>` : null}
      </div>
    </div>
  `
}

export function SwarmGapDot({ gap }: { gap: CommandPlaneSwarmGap }) {
  return html`
    <div class="flex items-center gap-1.5 py-[3px] text-[0.78rem]">
      <span class="swarm-gap-dot"></span>
      <${StatusChip} label=${`${gap.code} (${gap.count})`} tone=${toneClass(gap.severity)} />
      <span class="cmd-card rounded-xl-sub">${gap.summary}</span>
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
    <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card ${toneClass(tone)}">
        <div class="flex justify-between gap-3 items-start">
          <strong>Hot Proof / 가동 증거</strong>
          <${StatusChip} label=${proof?.status ?? 'missing'} tone=${toneClass(tone)} />
        </div>
      ${proof
        ? html`
            <div class="cmd-card rounded-xl-grid">
              <span>소스</span><span>${proof.source}</span>
              <span>런</span><span>${proof.run_id ?? 'n/a'}</span>
              <span>수집 시각</span><span>${relativeTime(proof.captured_at)}</span>
              <span>통과</span><span>${proof.pass == null ? 'n/a' : proof.pass ? '예' : '아니오'}</span>
              <span>최대 Hot Slots</span><span>${proof.peak_hot_slots ?? 'n/a'}</span>
              <span>Ctx / Slot</span><span>${proof.ctx_per_slot ?? 'n/a'}</span>
              <span>워커 증거</span><span>${proof.workers.expected ?? 'n/a'} 예상 · ${proof.workers.done ?? 'n/a'} 완료 · ${proof.workers.final ?? 'n/a'} 최종</span>
            </div>
            ${proof.artifact_ref
              ? html`<div class="cmd-card rounded-xl-foot">${proof.artifact_ref}</div>`
              : null}
            ${proof.missing_reason
              ? html`<p>${proof.missing_reason}</p>`
              : null}
          `
        : html`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `
}
