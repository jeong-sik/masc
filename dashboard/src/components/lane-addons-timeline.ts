import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import type { LaneAddonRow, LaneAddonInstance } from '../api/lane-addons'

export function formatLaneTime(value: number) {
  const date = new Date(value * 1000)
  return Number.isNaN(date.getTime()) ? `${value} Unix seconds` : date.toISOString()
}

function laneLabel(lane: string) {
  const separator = lane.indexOf('/')
  if (separator < 1) {
    const label = Array.from(lane)
    return label.length > 34 ? label.slice(0, 33).join('') + '…' : lane
  }
  const instance = lane.slice(0, separator)
  const local = Array.from(lane.slice(separator + 1))
  // UUIDv7's timestamp prefix can be shared by concurrent installations.
  const shortInstance = instance.slice(-8)
  const available = 34 - shortInstance.length - 3
  const label = local.length > available ? local.slice(0, available - 1).join('') + '…' : local.join('')
  return `${label} · ${shortInstance}`
}

/** Coordinates only: time proximity and connecting lines do not assert cause. */
export function LaneAddonsTimeline({ rows, instances = [], selectedId, onSelect, onWindow }: {
  rows: LaneAddonRow[]
  instances?: readonly LaneAddonInstance[]
  selectedId?: string
  onSelect?: (row: LaneAddonRow) => void
  onWindow: (since: number, until: number) => void
}) {
  const start = useRef<{ pointerId: number; time: number; rows: LaneAddonRow[] } | null>(null)
  const first = rows[0]
  const declared = instances.flatMap(instance => {
    const explicit = Object.values(instance.package.outputs).flatMap(output => output.all_lanes ? [] : output.lanes)
    const observed = rows.filter(row => row.lane_id.startsWith(`${instance.instance_id}/`)).map(row => row.lane_id)
    return [...explicit.map(lane => `${instance.instance_id}/${lane}`), ...observed,
      ...(explicit.length === 0 && observed.length === 0 ? [instance.instance_id] : [])]
  })
  const lanes = [...new Set([...declared, ...rows.map(row => row.lane_id)])].sort()
  if (lanes.length === 0) return html`<p>No Lane instances or retained observations.</p>`
  const owner = (lane: string) => instances.find(instance => lane === instance.instance_id || lane.startsWith(`${instance.instance_id}/`))
  const lower = rows.reduce((value, row) => Math.min(value, row.observed_at), (first?.observed_at ?? 0))
  const upper = rows.reduce((value, row) => Math.max(value, row.observed_at), (first?.observed_at ?? 0))
  const width = 960, labelWidth = 260, plotWidth = width - labelWidth - 20
  const laneIndex = new Map(lanes.map((lane, index) => [lane, index]))
  const y = (lane: string) => 32 + (laneIndex.get(lane) ?? 0) * 58
  const fraction = (time: number) => {
    if (upper === lower) return 0.5
    const span = upper - lower
    return Number.isFinite(span) ? (time - lower) / span : (time / 2 - lower / 2) / (upper / 2 - lower / 2)
  }
  const x = (time: number) => labelWidth + fraction(time) * plotWidth
  const eventTime = (event: PointerEvent) => {
    const element = event.currentTarget as SVGSVGElement
    const bounds = element.getBoundingClientRect()
    if (bounds.width <= 0) return lower
    const coordinate = (event.clientX - bounds.left) / bounds.width * width
    const part = Math.max(0, Math.min(1, (coordinate - labelWidth) / plotWidth))
    return (1 - part) * lower + part * upper
  }
  const byId = new Map(rows.map(row => [row.id, row]))
  return html`<figure class="border border-[var(--border)] rounded p-3 overflow-x-auto" aria-label="Lane by time">
    <figcaption>Lane × wall time · Select an event to inspect its evidence. Drag empty plot space to set a slice window.</figcaption>
    <p class="text-sm">Each row is a declared or observed Lane. Dotted links are recorded relationships; spacing does not imply causation.</p>
    <p class="text-sm">${first ? `${formatLaneTime(lower)} → ${formatLaneTime(upper)}` : 'No observations in this view'}</p>
    <svg viewBox=${`0 0 ${width} ${lanes.length * 58 + 25}`} class="w-full min-w-[640px] touch-none"
      role="group" aria-label="Parallel lanes with events and recorded relationships"
      onPointerDown=${(event: PointerEvent) => {
        if (!first || event.button !== 0 || event.isPrimary === false || start.current) return
        const element = event.currentTarget as SVGSVGElement
        const bounds = element.getBoundingClientRect()
        if (bounds.width <= 0 || (event.clientX - bounds.left) / bounds.width * width < labelWidth) return
        start.current = { pointerId: event.pointerId, time: eventTime(event), rows }
        element.setPointerCapture?.(event.pointerId)
      }}
      onPointerUp=${(event: PointerEvent) => {
        const gesture = start.current
        if (!gesture || gesture.pointerId !== event.pointerId) return
        start.current = null
        const element = event.currentTarget as SVGSVGElement
        if (element.hasPointerCapture?.(event.pointerId)) element.releasePointerCapture(event.pointerId)
        if (gesture.rows !== rows) return
        const end = eventTime(event)
        if (gesture.time !== end) onWindow(Math.min(gesture.time, end), Math.max(gesture.time, end))
      }} onPointerCancel=${() => { start.current = null }}
      onLostPointerCapture=${() => { start.current = null }}>
      ${lanes.map(lane => html`<g key=${lane}>
        <text x="0" y=${y(lane) + 4} fill="currentColor" font-size="12" aria-label=${lane}><title>${lane}</title>${laneLabel(lane)}</text>
        <text x="0" y=${y(lane) + 20} fill="currentColor" font-size="11" opacity="0.75"><title>${owner(lane) ? `${owner(lane)!.title} · run ${owner(lane)!.run_id} · ${owner(lane)!.instance_id}` : `Lane ${lane}`}</title>${owner(lane) ? `${owner(lane)!.title} · ${owner(lane)!.phase.kind}` : 'Retained observation'}</text>
        <line x1=${labelWidth} x2=${width - 20} y1=${y(lane)} y2=${y(lane)} stroke="currentColor" opacity="0.25" />
        ${!rows.some(row => row.lane_id === lane) && html`<text x=${labelWidth + 12} y=${y(lane) - 6} fill="currentColor" font-size="12">No observations in this view</text>`}
      </g>`)}
      ${rows.filter(row => row.kind === 'relation').flatMap(row => row.related_ids.map(id => {
        const related = byId.get(id)
        return related ? html`<line key=${`${row.id}:${id}`} x1=${x(row.observed_at)} y1=${y(row.lane_id)}
          x2=${x(related.observed_at)} y2=${y(related.lane_id)} stroke="#d99c56" stroke-dasharray="3 3" opacity="0.55">
          <title>${row.title}</title></line>` : null
      }))}
      ${rows.map(row => html`<circle key=${row.id} cx=${x(row.observed_at)} cy=${y(row.lane_id)}
        role=${onSelect ? 'button' : undefined} tabindex=${onSelect ? 0 : undefined}
        aria-label=${`Inspect ${row.title} · ${row.id}`} aria-pressed=${onSelect ? selectedId === row.id : undefined}
        style=${onSelect ? 'cursor:pointer' : undefined}
        onPointerDown=${(event: PointerEvent) => event.stopPropagation()}
        onClick=${() => onSelect?.(row)}
        onKeyDown=${(event: KeyboardEvent) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); onSelect?.(row) } }}
        stroke=${selectedId === row.id ? 'currentColor' : 'transparent'} stroke-width="3"
        r=${selectedId === row.id ? 8 : 6} fill=${row.kind === 'relation' ? '#d99c56' : row.kind === 'value' ? '#70bca7' : '#89aee8'}>
        <title>${row.title} · ${formatLaneTime(row.observed_at)}${row.clock ? ` · ${row.clock.domain} ${row.clock.value}` : ''}</title>
      </circle>`)}
    </svg>
    ${onSelect && rows.length > 0 && html`<details><summary>Event list · ${rows.length} observations, including overlapping points</summary>
      <ul>${rows.map(row => html`<li key=${row.id}><button type="button" class="underline text-left" onClick=${() => onSelect(row)} aria-pressed=${selectedId === row.id}>Inspect event: ${row.title} · ${row.id}</button></li>`)}</ul>
    </details>`}
  </figure>`
}
