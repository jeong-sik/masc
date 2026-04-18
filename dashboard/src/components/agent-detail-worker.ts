// Agent detail worker brief — execution worker status panel

import { html } from 'htm/preact'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { CopyIdButton } from './common/copy-id-button'
import { workerBriefForAgent } from './agent-detail-state'
import { trimText } from '../lib/truncate'

export function AgentWorkerBrief({ agentName }: { agentName: string }) {
  const worker = workerBriefForAgent(agentName)
  if (!worker) return null

  return html`
    <${Card} title="워커 상태">
      <div class="flex flex-col gap-1.5">
        <div class="flex items-baseline gap-2 text-[13px]">
          <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">상태</span>
          <${StatusBadge} status=${worker.state} />
        </div>
        ${worker.focus ? html`
          <div class="flex items-baseline gap-2 text-[13px]">
            <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">포커스</span>
            <span>${worker.focus}</span>
          </div>
        ` : null}
        ${worker.recent_output_preview ? html`
          <div class="flex items-baseline gap-2 text-[13px]">
            <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">출력</span>
            <span class="agent-worker-brief__preview">${trimText(worker.recent_output_preview, 200)}</span>
          </div>
        ` : null}
        ${worker.related_session_id ? html`
          <div class="flex items-baseline gap-2 text-[13px]">
            <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">세션</span>
            <span class="font-mono truncate" style="font-size: 11px" title=${worker.related_session_id}>${worker.related_session_id}</span>
            <${CopyIdButton} value=${worker.related_session_id} label="session_id" size=${10} />
          </div>
        ` : null}
        ${worker.last_signal_at ? html`
          <div class="flex items-baseline gap-2 text-[13px]">
            <span class="text-[11px] text-[var(--text-muted)] min-w-[60px] shrink-0">시그널</span>
            <${TimeAgo} timestamp=${worker.last_signal_at} />
            ${worker.signal_truth ? html`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[var(--accent)] whitespace-nowrap rounded-sm">${worker.signal_truth}</span>` : null}
          </div>
        ` : null}
      </div>
    <//>
  `
}
