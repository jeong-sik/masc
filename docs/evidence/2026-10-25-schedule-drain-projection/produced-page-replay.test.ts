import { readFileSync } from 'node:fs'
import { html } from 'htm/preact'
import { render } from 'preact'
import { describe, it, expect } from 'vitest'
import { decodeScheduledAutomationLookup, normalizeScheduledAutomation } from '../../api/dashboard-scheduled-automation'
import { queueDrainStatusOf, countQueueDrainMisses } from './queue-drain-status'
import { ScheduledAutomationPanel } from '../tools/scheduled-automation-panel'

const cases = JSON.parse(readFileSync('../docs/evidence/2026-10-25-schedule-drain-projection/produced-pages.json', 'utf8'))
const expected = {
  'completed:committed': 'settling', 'completed:unprojected': 'settling',
  'completed:projected': 'drained', 'completed:retired': 'drained',
  'completed:unreadable_receipt': 'read_error',
  'failed:committed': 'settling', 'failed:unprojected': 'settling', 'failed:projected': 'failed',
  'cancelled:committed': 'settling', 'cancelled:unprojected': 'settling', 'cancelled:projected': 'cancelled',
  'transferred:committed': 'settling', 'transferred:unprojected': 'settling', 'transferred:projected': 'pending',
}

describe('actual backend run40179723721 page rows', () => {
  it.each(Object.entries(expected))('%s retains producer authority through the actual frontend', (key, state) => {
    const actual = cases[key].row
    const before = JSON.stringify(actual)
    const lookup = decodeScheduledAutomationLookup({
      schema: 'masc.dashboard.scheduled_automation.lookup.v1', source: 'schedule_store',
      generated_at: '2026-10-25T00:00:00Z', status: 'found', schedule_id: actual.schedule_id,
      request: actual, wakes: [], wake_count: 0, wake_retention_per_schedule: null,
    }, actual.schedule_id)
    expect(lookup.status).toBe('found')
    if (lookup.status !== 'found') throw new Error('Actual produced row was rejected')
    const row = lookup.request
    expect(row.keeper_queue_evidence?.post_id).toBe(actual.dispatch_receipt.post_id)
    expect(row.keeper_reaction_evidence?.stimulus_id).toBe(actual.dispatch_receipt.stimulus_id)
    expect(queueDrainStatusOf(row)?.state).toBe(state)
    expect(countQueueDrainMisses([row])).toBe(0)
    const active = ['scheduled', 'due', 'running'].includes(row.status)
    const projection = normalizeScheduledAutomation({
      schema: 'masc.dashboard.scheduled_automation.v1', source: 'schedule_store',
      generated_at: '2026-10-25T00:00:00Z', status: 'ok', schedule_store_known: true,
      schedule_store_read_error: null, request_count: 1, request_limit: 1, truncated: false,
      counts: { [row.status]: 1 }, fsm: { state: active ? 'active' : 'terminal', active_count: +active, terminal_count: +!active },
      requests: [actual], signals: [], warnings: [],
    })
    expect(projection.state).toBe('available')
    if (projection.state !== 'available') throw new Error('Fixture envelope rejected')
    const container = document.createElement('div')
    document.body.appendChild(container)
    try {
      render(html`<${ScheduledAutomationPanel} automation=${projection.data}/>`, container)
      expect(container.querySelector(`[data-schedule-keeper-queue-evidence="${row.keeper_queue_evidence?.projection_status}"]`)).not.toBeNull()
      expect(container.querySelector('[data-keeper-queue-evidence-row="post_id"]')?.textContent).toContain(actual.dispatch_receipt.post_id)
      expect(container.querySelector(`[data-schedule-keeper-reaction-evidence="${actual.keeper_reaction_evidence.projection_status}"]`)).not.toBeNull()
      if (row.keeper_queue_evidence?.transition_id) {
        expect(container.querySelector('[data-keeper-queue-evidence-row="transition_id"]')?.textContent).toContain(row.keeper_queue_evidence.transition_id)
      }
      expect(JSON.stringify(actual)).toBe(before)
    } finally { render(null, container); container.remove() }
  })
})
