import { html } from 'htm/preact'
import { displayStatus, relativeTime, sessionStatusTone, toneClass } from './helpers'
import { truncate } from '../../lib/truncate'

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

type WarRoomPresenceView = {
  key: string
  name: string
  role: string
  source: 'agent' | 'keeper' | 'resident'
  status: string
  tone: 'ok' | 'warn' | 'bad'
  task: string
  signal: string
  detail: string
  chips: string[]
  note?: string | null
}

type WarRoomFeedItem = {
  key: string
  title: string
  detail: string
  meta: string
  source: string
  tone: 'ok' | 'warn' | 'bad'
  timestamp?: string | null
  sortTs: number
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

export function WarRoomWorkerCard({ worker }: { worker: WarRoomWorkerView }) {
  return html`
    <article class="command-card p-3 warroom-worker-card ${toneClass(sessionStatusTone(worker.status))}">
      <div class="flex justify-between items-start">
        <div>
          <strong>${worker.name}</strong>
          <div class="text-[var(--white-56)] text-[length:var(--fs-sm)] mt-1 break-words [overflow-wrap:anywhere]">${worker.role} · ${worker.lane}</div>
        </div>
        <span class="command-chip ${toneClass(sessionStatusTone(worker.status))}">${displayStatus(worker.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${warRoomSourceLabel(worker.source)}</span>
        <span>과업</span><span>${worker.task}</span>
        <span>최근 신호</span><span>${worker.heartbeat}</span>
        <span>근거</span><span>${worker.detail}</span>
      </div>
      <div class="command-tag-row mt-2.5">
        ${worker.markers.map(marker => html`<span class="command-tag">${warRoomMarkerLabel(marker)}</span>`)}
      </div>
      ${worker.note
        ? html`<div class="mt-3 pt-3 border-t border-t-[var(--white-8)] text-[#67e8f9] font-mono text-[length:var(--fs-sm)] break-words [overflow-wrap:anywhere]">${truncate(worker.note, 220)}</div>`
        : null}
    </article>
  `
}

export function WarRoomPresenceCard({ item }: { item: WarRoomPresenceView }) {
  return html`
    <article class="command-card p-3 warroom-presence-card ${item.tone}">
      <div class="flex justify-between items-start">
        <div>
          <strong>${item.name}</strong>
          <div class="text-[var(--white-56)] text-[length:var(--fs-sm)] mt-1 break-words [overflow-wrap:anywhere]">${item.role} · ${item.source}</div>
        </div>
        <span class="command-chip ${item.tone}">${item.status}</span>
      </div>
      <div class="command-card-grid">
        <span>현재 과업</span><span>${item.task}</span>
        <span>최근 신호</span><span>${item.signal}</span>
        <span>근거</span><span>${item.detail}</span>
      </div>
      <div class="flex gap-2 flex-wrap mt-2 text-[var(--white-56)] text-[length:var(--fs-sm)]">
        ${item.chips.map(chip => html`<span class="command-tag">${chip}</span>`)}
      </div>
      ${item.note ? html`<div class="mt-3 pt-3 border-t border-t-[var(--white-8)] text-[#67e8f9] font-mono text-[length:var(--fs-sm)] break-words [overflow-wrap:anywhere]">${truncate(item.note, 200)}</div>` : null}
    </article>
  `
}

export function WarRoomFeedCard({ item }: { item: WarRoomFeedItem }) {
  return html`
    <article class="command-trace-row warroom-feed-card ${item.tone}">
      <div class="min-w-0 break-words [overflow-wrap:anywhere]">
        <div class="flex justify-between items-start">
          <strong>${item.title}</strong>
          <span class="command-chip ${item.tone}">${item.timestamp ? relativeTime(item.timestamp) : item.source}</span>
        </div>
        <div class="text-[var(--white-56)] text-[length:var(--fs-sm)] mt-1 break-words [overflow-wrap:anywhere]">${item.meta}</div>
      </div>
      <div class="text-[rgba(226,232,240,0.86)] leading-relaxed whitespace-pre-wrap break-words [overflow-wrap:anywhere]">${item.detail}</div>
    </article>
  `
}

export type { WarRoomWorkerView, WarRoomPresenceView, WarRoomFeedItem }
