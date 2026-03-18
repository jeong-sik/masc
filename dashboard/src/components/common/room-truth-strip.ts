import { html } from 'htm/preact'
import { navigate } from '../../router'
import { roomTruth, roomTruthError, roomTruthLoading } from '../../room-truth-store'
import { ProvenanceChip } from './provenance-strip'
import { toneClass } from '../../lib/tone'

function openFocus(): void {
  const focus = roomTruth.value?.focus
  if (!focus?.suggested_tab) return
  const params = focus.suggested_params ?? {}
  if (focus.suggested_tab === 'intervene') {
    navigate('control', params)
    return
  }
  navigate('lab', {
    ...(focus.suggested_surface ? { surface: focus.suggested_surface } : {}),
    ...params,
  })
}

export function RoomTruthStrip() {
  const snapshot = roomTruth.value
  if (!snapshot) {
    if (roomTruthLoading.value) {
      return html`<section class="room-truth-strip room-truth-strip-loading">room truth 불러오는 중...</section>`
    }
    if (roomTruthError.value) {
      return html`<section class="room-truth-strip room-truth-strip-error">${roomTruthError.value}</section>`
    }
    return null
  }

  const status = snapshot.room.status
  const counts = snapshot.room.counts
  const execution = snapshot.execution?.summary
  const topQueue = snapshot.execution?.top_queue
  const command = snapshot.command
  const operator = snapshot.operator
  const focus = snapshot.focus

  return html`
    <section class="room-truth-strip">
      <article class="room-truth-card">
        <span class="room-truth-label">room truth</span>
        <strong>${status?.project ?? 'project'} · ${status?.room ?? 'default'}</strong>
        <p>${counts?.agents ?? 0} agents · ${counts?.tasks ?? 0} tasks · ${counts?.keepers ?? 0} keepers</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${status?.paused ? 'warn' : 'ok'}">${status?.paused ? '일시정지' : '열림'}</span>
          <span class="command-chip">${status?.cluster ?? 'cluster:unknown'}</span>
          <${ProvenanceChip} item=${{ kind: snapshot.room.provenance ?? 'truth' }} />
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">execution</span>
        <strong>세션 ${execution?.active_sessions ?? 0} · 막힘 ${execution?.blocked_sessions ?? 0}</strong>
        <p>${topQueue?.summary ?? '지금은 실행 대기열 최상단 항목이 없습니다.'}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${toneClass((execution?.blocked_sessions ?? 0) > 0 ? 'warn' : 'ok')}">priority ${execution?.priority_items ?? 0}</span>
          <${ProvenanceChip} item=${{ kind: snapshot.execution?.provenance ?? 'derived' }} />
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">control</span>
        <strong>작전 ${command?.active_operations ?? 0} · 승인 ${command?.pending_approvals ?? 0}</strong>
        <p>alerts bad ${command?.bad_alerts ?? 0} / warn ${command?.warn_alerts ?? 0} · lanes ${command?.moving_lanes ?? 0}/${command?.active_lanes ?? 0}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${toneClass((command?.bad_alerts ?? 0) > 0 ? 'bad' : (command?.warn_alerts ?? 0) > 0 || (command?.pending_approvals ?? 0) > 0 ? 'warn' : 'ok')}">
            health ${operator?.health ?? 'ok'}
          </span>
          <${ProvenanceChip} item=${{ kind: command?.provenance ?? 'truth' }} />
        </div>
      </article>

      <article class="room-truth-card room-truth-card-focus">
        <span class="room-truth-label">next focus</span>
        <strong>${focus?.label ?? '지금은 방 전체가 비교적 안정적입니다'}</strong>
        <p>${focus?.reason ?? (operator?.attention_summary?.top_item?.summary ?? topQueue?.summary ?? '다음 drill-down 대상이 아직 없습니다.')}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${toneClass(focus?.provenance === 'fallback' ? 'warn' : 'ok')}">${focus?.source ?? 'steady'}</span>
          <${ProvenanceChip} item=${{ kind: focus?.provenance ?? operator?.recommendation_summary?.provenance ?? 'derived' }} />
        </div>
        ${focus?.suggested_tab
          ? html`
              <div class="room-truth-actions">
                <button class="control-btn ghost" onClick=${openFocus}>
                  ${focus.suggested_tab === 'intervene' ? '개입면 열기' : '지휘면 열기'}
                </button>
              </div>
            `
          : null}
      </article>
    </section>
  `
}
