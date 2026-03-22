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

function OasSummaryLines() {
  const events = oasAgentEvents.value
  const snapshots = oasKeeperSnapshots.value
  const health = oasHealthSummary.value

  const activeAgents = new Set(events.map(ev => ev.agent_name))
  const firstEvent = events[0]
  const lastEventTs = firstEvent != null ? firstEvent.timestamp : null
  const agoMin = lastEventTs != null ? Math.round((Date.now() / 1000 - lastEventTs) / 60) : null

  return html`
    <div class="oas-summary-lines">
      <span>활성 에이전트 ${activeAgents.size}명</span>
      <span>${health.totalEvents}건${snapshots.size > 0 ? `, 키퍼 ${snapshots.size}명` : ''}</span>
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
            <span class="oas-keeper-name">${snap.keeper_name}</span>
            <span class="oas-keeper-gen">gen ${snap.generation}</span>
            <div class="oas-keeper-bar-wrap">
              <div class="oas-keeper-bar ${barClass}" style=${{ width: `${pct}%` }}></div>
            </div>
            <span class="oas-keeper-pct">${pct}%</span>
            <span class="oas-keeper-msgs">${snap.message_count} msgs</span>
          </div>
        `
      })}
    </div>
  `
}

function OasRawEventList() {
  const events = oasAgentEvents.value
  if (events.length === 0) {
    return html`<div class="oas-empty">OAS 에이전트 이벤트 대기 중...</div>`
  }

  return html`
    <div class="flex flex-col gap-0.5">
      ${events.slice(0, 15).map((ev, i) => html`
        <div class="oas-event-row rounded" key=${i}>
          <span class="oas-event-ts">${formatTs(ev.timestamp)}</span>
          <span class="oas-event-agent">${ev.agent_name}</span>
          <span class="oas-event-type">${ev.type}</span>
          ${ev.action ? html`<span class="oas-event-badge ${actionBadge(ev.action)}">${ev.action}</span>` : null}
          ${ev.trigger ? html`<span class="oas-event-trigger">${ev.trigger}</span>` : null}
          ${ev.success != null ? html`<span class="oas-event-ok ${ev.success ? 'ok' : 'fail'}">${ev.success ? 'ok' : 'fail'}</span>` : null}
        </div>
      `)}
    </div>
  `
}

export function OasPipeline() {
  const health = oasHealthSummary.value
  const eventLabel = `${health.totalEvents}건`

  return html`
    <div class="oas-pipeline rounded-lg">
      <div class="flex justify-between items-center mb-3">
        <span class="oas-pipeline__title">실행 흐름</span>
        <div class="home-section-actions">
          <span class="oas-pipeline__count">${eventLabel}</span>
        </div>
      </div>

      <${OasSummaryLines} />

      <div class="mb-2.5">
        <div class="oas-section-label">키퍼 컨텍스트</div>
        <${OasKeeperBars} />
      </div>

      <details class="oas-pipeline__raw-toggle">
        <summary>에이전트 실행 (raw events)</summary>
        <${OasRawEventList} />
      </details>
    </div>
  `
}
