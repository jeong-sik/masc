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
      <div class="flex flex-col gap-1.5">
        <div class="flex items-baseline gap-2 text-[13px]">
          <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">State</span>
          <${StatusBadge} status=${worker.state} />
        </div>
        ${worker.focus ? html`
          <div class="flex items-baseline gap-2 text-[13px]">
            <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">Focus</span>
            <span>${worker.focus}</span>
          </div>
        ` : null}
        ${worker.recent_output_preview ? html`
          <div class="flex items-baseline gap-2 text-[13px]">
            <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">Output</span>
            <span class="agent-worker-brief__preview">${compactCopy(worker.recent_output_preview, 200)}</span>
          </div>
        ` : null}
        ${worker.related_session_id ? html`
          <div class="flex items-baseline gap-2 text-[13px]">
            <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">Session</span>
            <span class="font-mono" style="font-size: 11px">${worker.related_session_id}</span>
          </div>
        ` : null}
        ${worker.last_signal_at ? html`
          <div class="flex items-baseline gap-2 text-[13px]">
            <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">Signal</span>
            <${TimeAgo} timestamp=${worker.last_signal_at} />
            ${worker.signal_truth ? html`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">${worker.signal_truth}</span>` : null}
          </div>
        ` : null}
      </div>
    <//>
  `
}
