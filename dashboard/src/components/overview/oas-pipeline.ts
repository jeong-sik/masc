// OAS Agent Pipeline — summary view with expandable raw events.
// Shows 3-line summary + keeper context bars. Raw events behind <details> toggle.

import { html } from 'htm/preact'
import { SectionHeader } from '../common/section-header'
import { oasAgentEvents, oasKeeperSnapshots, oasHealthSummary } from '../../store'

function formatTs(ts: number): string {
  const d = new Date(ts * 1000)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`
}

function actionBadge(action: string | undefined): string {
  switch (action) {
    case 'post': return 'badge--post'
    case 'comment': return 'badge--comment'
    case 'upvote': return 'badge--upvote'
    case 'skip':
    case 'passed':
    case 'skipped': return 'badge--skip'
    default: return ''
  }
}

function eventTypeLabel(type: string): string {
  switch (type) {
    case 'selected': return 'selected'
    case 'decision': return 'decision'
    case 'action_executed': return 'executed'
    case 'keeper_resident_lifecycle': return 'resident'
    case 'trust_updated': return 'trust'
    case 'reputation_changed': return 'reputation'
    default: return type
  }
}

function eventDetail(ev: (typeof oasAgentEvents.value)[number]): string {
  switch (ev.type) {
    case 'selected':
      return ev.trigger ? `trigger ${ev.trigger}` : 'selection updated'
    case 'decision':
      return [ev.action, ev.trigger_reason].filter(Boolean).join(' · ') || 'decision updated'
    case 'action_executed':
      return [ev.action, ev.success != null ? (ev.success ? 'ok' : 'fail') : null].filter(Boolean).join(' · ')
    case 'keeper_resident_lifecycle':
      return [ev.event, ev.detail].filter(Boolean).join(' · ') || 'resident lifecycle'
    case 'trust_updated':
      return [ev.secondary_agent, ev.trust_score != null ? `score ${ev.trust_score.toFixed(2)}` : null].filter(Boolean).join(' · ')
    case 'reputation_changed':
      return [
        ev.old_score != null && ev.new_score != null ? `${ev.old_score.toFixed(2)} -> ${ev.new_score.toFixed(2)}` : null,
        ev.trend ?? null,
      ].filter(Boolean).join(' · ')
    default:
      return ''
  }
}

function barColor(pct: number): string {
  if (pct > 70) return 'bg-[var(--warn)]'
  if (pct > 50) return 'bg-[var(--accent)]'
  return 'bg-[var(--ok)]'
}

function OasSummaryLines() {
  const events = oasAgentEvents.value
  const snapshots = oasKeeperSnapshots.value
  const health = oasHealthSummary.value

  const activeAgents = new Set(events.map(ev => ev.agent_name))
  const firstEvent = events[0]
  const lastEventTs = firstEvent != null ? firstEvent.timestamp : null
  const agoMin = lastEventTs != null ? Math.round((Date.now() / 1000 - lastEventTs) / 60) : null

  return html`
    <div class="flex gap-4 text-xs text-[var(--text-muted)] mb-4">
      <span>에이전트 ${activeAgents.size}명</span>
      <span>${health.totalEvents}건${snapshots.size > 0 ? ` / 키퍼 ${snapshots.size}명` : ''}</span>
      <span>${agoMin != null ? `${agoMin}분 전` : '이벤트 대기 중'}</span>
    </div>
  `
}

function OasKeeperBars() {
  const snapshots = oasKeeperSnapshots.value
  if (snapshots.size === 0) return null

  const entries = [...snapshots.values()].sort((a, b) => b.timestamp - a.timestamp)

  return html`
    <div class="flex flex-col gap-2 mb-4">
      <${SectionHeader} class="mb-1">키퍼 컨텍스트<//>
      ${entries.map(snap => {
        const pct = Math.round(snap.context_ratio * 100)
        return html`
          <div class="flex items-center gap-3 text-xs" key=${snap.keeper_name}>
            <span class="text-[var(--text-strong)] font-medium w-20 truncate">${snap.keeper_name}</span>
            <span class="text-[var(--text-muted)] text-[10px] w-8">g${snap.generation}</span>
            <div class="flex-1 h-1.5 bg-[var(--white-6)] rounded-full overflow-hidden">
              <div class="h-full rounded-full transition-all ${barColor(pct)}" style=${{ width: `${pct}%` }}></div>
            </div>
            <span class="text-[var(--text-muted)] tabular-nums w-8 text-right">${pct}%</span>
            <span class="text-[var(--text-muted)] text-[10px] w-12">${snap.message_count} msg</span>
          </div>
        `
      })}
    </div>
  `
}

function OasRawEventList() {
  const events = oasAgentEvents.value
  if (events.length === 0) {
    return html`<div class="text-xs text-[var(--text-muted)] py-3 text-center">OAS 에이전트 이벤트 대기 중...</div>`
  }

  return html`
    <div class="flex flex-col gap-0.5">
      ${events.slice(0, 15).map((ev, i) => html`
        <div class="flex items-center gap-3 py-1 text-xs" key=${i}>
          <span class="text-[var(--text-muted)] tabular-nums w-14 shrink-0">${formatTs(ev.timestamp)}</span>
          <span class="text-[var(--text-strong)] font-medium w-20 truncate shrink-0">${ev.agent_name}</span>
          <span class="text-[var(--text-muted)] w-14 shrink-0">${eventTypeLabel(ev.type)}</span>
          ${ev.action ? html`<span class="oas-event-badge ${actionBadge(ev.action)}">${ev.action}</span>` : null}
          ${ev.trigger ? html`<span class="oas-event-trigger">${ev.trigger}</span>` : null}
          ${ev.success != null ? html`<span class="text-[10px] ${ev.success ? 'text-[var(--ok)]' : 'text-[var(--bad)]'}">${ev.success ? 'ok' : 'fail'}</span>` : null}
          ${eventDetail(ev) ? html`<span class="text-[var(--text-muted)] truncate">${eventDetail(ev)}</span>` : null}
        </div>
      `)}
    </div>
  `
}

export function OasPipeline() {
  const health = oasHealthSummary.value

  return html`
    <div class="p-4 rounded-lg border border-[var(--card-border)] bg-[var(--card)]">
      <div class="flex justify-between items-center mb-3">
        <span class="text-xs font-semibold text-[var(--text-strong)] uppercase tracking-wider">실행 흐름</span>
        <span class="text-[10px] text-[var(--text-muted)] tabular-nums">${health.totalEvents}건</span>
      </div>

      <${OasSummaryLines} />
      <${OasKeeperBars} />

      <details class="group">
        <summary class="cursor-pointer text-xs text-[var(--text-muted)] py-1 hover:text-[var(--accent)] transition-colors">에이전트 실행 (raw events)</summary>
        <div class="mt-2">
          <${OasRawEventList} />
        </div>
      </details>
    </div>
  `
}
