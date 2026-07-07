// MASC Dashboard — V2 Schedule Surface
// Grounded in lib/schedule/ — a keeper schedules future intent; operator
// approves before the runner fires at due time.

import { html } from 'htm/preact'
import { useEffect, useState, useMemo } from 'preact/hooks'
import { ConnectionStatus } from '../dashboard-shell'
import { ErrorState, LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { showToast } from '../common/toast'
import { SigilBadge } from '../v2/primitives-v2'
import { kSigil, kSlot } from '../keeper-badge'
import {
  loadTools,
  toolsData,
  toolsError,
  toolsLoading,
} from '../tools/tool-state'
import {
  pruneSchedules,
  resolveScheduleApproval,
  type DashboardScheduleDecision,
} from '../../api/dashboard-governance'
import {
  schedPayloadSpec,
  schedRiskSpec,
  schedStatusSpec,
  SCHED_TERMINAL,
} from '../v2/schedule-constants'
import { selectedAgentName } from '../agent-detail-selection'
import type { DashboardScheduledAutomationRequest, DashboardScheduledAutomationSignal } from '../../api'

// Helper to check if status is terminal
function isTerminalStatus(status: string | null | undefined): boolean {
  if (!status) return false
  const s = status.trim().toLowerCase()
  return SCHED_TERMINAL.map(x => x.toLowerCase()).includes(s)
}

// Recurrence cadence check
function schedCadence(s: DashboardScheduledAutomationRequest): 'oneshot' | 'interval' | 'daily' {
  const r = s.recurrence
  const kind = r?.kind ?? s.recurrence_kind ?? 'one_shot'
  const normalizedKind = kind.trim().toLowerCase()
  if (normalizedKind === 'interval') return 'interval'
  if (normalizedKind === 'daily') return 'daily'
  return 'oneshot'
}

function schedFmtInterval(sec: number): string {
  if (sec % 86400 === 0) return `매 ${sec / 86400}d`
  if (sec % 3600 === 0) return `매 ${sec / 3600}h`
  if (sec % 60 === 0) return `매 ${sec / 60}m`
  return `매 ${sec}s`
}

function schedRecurrenceText(r: any): string {
  if (!r) return '1회'
  const kind = (r.kind ?? '').trim().toLowerCase()
  if (kind === 'one_shot' || kind === 'oneshot') return '1회'
  if (kind === 'interval') return schedFmtInterval(r.interval_sec ?? 0)
  if (kind === 'daily') {
    const hh = String(r.hour ?? 0).padStart(2, '0')
    const mm = String(r.minute ?? 0).padStart(2, '0')
    return `매일 ${hh}:${mm} ${r.timezone ?? 'KST'}`
  }
  return '1회'
}

function schedNow(): Date {
  return new Date()
}

function formatTimeOnly(date: Date): string {
  const hh = String(date.getHours()).padStart(2, '0')
  const mm = String(date.getMinutes()).padStart(2, '0')
  return `${hh}:${mm}`
}

function schedNextTick(intervalSec: number, now: Date): Date {
  const midnight = new Date(now)
  midnight.setHours(0, 0, 0, 0)
  const elapsed = Math.floor((now.getTime() - midnight.getTime()) / 1000)
  const next = Math.ceil((elapsed + 1) / intervalSec) * intervalSec
  return new Date(midnight.getTime() + next * 1000)
}

interface AgendaEvent {
  s: DashboardScheduledAutomationRequest
  at: Date
  cad: 'oneshot' | 'interval' | 'daily'
}

interface AgendaColumn {
  offset: number
  date: Date
  events: AgendaEvent[]
}

function schedAgenda(list: DashboardScheduledAutomationRequest[], days = 7): AgendaColumn[] {
  const now = schedNow()
  const d0 = new Date(now)
  d0.setHours(0, 0, 0, 0)
  
  const cols: AgendaColumn[] = []
  for (let i = 0; i < days; i++) {
    const date = new Date(d0)
    date.setDate(d0.getDate() + i)
    cols.push({ offset: i, date, events: [] })
  }

  const dayOffset = (dt: Date) => {
    const x = new Date(dt)
    x.setHours(0, 0, 0, 0)
    return Math.round((x.getTime() - d0.getTime()) / 86400000)
  }

  list.forEach(s => {
    if (isTerminalStatus(s.status)) return
    const cad = schedCadence(s)
    if (cad === 'interval') return
    
    if (cad === 'daily') {
      const r = s.recurrence
      const hour = r?.hour ?? 0
      const minute = r?.minute ?? 0
      for (let i = 0; i < days; i++) {
        const dt = new Date(d0)
        dt.setDate(d0.getDate() + i)
        dt.setHours(hour, minute, 0, 0)
        if (i === 0 && dt < now) continue // already passed today
        const col = cols[i]
        if (col) {
          col.events.push({ s, at: dt, cad })
        }
      }
    } else {
      const dueIso = s.next_due_at_iso ?? s.due_at_iso ?? null
      const dt = dueIso ? new Date(dueIso) : now
      let off = dayOffset(dt)
      if (off < 0) off = 0 // overdue -> show today
      if (off >= 0 && off < days) {
        const col = cols[off]
        if (col) {
          col.events.push({ s, at: dt, cad })
        }
      }
    }
  })

  cols.forEach(c => c.events.sort((a, b) => a.at.getTime() - b.at.getTime()))
  return cols
}

function schedCadenceCounts(list: DashboardScheduledAutomationRequest[]) {
  const out = { oneshot: 0, interval: 0, daily: 0 }
  list.forEach(s => {
    out[schedCadence(s)]++
  })
  return out
}

function countByStatus(list: DashboardScheduledAutomationRequest[], statuses: string[]): number {
  const norm = statuses.map(s => s.trim().toLowerCase())
  return list.filter(s => norm.includes((s.status ?? '').trim().toLowerCase())).length
}

const SCH_TABS: ReadonlyArray<[string, string, readonly string[] | null]> = [
  ['pending', '승인 대기', ['pending_approval', 'awaiting_approval', 'blocked_approval']],
  ['scheduled', '예약됨', ['scheduled']],
  ['active', 'due · 실행', ['due', 'running']],
  ['done', '완료 · 종료', SCHED_TERMINAL],
  ['all', '전체', null],
]

const SCHED_CADENCE_SPECS = {
  oneshot:  { key: 'oneshot',  lbl: '1회 · ad-hoc', short: '1회',  glyph: '•', cls: 'info', hint: '한 번 실행하고 종료 — keeper가 상황에 맞춰 건 단발성 예약' },
  interval: { key: 'interval', lbl: '폴링 · 주기',   short: '폴링', glyph: '↻', cls: 'volt', hint: '고정 간격마다 반복 — 상시 폴링 루프' },
  daily:    { key: 'daily',    lbl: '정기 · 매일',   short: '정기', glyph: '◈', cls: 'ok',   hint: '매일 지정 시각에 반복되는 정기 잡' },
}

// --- V2 Subcomponents ---

function SchStatusPill({ status }: { status: string }) {
  const d = schedStatusSpec(status)
  return html`<span class=${`sch-pill ${d.cls}`}>${d.glyph} ${d.lbl}</span>`
}

function SchRisk({ risk }: { risk: string }) {
  const d = schedRiskSpec(risk)
  return html`<span class=${`sch-risk ${d.cls}`} title=${`risk_class = ${risk}`}>${d.lbl}</span>`
}

function SchCadenceTag({ cad, full }: { cad: 'oneshot' | 'interval' | 'daily'; full?: boolean }) {
  const d = SCHED_CADENCE_SPECS[cad] || SCHED_CADENCE_SPECS.oneshot
  return html`<span class=${`sch-cad ${d.cls}`} title=${d.hint}>${d.glyph} ${full ? d.lbl : d.short}</span>`
}

function SchCard({
  s,
  onOpen,
  onAct,
  onOpenKeeper,
}: {
  s: DashboardScheduledAutomationRequest
  onOpen: (s: DashboardScheduledAutomationRequest) => void
  onAct: (id: string, action: DashboardScheduleDecision, reason?: string) => void
  onOpenKeeper: (id: string) => void
}) {
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const statusNorm = (s.status ?? '').trim().toLowerCase()
  const pending = ['pending_approval', 'awaiting_approval'].includes(statusNorm)
  
  const pl = schedPayloadSpec(s.payload_kind)
  const slot = kSlot(s.scheduled_by?.id ?? '')
  const sigil = kSigil(s.scheduled_by?.id ?? '')
  const dueIso = s.next_due_at_iso ?? s.due_at_iso ?? null
  const dueRel = dueIso ? formatTimeOnly(new Date(dueIso)) : '-'

  return html`
    <article class=${`sch-card st-${schedStatusSpec(s.status).cls}`}>
      <div class="sch-card-rail"></div>
      <div class="sch-card-main">
        <button class="sch-card-head" onClick=${() => onOpen(s)}>
          <span class="sch-kind">${pl.glyph} ${pl.lbl}</span>
          <span class="sch-id mono">${s.schedule_id}</span>
          <${SchCadenceTag} cad=${schedCadence(s)} />
          <${SchRisk} risk=${s.risk_class} />
          <span class="sch-rec mono" title="recurrence">↻ ${schedRecurrenceText(s.recurrence)}</span>
          <span class="sch-head-sp"></span>
          <${SchStatusPill} status=${s.status} />
        </button>
        <button class="sch-summary" onClick=${() => onOpen(s)}>${s.payload_summary ?? '작업 상세 내용 없음'}</button>
        <div class="sch-meta">
          <span class="sch-by">
            <${SigilBadge} slot=${slot} sigil=${sigil} size=${22} />
            <button class="sch-klink" onClick=${() => onOpenKeeper(s.scheduled_by?.id ?? '')} title=${`${s.scheduled_by?.id} 대화 열기`}>
              ${s.scheduled_by?.id ?? '-'}
            </button>
            <span class="sch-actor-kind mono">예약</span>
          </span>
          <span class="sch-due" title="due_at"><span class="sub-k">due</span>${dueRel}</span>
          ${s.approval_required && pending ? html`<span class="sch-need mono" title="별도 사람(operator) 승인 필요">⊙ 승인 필요</span>` : null}
          ${statusNorm === 'scheduled' || statusNorm === 'running' || statusNorm === 'succeeded'
            ? html`<span class="sch-grant mono">✓ 승인됨</span>`
            : null}
        </div>

        ${pending && !rejecting
          ? html`
              <div class="sch-actions">
                <button class="sch-act approve" onClick=${() => onAct(s.schedule_id, 'approve')}>승인</button>
                <button class="sch-act deny" onClick=${() => setRejecting(true)}>거부</button>
                <button class="sch-act ghost" onClick=${() => onOpen(s)}>상세 →</button>
              </div>
            `
          : null}
          
        ${rejecting
          ? html`
              <div class="sch-reject">
                <input
                  class="sch-reject-in mono"
                  placeholder="거부 사유 (operator 결정)"
                  value=${reason}
                  onChange=${(e: any) => setReason(e.target.value)}
                  onKeyDown=${(e: any) => {
                    if (e.key === 'Enter' && reason.trim()) {
                      onAct(s.schedule_id, 'reject', reason.trim())
                    }
                  }}
                  autoFocus
                />
                <button class="sch-act deny" disabled=${!reason.trim()} onClick=${() => onAct(s.schedule_id, 'reject', reason.trim())}>거부 확정</button>
                <button class="sch-act ghost" onClick=${() => { setRejecting(false); setReason(''); }}>취소</button>
              </div>
            `
          : null}
      </div>
    </article>
  `
}

function SchCadenceSummary({
  list,
  filter,
  onFilter,
}: {
  list: DashboardScheduledAutomationRequest[]
  filter: string | null
  onFilter: (key: string | null) => void
}) {
  const counts = schedCadenceCounts(list)
  return html`
    <div class="sch-cadsum">
      ${(['daily', 'interval', 'oneshot'] as const).map(key => {
        const d = SCHED_CADENCE_SPECS[key]
        const on = filter === key
        return html`
          <button
            key=${key}
            class=${`sch-cadsum-i ${d.cls} ${on ? 'on' : ''} ${filter && !on ? 'off' : ''}`}
            onClick=${() => onFilter(on ? null : key)}
            title=${d.hint}
          >
            <span class="sch-cadsum-gl">${d.glyph}</span>
            <span class="sch-cadsum-n mono">${counts[key]}</span>
            <span class="sch-cadsum-l">${d.lbl}</span>
          </button>
        `
      })}
    </div>
  `
}

function SchPollingStrip({
  list,
  onOpen,
}: {
  list: DashboardScheduledAutomationRequest[]
  onOpen: (s: DashboardScheduledAutomationRequest) => void
}) {
  const now = schedNow()
  const polls = list.filter(s => schedCadence(s) === 'interval' && !isTerminalStatus(s.status))
  return html`
    <section class="sch-poll">
      <div class="sch-poll-h">
        <span class="sch-cad volt">↻ 상시 폴링</span>
        <span class="sch-poll-sub">고정 간격 반복 — 특정 시각이 아니라 계속 돎</span>
      </div>
      ${polls.length === 0
        ? html`<div class="sch-day-empty mono">활성 폴링 없음</div>`
        : html`
            <div class="sch-poll-list">
              ${polls.map(s => {
                const kId = s.scheduled_by?.id ?? ''
                const slot = kSlot(kId)
                const sigil = kSigil(kId)
                const pl = schedPayloadSpec(s.payload_kind)
                const st = schedStatusSpec(s.status)
                
                const interval = s.recurrence?.interval_sec ?? 60
                const next = schedNextTick(interval, now)
                
                return html`
                  <button key=${s.schedule_id} class=${`sch-poll-card st-${st.cls}`} onClick=${() => onOpen(s)}>
                    <div class="sch-poll-top">
                      <span class="sch-poll-int mono">↻ ${schedRecurrenceText(s.recurrence)}</span>
                      <span class=${`sch-pill ${st.cls}`}>${st.glyph} ${st.lbl}</span>
                    </div>
                    <div class="sch-poll-title">${pl.glyph} ${s.payload_summary ?? '작업'}</div>
                    <div class="sch-poll-foot">
                      <${SigilBadge} slot=${slot} sigil=${sigil} size=${18} />
                      <span class="mono sch-poll-by">${kId}</span>
                      <${SchRisk} risk=${s.risk_class} />
                      <span class="sch-poll-next mono" title="다음 tick 예상 시각">다음 ~${formatTimeOnly(next)}</span>
                    </div>
                  </button>
                `
              })}
            </div>
          `}
    </section>
  `
}

const SCH_WD = ['일', '월', '화', '수', '목', '금', '토']

function SchAgenda({
  list,
  filter,
  onOpen,
}: {
  list: DashboardScheduledAutomationRequest[]
  filter: string | null
  onOpen: (s: DashboardScheduledAutomationRequest) => void
}) {
  const cols = schedAgenda(list, 7)
  const now = schedNow()
  
  const rel = (o: number) => (o === 0 ? '오늘' : o === 1 ? '내일' : `+${o}일`)
  
  const rows = cols
    .map(col => {
      const evs = filter ? col.events.filter(e => e.cad === filter) : col.events
      return { col, evs }
    })
    .filter(r => r.evs.length || r.col.offset <= 1)
    
  const hasAny = rows.some(r => r.evs.length)
  
  return html`
    <div class="sch-agenda">
      ${!hasAny ? html`<div class="sch-empty">다가오는 7일에 예정된 ${filter ? (SCHED_CADENCE_SPECS[filter as 'oneshot'] || {}).lbl + ' ' : ''}예약이 없습니다.</div>` : null}
      ${rows.map(({ col, evs }) => {
        const isToday = col.offset === 0
        return html`
          <div key=${col.offset} class=${`sch-day ${isToday ? 'today' : ''}`}>
            <div class="sch-day-h">
              <span class="sch-day-rel">${rel(col.offset)}</span>
              <span class="sch-day-date mono">${col.date.getMonth() + 1}/${col.date.getDate()} (${SCH_WD[col.date.getDay()]})</span>
              ${isToday ? html`<span class="sch-day-now mono">지금 ${formatTimeOnly(now)}</span>` : null}
              <span class="sch-day-n mono">${evs.length ? `${evs.length}건` : ''}</span>
            </div>
            ${evs.length === 0
              ? html`<div class="sch-day-empty mono">예정 없음</div>`
              : html`
                  <div class="sch-day-evs">
                    ${evs.map((e, i) => {
                      const s = e.s
                      const kId = s.scheduled_by?.id ?? ''
                      const slot = kSlot(kId)
                      const sigil = kSigil(kId)
                      const pl = schedPayloadSpec(s.payload_kind)
                      const st = schedStatusSpec(s.status)
                      const statusNorm = (s.status ?? '').trim().toLowerCase()
                      const pending = ['pending_approval', 'awaiting_approval'].includes(statusNorm)
                      
                      return html`
                        <button key=${s.schedule_id + '@' + i} class=${`sch-ev st-${st.cls} ${pending ? 'pending' : ''}`} onClick=${() => onOpen(s)}>
                          <span class="sch-ev-time mono">${formatTimeOnly(e.at)}</span>
                          <${SchCadenceTag} cad=${e.cad} />
                          <span class="sch-ev-body">
                            <span class="sch-ev-title">${pl.glyph} ${s.payload_summary ?? '작업'}</span>
                            <span class="sch-ev-meta">
                              <${SigilBadge} slot=${slot} sigil=${sigil} size=${16} />
                              <span class="mono sch-ev-by">${kId}</span>
                              <${SchRisk} risk=${s.risk_class} />
                              ${pending ? html`<span class="sch-ev-need mono">⊙ 승인 필요</span>` : null}
                            </span>
                          </span>
                          <span class=${`sch-pill ${st.cls}`}>${st.glyph} ${st.lbl}</span>
                        </button>
                      `
                    })}
                  </div>
                `}
          </div>
        `
      })}
    </div>
  `
}

function SchDetail({
  s,
  onClose,
  onAct,
  onOpenKeeper,
}: {
  s: DashboardScheduledAutomationRequest
  onClose: () => void
  onAct: (id: string, action: DashboardScheduleDecision, reason?: string) => void
  onOpenKeeper: (id: string) => void
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  const pl = schedPayloadSpec(s.payload_kind)
  const statusNorm = (s.status ?? '').trim().toLowerCase()
  const pending = ['pending_approval', 'awaiting_approval'].includes(statusNorm)
  
  const kv = (k: string, v: string) => html`
    <div class="sch-kv">
      <span class="k">${k}</span>
      <span class="v mono">${v}</span>
    </div>
  `

  return html`
    <div class="turn-overlay" onClick=${onClose}>
      <div class="turn-drawer sch-drawer" onClick=${(e: any) => e.stopPropagation()}>
        <div class="turn-hd">
          <h3>예약 상세</h3>
          <span class="tid">${s.schedule_id}</span>
          <span class="sch-hd-sp" style=${{ marginLeft: 'auto' }}></span>
          <${SchStatusPill} status=${s.status} />
          <button class="turn-close" onClick=${onClose} title="닫기 (Esc)">✕</button>
        </div>
        <div class="turn-body">
          <div class="turn-sec">
            <h4>${pl.glyph} ${pl.lbl}</h4>
            <p class="sch-d-summary">${s.payload_summary ?? '작업 상세 내용 없음'}</p>
            <div class="sch-badges">
              <${SchRisk} risk=${s.risk_class} />
              <span class="sch-rec mono">↻ ${schedRecurrenceText(s.recurrence)}</span>
              <span class="sch-src mono">${enumLabel(s.source)}</span>
            </div>
          </div>

          <div class="turn-sec">
            <h4>주체 · 직무분리</h4>
            <div class="sch-kvs">
              ${kv('요청자', `${s.requested_by?.id ?? '-'} (${enumLabel(s.requested_by?.kind)})`)}
              ${kv('예약자', `${s.scheduled_by?.id ?? '-'} (${enumLabel(s.scheduled_by?.kind)})`)}
              ${kv('승인 필요 여부', String(s.approval_required))}
            </div>
            <div class="sch-sod">
              승인자(operator)는 요청자·예약자와 달라야 실행 grant가 발급됩니다 — 예약 주체는 keeper(<b>${s.scheduled_by?.id ?? ''}</b>), 승인 주체는 operator.
            </div>
          </div>

          <div class="turn-sec">
            <h4>타이밍</h4>
            <div class="sch-kvs">
              ${kv('생성 시각', formatDateTimeKo(s.requested_at_iso))}
              ${kv('실행 예정 (Due)', formatDateTimeKo(s.next_due_at_iso ?? s.due_at_iso))}
              ${kv('만료 시각', formatDateTimeKo(s.expires_at_iso))}
              ${kv('반복 조건', s.recurrence?.kind ?? s.recurrence_kind ?? 'one_shot')}
            </div>
          </div>

          <div class="turn-sec">
            <h4>payload 봉투</h4>
            <pre class="turn-pre">${JSON.stringify({ kind: s.payload_kind, schema_version: 1, body: s.payload_target }, null, 2)}</pre>
          </div>

          ${statusNorm === 'rejected' || statusNorm === 'cancelled' || statusNorm === 'canceled' || statusNorm === 'scheduled' || statusNorm === 'running' || statusNorm === 'succeeded'
            ? html`
                <div class="turn-sec">
                  <h4>결정 기록</h4>
                  ${statusNorm === 'scheduled' || statusNorm === 'running' || statusNorm === 'succeeded' ? html`<div class="sch-decision ok">✓ 승인됨</div>` : null}
                  ${statusNorm === 'rejected' ? html`<div class="sch-decision bad">⊘ 거부됨</div>` : null}
                  ${statusNorm === 'cancelled' || statusNorm === 'canceled' ? html`<div class="sch-decision dim">◌ 취소됨</div>` : null}
                </div>
              `
            : null}

          ${s.last_execution
            ? html`
                <div class="turn-sec">
                  <h4>최근 실행 기록</h4>
                  <div class="sch-kvs">
                    ${kv('상태', s.last_execution.status ?? '-')}
                    ${kv('시작', formatDateTimeKo(s.last_execution.started_at_iso))}
                    ${kv('종료', formatDateTimeKo(s.last_execution.finished_at_iso))}
                  </div>
                  ${s.last_execution.error ? html`<div class="sch-exec bad">${s.last_execution.error}</div>` : null}
                </div>
              `
            : null}

          ${pending
            ? html`
                <div class="turn-sec sch-detail-actions">
                  <button class="sch-act approve" onClick=${() => { onAct(s.schedule_id, 'approve'); onClose(); }}>승인 — grant 발급</button>
                  <button class="sch-act deny" onClick=${() => { const r = window.prompt('거부 사유 (operator 결정)') || ''; if (r.trim()) { onAct(s.schedule_id, 'reject', r.trim()); onClose(); } }}>거부</button>
                  <button class="sch-act ghost" onClick=${() => onOpenKeeper(s.scheduled_by?.id ?? '')}>${s.scheduled_by?.id ?? '-'} 대화 →</button>
                </div>
              `
            : null}
        </div>
      </div>
    </div>
  `
}

function SchAside({
  list,
  sum,
  onOpen,
}: {
  list: DashboardScheduledAutomationRequest[]
  sum: { scheduled: number; dueRunning: number; pending: number; total: number }
  onOpen: (id: string) => void
}) {
  const failed = list.filter(s => (s.status ?? '').trim().toLowerCase() === 'failed')
  const pending = list.filter(s => ['pending_approval', 'awaiting_approval'].includes((s.status ?? '').trim().toLowerCase()))
  const due = list.filter(s => (s.status ?? '').trim().toLowerCase() === 'due')
  const recent = list.filter(s => isTerminalStatus(s.status)).slice(0, 6)
  const needTotal = pending.length + due.length

  return html`
    <aside class="ov-aside" data-testid="schedule-aside">
      <section class="wka-sec">
        <div class="wka-h">지금 상황 <span class="n mono">${sum.total} 예약</span></div>
        <div class="wka-pulse">
          <span class="wka-pulse-i"><b class="mono">${sum.scheduled}</b> 예약됨</span>
          <span class="wka-pulse-i"><b class=${`mono ${sum.dueRunning ? 'volt' : ''}`}>${sum.dueRunning}</b> due·실행</span>
          <span class="wka-pulse-i"><b class=${`mono ${sum.pending ? 'warn' : ''}`}>${sum.pending}</b> 승인대기</span>
        </div>
        ${failed.length === 0
          ? html`<div class="wka-calm mono">실패한 실행 없음</div>`
          : html`
              <div class="wka-list">
                ${failed.map(s => html`
                  <button key=${s.schedule_id} class="wka-flag st-bad" onClick=${() => onOpen(s.schedule_id)}>
                    <span class="wka-flag-tag bad">실패</span>
                    <span class="wka-flag-title">${s.payload_summary ?? '작업'}</span>
                    ${s.last_execution?.error ? html`<span class="wka-flag-reason">${s.last_execution.error}</span>` : null}
                  </button>
                `)}
              </div>
            `}
      </section>

      <section class="wka-sec">
        <div class="wka-h">해야 할 일 <span class="n mono">${needTotal}</span></div>
        <div class="wka-list">
          ${pending.map(s => html`
            <button key=${s.schedule_id} class="wka-todo approve" onClick=${() => onOpen(s.schedule_id)}>
              <span class="wka-todo-k">승인</span>
              <span class="wka-todo-t">${s.payload_summary ?? '작업'}</span>
              <span class="wka-todo-m mono">${schedRiskSpec(s.risk_class).lbl} · ${formatDateTimeKo(s.next_due_at_iso ?? s.due_at_iso)}</span>
            </button>
          `)}
          ${due.map(s => html`
            <button key=${s.schedule_id} class="wka-todo verify" onClick=${() => onOpen(s.schedule_id)}>
              <span class="wka-todo-k">due</span>
              <span class="wka-todo-t">${s.payload_summary ?? '작업'}</span>
              <span class="wka-todo-m mono">${schedRecurrenceText(s.recurrence)} · 실행 대기</span>
            </button>
          `)}
          ${needTotal === 0 ? html`<div class="wka-calm mono">승인·실행 대기 없음</div>` : null}
        </div>
      </section>

      <section class="wka-sec">
        <div class="wka-h">최근 실행 <span class="n mono">${recent.length}</span></div>
        <div class="wka-list">
          ${recent.length === 0
            ? html`<div class="wka-calm mono">종료된 예약 없음</div>`
            : recent.map(s => {
                const m = schedStatusSpec(s.status)
                return html`
                  <button key=${s.schedule_id} class="wka-done" onClick=${() => onOpen(s.schedule_id)}>
                    <span class=${`wka-done-mark ${m.cls}`}>${m.glyph}</span>
                    <span class="wka-done-t">${s.payload_summary ?? '작업'}</span>
                    <span class="wka-done-ns mono">${m.lbl}</span>
                  </button>
                `
              })}
        </div>
      </section>
    </aside>
  `
}

// Keeper background tasks (simulated from waiting inventory & active signals)
function SchKeeperBg({
  signals,
  onOpenKeeper,
}: {
  signals: DashboardScheduledAutomationSignal[]
  onOpenKeeper: (id: string) => void
}) {
  const polls = signals.filter(s => (s.kind ?? '').includes('poll'))
  const asyncs = signals.filter(s => !(s.kind ?? '').includes('poll'))
  
  const renderRow = (b: DashboardScheduledAutomationSignal) => {
    const kId = 'masc-improver' // Fallback keeper
    const slot = kSlot(kId)
    const sigil = kSigil(kId)
    return html`
      <button key=${b.signal_id} class="sch-bg-row st-ok" onClick=${() => onOpenKeeper(kId)} title=${`${kId} 대화 열기`}>
        <span class="sch-bg-when mono">↻ 30s</span>
        <span class="sch-bg-body">
          <span class="sch-bg-title">${b.kind}</span>
          <span class="sch-bg-meta">
            <${SigilBadge} slot=${slot} sigil=${sigil} size=${16} />
            <span class="mono sch-bg-by">${kId}</span>
            <${SchRisk} risk=${b.risk_class ?? 'Read_only'} />
            <span class="sch-bg-since mono">since ${formatDateTimeKo(b.emitted_at_iso)}</span>
          </span>
        </span>
        <span class="sch-pill ok">▶ 도는 중</span>
      </button>
    `
  }

  return html`
    <section class="sch-bg">
      <div class="sch-bg-h">
        <h3>Keeper 자율 백그라운드</h3>
        <span class="sch-bg-sub">operator 승인 없이 keeper가 자기 turn에서 도는 폴링 · 비동기 도구 호출 — 예약 큐와 별개 origin</span>
      </div>
      <div class="sch-bg-grps">
        <div class="sch-bg-grp">
          <div class="sch-bg-grp-h"><span class="sch-cad volt">↻ 폴링 루프</span><span class="sch-bg-grp-n mono">${polls.length}</span></div>
          <div class="sch-bg-list">${polls.map(renderRow)}</div>
        </div>
        <div class="sch-bg-grp">
          <div class="sch-bg-grp-h"><span class="sch-cad info">⇢ 비동기 도구 호출</span><span class="sch-bg-grp-n mono">${asyncs.length}</span></div>
          <div class="sch-bg-list">${asyncs.map(renderRow)}</div>
        </div>
      </div>
    </section>
  `
}

function enumLabel(value: string | null | undefined): string {
  if (!value) return '-'
  return value.replace(/_/g, ' ')
}

function formatDateTimeKo(iso: string | null | undefined): string {
  if (!iso) return '-'
  const date = new Date(iso)
  if (!Number.isFinite(date.getTime())) return iso
  return date.toLocaleString('ko-KR')
}

// --- Main Surface Component ---

export function ScheduleSurface() {
  const data = toolsData.value
  const automation = data?.scheduled_automation ?? null
  const loading = toolsLoading.value
  const error = toolsError.value
  
  const [view, setView] = useState<'calendar' | 'list'>('calendar')
  const [cadFilter, setCadFilter] = useState<string | null>(null)
  const [tab, setTab] = useState<string>('pending')
  const [selectedScheduleId, setSelectedScheduleId] = useState<string | null>(null)
  const [banner, setBanner] = useState<{ id: string; action: string; lbl: string; toTab: string; tabLbl: string } | null>(null)
  const [pruning, setPruning] = useState(false)

  const list = useMemo(() => automation?.requests ?? [], [automation])
  
  const act = async (id: string, action: DashboardScheduleDecision, reason?: string) => {
    try {
      await resolveScheduleApproval(id, action, reason)
      showToast(`${id}이(가) ${action === 'approve' ? '승인' : '거부'}되었습니다.`, 'success')
      
      const map = { 
        approve: { lbl: '예약됨', toTab: 'scheduled', tabLbl: '예약됨' }, 
        reject: { lbl: '거부됨', toTab: 'done', tabLbl: '완료·종료' }
      }
      const m = map[action]
      if (m) {
        setBanner({ id, action, ...m })
        clearTimeout((window as any).__schBannerT)
        ;(window as any).__schBannerT = setTimeout(() => setBanner(null), 7000)
      }
      await loadTools()
    } catch (err: any) {
      console.error('[ScheduleSurface] action failed:', err)
      showToast(err.message || String(err), 'error')
    }
  }

  const handlePrune = async () => {
    if (!window.confirm('완료되었거나 취소/만료/반려된 예약을 정말로 정리하시겠습니까?\n연관된 실행 기록 및 권한 승인도 함께 삭제됩니다.')) {
      return
    }
    setPruning(true)
    try {
      const res = await pruneSchedules()
      showToast(`성공적으로 ${res.pruned_count}개의 완료된 예약을 정리했습니다.`, 'success')
      await loadTools()
    } catch (err: any) {
      console.error('[ScheduleSurface] prune failed:', err)
      showToast(err.message || String(err), 'error')
    } finally {
      setPruning(false)
    }
  }

  useEffect(() => {
    if (!toolsData.value && !toolsLoading.value) {
      void loadTools()
    }
  }, [])

  const pendingCount = countByStatus(list, ['pending_approval', 'awaiting_approval'])
  const scheduledCount = countByStatus(list, ['scheduled'])
  const dueCount = countByStatus(list, ['due'])
  const runningCount = countByStatus(list, ['running'])
  const dueRunning = dueCount + runningCount
  const totalCount = list.length
  
  const sum = {
    pending: pendingCount,
    scheduled: scheduledCount,
    dueRunning,
    total: totalCount,
  }

  const tabDef = SCH_TABS.find(t => t[0] === tab) || SCH_TABS[0]
  let filtered = tabDef && tabDef[2] 
    ? list.filter(s => tabDef[2]!.includes((s.status ?? '').trim().toLowerCase())) 
    : list
    
  if (cadFilter) {
    filtered = filtered.filter(s => schedCadence(s) === cadFilter)
  }
  
  const detailLive = selectedScheduleId 
    ? list.find(s => s.schedule_id === selectedScheduleId) ?? null 
    : null

  const handleOpenKeeper = (id: string) => {
    selectedAgentName.value = id
  }

  if (loading && !automation) {
    return html`<${LoadingState}>예약 자동화 projection 불러오는 중...<//>`
  }

  return html`
    <main class="ov ov-flush ov-2col sch-surf" data-screen-label="예약" data-testid="schedule-surface">
      <div class="ov-scroll">
        <header class="ov-head" style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <div>
            <span class="ov-eyebrow">Schedule</span>
            <h1>예약 · 자동화 큐</h1>
            <p class="ov-sub">keeper가 예약한 미래 작업 · operator가 due 전 승인 · <span class="mono">lib/schedule</span></p>
            <div class="mt-2 flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]" data-testid="schedule-reality-notice">
              <span class="sch-pill warn">관측 전용</span>
              <span>schedule runner projection을 읽어 표시하며, 이 화면에서 keeper turn을 자동 구동하지 않습니다.</span>
            </div>
          </div>
          <div style=${{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: '8px' }}>
            <${ConnectionStatus} />
            <${ActionButton}
              variant="danger"
              size="sm"
              onClick=${handlePrune}
              disabled=${pruning}
              testId="schedule-prune-btn"
            >
              ${pruning ? '정리 중...' : '완료된 예약 정리 (Prune)'}
            <//>
          </div>
        </header>

        ${error ? html`<${ErrorState} message=${error} class="mb-4" />` : null}

        <section class="ov-kpis" style=${{ gridTemplateColumns: 'repeat(4, 1fr)' }} aria-label="예약 요약">
          <div class="ov-kpi">
            <div class="ov-kpi-k">승인 대기</div>
            <div class=${`ov-kpi-v ${sum.pending ? 'warn' : 'ok'}`}>${sum.pending}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">예약됨</div>
            <div class="ov-kpi-v">${sum.scheduled}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">due · 실행</div>
            <div class=${`ov-kpi-v ${sum.dueRunning ? 'warn' : ''}`}>${sum.dueRunning}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">총 예약</div>
            <div class="ov-kpi-v volt">${sum.total}</div>
          </div>
        </section>

        <div class="sch-viewbar">
          <div class="sch-viewseg">
            <button class=${`sch-viewbtn ${view === 'calendar' ? 'on' : ''}`} onClick=${() => setView('calendar')}>▧ 캘린더</button>
            <button class=${`sch-viewbtn ${view === 'list' ? 'on' : ''}`} onClick=${() => setView('list')}>≡ 목록</button>
          </div>
          <${SchCadenceSummary} list=${list} filter=${cadFilter} onFilter=${setCadFilter} />
        </div>

        ${banner
          ? html`
              <div class=${`sch-banner ${banner.action}`}>
                <span class="sch-banner-ico">${banner.action === 'approve' ? '✓' : '✕'}</span>
                <span class="sch-banner-txt"><b class="mono">${banner.id}</b> ${banner.lbl}${banner.action === 'approve' ? ' · grant 발급 — due 시각에 runner가 실행' : ''}</span>
                ${banner.toTab ? html`<button class="sch-banner-go" onClick=${() => { setView('list'); setTab(banner.toTab); setBanner(null); }}>${banner.tabLbl} 탭 보기 →</button>` : null}
                <button class="sch-banner-x" onClick=${() => setBanner(null)} title="닫기">✕</button>
              </div>
            `
          : null}

        ${view === 'calendar'
          ? html`
              ${cadFilter !== 'daily' && cadFilter !== 'oneshot' ? html`<${SchPollingStrip} list=${list} onOpen=${setSelectedScheduleId} />` : null}
              ${cadFilter !== 'interval' ? html`<${SchAgenda} list=${list} filter=${cadFilter} onOpen=${setSelectedScheduleId} />` : null}
              <${SchKeeperBg} signals=${automation?.signals ?? []} onOpenKeeper=${handleOpenKeeper} />
            `
          : html`
              <div class="sch-tabs">
                ${SCH_TABS.map(([id, lbl, statuses]) => {
                  const n = statuses 
                    ? list.filter(s => statuses.includes((s.status ?? '').trim().toLowerCase())).length 
                    : list.length
                  return html`
                    <button key=${id} class=${`sch-tab ${tab === id ? 'on' : ''}`} onClick=${() => setTab(id)}>
                      ${lbl}<span class="sch-tab-n mono">${n}</span>
                    </button>
                  `
                })}
              </div>
              ${filtered.length === 0
                ? html`<div class="sch-empty">이 필터에 해당하는 예약이 없습니다.</div>`
                : html`
                    <div class="sch-list">
                      ${filtered.map(s => html`
                        <${SchCard}
                          key=${s.schedule_id}
                          s=${s}
                          onOpen=${setSelectedScheduleId}
                          onAct=${act}
                          onOpenKeeper=${handleOpenKeeper}
                        />
                      `)}
                    </div>
                  `}
            `}

        <section class="sch-signals">
          <div class="ov-card-h"><h3>wake signal 피드 · schedule_runner.tick</h3></div>
          <div class="sch-sig-list">
            ${(automation?.signals ?? []).map(sig => html`
              <div key=${sig.signal_id} class="sch-sig">
                <span class="sch-sig-at mono">${formatDateTimeKo(sig.emitted_at_iso)}</span>
                <span class="sch-sig-kind ok">${sig.kind}</span>
                <button class="sch-sig-id mono" onClick=${() => { setSelectedScheduleId(sig.schedule_id) }}>${sig.schedule_id}</button>
                <span class="sch-sig-risk mono">${sig.risk_class ?? 'Read_only'}</span>
              </div>
            `)}
          </div>
        </section>
      </div>
      <${SchAside} list=${list} sum=${sum} onOpen=${setSelectedScheduleId} />
      ${detailLive
        ? html`
            <${SchDetail}
              s=${detailLive}
              onClose=${() => setSelectedScheduleId(null)}
              onAct=${act}
              onOpenKeeper=${handleOpenKeeper}
            />
          `
        : null}
    </main>
  `
}
