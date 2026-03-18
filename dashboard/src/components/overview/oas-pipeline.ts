// OAS Agent Pipeline — real-time lodge agent lifecycle and keeper snapshot monitor.
// Shows recent agent selection/decision/execution events from OAS Event_bus.

import { html } from 'htm/preact'
import { oasAgentEvents, oasKeeperSnapshots, oasHealthSummary } from '../../store'

function actionBadge(action: string | undefined): string {
  switch (action) {
    case 'post': return 'badge--post'
    case 'comment': return 'badge--comment'
    case 'upvote': return 'badge--upvote'
    case 'skip': return 'badge--skip'
    case 'passed': return 'badge--skip'
    case 'skipped': return 'badge--skip'
    default: return ''
  }
}

function formatTs(ts: number): string {
  const d = new Date(ts * 1000)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`
}

function OasAgentEventList() {
  const events = oasAgentEvents.value
  if (events.length === 0) {
    return html`<div class="oas-empty">OAS agent event 대기 중...</div>`
  }

  return html`
    <div class="oas-event-list">
      ${events.slice(0, 15).map((ev, i) => html`
        <div class="oas-event-row" key=${i}>
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

function OasKeeperSnapshotList() {
  const snapshots = oasKeeperSnapshots.value
  if (snapshots.size === 0) {
    return html`<div class="oas-empty">OAS keeper snapshot 대기 중...</div>`
  }

  const entries = [...snapshots.values()].sort((a, b) => b.timestamp - a.timestamp)

  return html`
    <div class="oas-keeper-list">
      ${entries.map(snap => {
        const pct = Math.round(snap.context_ratio * 100)
        const barClass = pct > 70 ? 'bar--warn' : pct > 50 ? 'bar--mid' : 'bar--ok'
        return html`
          <div class="oas-keeper-row" key=${snap.keeper_name}>
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

export function OasPipeline() {
  const health = oasHealthSummary.value

  return html`
    <div class="oas-pipeline">
      <div class="oas-pipeline__header">
        <span class="oas-pipeline__title">OAS Pipeline</span>
        <span class="oas-pipeline__count">${health.totalEvents} events</span>
      </div>

      <div class="oas-pipeline__section">
        <div class="oas-section-label">Agent Lifecycle</div>
        <${OasAgentEventList} />
      </div>

      <div class="oas-pipeline__section">
        <div class="oas-section-label">Keeper Context</div>
        <${OasKeeperSnapshotList} />
      </div>
    </div>
  `
}
