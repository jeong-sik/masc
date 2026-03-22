import { html } from 'htm/preact'
import { roomTruth, roomTruthError, roomTruthLoading } from '../../room-truth-store'
import { toneClass } from '../../lib/tone'

export function RoomTruthStrip() {
  const snapshot = roomTruth.value
  if (!snapshot) {
    if (roomTruthLoading.value) {
      return html`<section class="room-truth-strip room-truth-strip-loading">불러오는 중...</section>`
    }
    if (roomTruthError.value) {
      return html`<section class="room-truth-strip room-truth-strip-error">${roomTruthError.value}</section>`
    }
    return null
  }

  const status = snapshot.room.status
  const counts = snapshot.room.counts
  const execution = snapshot.execution?.summary
  const blocked = execution?.blocked_sessions ?? 0

  return html`
    <section class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3 mb-4">
      <article class="room-truth-card rounded-xl">
        <span class="room-truth-label">현황</span>
        <strong>에이전트 ${counts?.agents ?? 0} · 태스크 ${counts?.tasks ?? 0} · 키퍼 ${counts?.keepers ?? 0}</strong>
        <p>${status?.project ?? 'project'} · ${status?.paused ? '일시정지' : '활성'}</p>
      </article>

      <article class="room-truth-card rounded-xl">
        <span class="room-truth-label">세션</span>
        <strong>활성 ${execution?.active_sessions ?? 0} · 막힘 ${blocked}</strong>
        <div class="flex flex-wrap gap-2">
          <span class="rounded-full ${toneClass(blocked > 0 ? 'warn' : 'ok')}">
            우선 ${execution?.priority_items ?? 0}
          </span>
        </div>
      </article>
    </section>
  `
}
