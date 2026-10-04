import { html } from 'htm/preact'
import type { LaneAddonInstance, LaneAddonReading, LaneAddonRow } from '../api/lane-addons'
import { isRecord } from './common/normalize'

type ReadingValue =
  | { kind: 'value'; text: string }
  | { kind: 'unavailable'; reason: 'missing' | 'not_object' | 'wrong_type' }

function readingValue(reading: LaneAddonReading, fields: LaneAddonRow['fields']): ReadingValue {
  let value: unknown = fields
  for (const key of reading.path) {
    if (!isRecord(value)) return { kind: 'unavailable', reason: 'not_object' }
    if (!Object.prototype.hasOwnProperty.call(value, key)) return { kind: 'unavailable', reason: 'missing' }
    value = value[key]
  }
  switch (reading.format) {
    case 'text':
      if (typeof value === 'string') return { kind: 'value', text: value }
      break
    case 'number':
      if (typeof value === 'number' && Number.isFinite(value)) return { kind: 'value', text: String(value) }
      break
    case 'boolean':
      if (typeof value === 'boolean') return { kind: 'value', text: String(value) }
      break
    case 'json': {
      const text = JSON.stringify(value)
      if (text !== undefined) return { kind: 'value', text }
      break
    }
  }
  return { kind: 'unavailable', reason: 'wrong_type' }
}

const unavailableReason = {
  missing: 'field unavailable',
  not_object: 'field path does not address an object',
  wrong_type: 'field does not match declared display format',
} as const

/** Package-local Lane IDs are resolved only within the declaring instance.
 * Metadata describes readings; it never enables a package action. */
export function LaneAddonReadings({ row, instances }: {
  row: LaneAddonRow; instances: readonly LaneAddonInstance[];
}) {
  const readings = instances.flatMap(instance => instance.package.presentation.readings
    .filter(reading => row.lane_id === `${instance.instance_id}/${reading.lane_id}`))
  if (readings.length === 0) return null
  return html`<dl class="space-y-2" aria-label=${`Package readings for ${row.id}`}>
    ${readings.map(reading => {
      const value = readingValue(reading, row.fields)
      return html`<div key=${JSON.stringify([reading.lane_id, reading.path])}>
        <dt class="font-medium">${reading.label}</dt>
        <dd class="whitespace-pre-wrap break-all">${value.kind === 'value'
          ? html`${value.text}${reading.unit === null ? '' : ` ${reading.unit}`}`
          : html`Unavailable · ${unavailableReason[value.reason]}`}</dd>
      </div>`
    })}
  </dl>`
}
