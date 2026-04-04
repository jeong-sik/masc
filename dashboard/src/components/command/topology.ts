import { html } from 'htm/preact'
import { JsonViewerCard } from '../common/json-viewer'
import { StatusChip } from '../common/status-chip'
import type { CommandPlaneTraceEvent } from '../../types'
import { relativeTime } from './helpers'

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
      <${JsonViewerCard} data=${event.detail} title="Event Detail" />
    </article>
  `
}
