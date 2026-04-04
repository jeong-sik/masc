import { html } from 'htm/preact'
import { Markdown } from "../common/markdown"
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
      <div class=\"max-h-[300px] overflow-auto rounded-xl border border-[var(--white-6)] bg-[var(--bg-0)]\"><${Markdown} text=${'```json\n' + JSON.stringify(event.detail, null, 2) + '\n```'} /></div>
    </article>
  `
}
