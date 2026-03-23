import { html } from 'htm/preact'
import { StatusChip } from '../common/status-chip'
import type { CommandPlaneTraceEvent } from '../../types'
import { prettyJson, relativeTime } from './helpers'

export function TraceRow({ event }: { event: CommandPlaneTraceEvent }) {
  return html`
    <article class="grid grid-cols-[minmax(0,1fr)_minmax(220px,0.9fr)] gap-4">
      <div class="min-w-0 [overflow-wrap:anywhere] break-words">
        <div class="flex justify-between items-start">
          <strong>${event.event_type}</strong>
          <${StatusChip} label=${event.source ?? 'control_plane'} />
          <${StatusChip} label=${relativeTime(event.timestamp)} />
        </div>
        <div class="cmd-card rounded-xl-sub">
          ${event.operation_id ?? event.trace_id}
          ${event.unit_id ? ` · ${event.unit_id}` : ''}
          ${event.actor ? ` · ${event.actor}` : ''}
        </div>
      </div>
      <pre class="m-0 p-3 rounded-[10px] bg-[rgba(9,12,20,0.75)] text-[rgba(224,242,254,0.92)] text-[13px] leading-[1.45] max-h-[220px] overflow-auto whitespace-pre-wrap break-words [overflow-wrap:anywhere]">${prettyJson(event.detail)}</pre>
    </article>
  `
}
