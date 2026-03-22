// OAS Agent Pipeline — summary view with expandable raw events.
// Shows 3-line summary + keeper context bars. Raw events behind <details> toggle.

import { html } from 'htm/preact'
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
        ev.old_score != null && ev.new_score != null ? `${ev.old_score.toFixed(2)} → ${ev.new_score.toFixed(2)}` : null,
        ev.trend ?? null,
      ].filter(Boolean).join(' · ')
    default:
      return ''
  }
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
    <div class="flex gap-3 text-[length:var(--fs-xs)] text-[color:var(--text-muted,#888)] mb-2.5">
      <span>활성 에이전트 ${activeAgents.size}명</span>
      <span>${health.totalEvents}건${snapshots.size > 0 ? ` · 키퍼 ${snapshots.size}명` : ''}</span>
      <span>${agoMin != null ? `${agoMin}분 전` : '이벤트 대기 중'}</span>
    </div>
  `
}

function OasKeeperBars() {
  const snapshots = oasKeeperSnapshots.value
  if (snapshots.size === 0) return null

  const entries = [...snapshots.values()].sort((a, b) => b.timestamp - a.timestamp)

  return html`
    <div class="flex flex-col gap-1">
      ${entries.map(snap => {
        const pct = Math.round(snap.context_ratio * 100)
        const barClass = pct > 70 ? 'bar--warn' : pct > 50 ? 'bar--mid' : 'bar--ok'
        return html`
          <div class="oas-keeper-row rounded" key=${snap.keeper_name}>
            <span class="text-[color:var(--text-strong,var(--text-near-white))] font-medium min-w-[80px] max-w-[120px] overflow-hidden text-ellipsis whitespace-nowrap">${snap.keeper_name}</span>
            <span class="text-[color:var(--text-muted,#666)] text-[length:var(--fs-2xs)] min-w-[40px]">gen ${snap.generation}</span>
            <div class="oas-keeper-bar-wrap">
              <div class="oas-keeper-bar ${barClass}" style=${{ width: `${pct}%` }}></div>
            </div>
            <span class="text-[color:var(--text-muted,#888)] tabular-nums min-w-[32px] text-right">${pct}%</span>
            <span class="text-[color:var(--text-muted,#666)] text-[length:var(--fs-2xs)] min-w-[48px]">${snap.message_count} msgs</span>
          </div>
        `
      })}
    </div>
  `
}

function OasRawEventList() {
  const events = oasAgentEvents.value
  if (events.length === 0) {
    return html`<div class="text-[length:var(--fs-xs)] text-[color:var(--text-muted,#666)] py-2">OAS 에이전트 이벤트 대기 중...</div>`
  }

  return html`
    <div class="flex flex-col gap-0.5">
      ${events.slice(0, 15).map((ev, i) => html`
        <div class="oas-event-row rounded" key=${i}>
          <span class="text-[color:var(--text-muted,#666)] tabular-nums min-w-[56px]">${formatTs(ev.timestamp)}</span>
          <span class="text-[color:var(--text-strong,var(--text-near-white))] font-medium min-w-[80px] max-w-[120px] overflow-hidden text-ellipsis whitespace-nowrap">${ev.agent_name}</span>
          <span class="text-[color:var(--text-muted,#888)] min-w-[60px]">${eventTypeLabel(ev.type)}</span>
          ${ev.action ? html`<span class="oas-event-badge ${actionBadge(ev.action)}">${ev.action}</span>` : null}
          ${ev.trigger ? html`<span class="oas-event-trigger">${ev.trigger}</span>` : null}
          ${ev.success != null ? html`<span class="oas-event-ok ${ev.success ? 'ok' : 'fail'}">${ev.success ? 'ok' : 'fail'}</span>` : null}
          ${eventDetail(ev) ? html`<span class="oas-event-trigger">${eventDetail(ev)}</span>` : null}
        </div>
      `)}
    </div>
  `
}

export function OasPipeline() {
  const health = oasHealthSummary.value
  const eventLabel = `${health.totalEvents}건`

  return html`
    <div class="bg-[var(--card,#1a1f2e)] border border-[var(--card-border,#2a2f3e)] py-3 px-4 mt-3 rounded-lg">
      <div class="flex justify-between items-center mb-3">
        <span class="text-[length:var(--fs-base)] font-semibold text-[color:var(--text-strong,var(--text-near-white))] tracking-[0.5px]">실행 흐름</span>
        <div class="home-section-actions">
          <span class="text-[length:var(--fs-xs)] text-[color:var(--text-muted,#888)] tabular-nums">${eventLabel}</span>
        </div>
      </div>

      <${OasSummaryLines} />

      <div class="mb-2.5">
        <div class="text-[length:var(--fs-xs)] font-medium text-[color:var(--text-muted,#888)] uppercase tracking-[0.5px] mb-1.5">키퍼 컨텍스트</div>
        <${OasKeeperBars} />
      </div>

      <details class="oas-pipeline__raw-toggle">
        <summary>에이전트 실행 (raw events)</summary>
        <${OasRawEventList} />
      </details>
    </div>
  `
}
