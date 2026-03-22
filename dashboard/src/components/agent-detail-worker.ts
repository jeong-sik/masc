// Agent detail worker brief — execution worker status panel

import { html } from 'htm/preact'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { compactCopy, workerBriefForAgent } from './agent-detail-state'

export function AgentWorkerBrief({ agentName }: { agentName: string }) {
  const worker = workerBriefForAgent(agentName)
  if (!worker) return null

  return html`
    <${Card} title="Worker Status">
      <div class="agent-worker-brief">
        <div class="agent-worker-brief__row">
          <span class="agent-worker-brief__label">State</span>
          <${StatusBadge} status=${worker.state} />
        </div>
        ${worker.focus ? html`
          <div class="agent-worker-brief__row">
            <span class="agent-worker-brief__label">Focus</span>
            <span>${worker.focus}</span>
          </div>
        ` : null}
        ${worker.recent_output_preview ? html`
          <div class="agent-worker-brief__row">
            <span class="agent-worker-brief__label">Output</span>
            <span class="agent-worker-brief__preview">${compactCopy(worker.recent_output_preview, 200)}</span>
          </div>
        ` : null}
        ${worker.related_session_id ? html`
          <div class="agent-worker-brief__row">
            <span class="agent-worker-brief__label">Session</span>
            <span class="font-mono" style="font-size: 11px">${worker.related_session_id}</span>
          </div>
        ` : null}
        ${worker.last_signal_at ? html`
          <div class="agent-worker-brief__row">
            <span class="agent-worker-brief__label">Signal</span>
            <${TimeAgo} timestamp=${worker.last_signal_at} />
            ${worker.signal_truth ? html`<span class="pill">${worker.signal_truth}</span>` : null}
          </div>
        ` : null}
      </div>
    <//>
  `
}
