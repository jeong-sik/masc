// Agent detail worker brief — execution worker status panel

import { html } from 'htm/preact'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { CopyIdButton } from './common/copy-id-button'
import { workerBriefForAgent } from './agent-detail-state'
import { trimText } from '../lib/truncate'

function DetailLabel({ children }: { children: unknown }) {
  return html`<span class="text-2xs text-[var(--color-fg-muted)] min-w-15 shrink-0">${children}</span>`
}

function WorkerInfoRow({ children }: { children: unknown }) {
  return html`<div class="flex items-baseline gap-2 text-sm">${children}</div>`
}

export function AgentWorkerBrief({ agentName }: { agentName: string }) {
  const worker = workerBriefForAgent(agentName)
  if (!worker) return null

  return html`
    <${Card} title="워커 상태">
      <div class="flex flex-col gap-1.5">
        <${WorkerInfoRow}>
          <${DetailLabel}>상태</${DetailLabel}>
          <${StatusBadge} status=${worker.state} />
        </${WorkerInfoRow}>
        ${worker.focus ? html`
          <${WorkerInfoRow}>
            <${DetailLabel}>포커스</${DetailLabel}>
            <span>${worker.focus}</span>
          </${WorkerInfoRow}>
        ` : null}
        ${worker.recent_output_preview ? html`
          <${WorkerInfoRow}>
            <${DetailLabel}>출력</${DetailLabel}>
            <span class="agent-worker-brief__preview">${trimText(worker.recent_output_preview, 200)}</span>
          </${WorkerInfoRow}>
        ` : null}
        ${worker.related_session_id ? html`
          <${WorkerInfoRow}>
            <${DetailLabel}>세션</${DetailLabel}>
            <span class="font-mono truncate" style="font-size: 11px" title=${worker.related_session_id}>${worker.related_session_id}</span>
            <${CopyIdButton} value=${worker.related_session_id} label="session_id" size=${10} />
          </${WorkerInfoRow}>
        ` : null}
        ${worker.last_signal_at ? html`
          <${WorkerInfoRow}>
            <${DetailLabel}>시그널</${DetailLabel}>
            <${TimeAgo} timestamp=${worker.last_signal_at} />
            ${worker.signal_truth ? html`<span class="text-3xs py-0.5 px-2 border border-solid border-[var(--accent-36)] bg-[var(--accent-12)] text-[var(--color-accent-fg)] whitespace-nowrap rounded-sm">${worker.signal_truth}</span>` : null}
          </${WorkerInfoRow}>
        ` : null}
      </div>
    <//>
  `
}
