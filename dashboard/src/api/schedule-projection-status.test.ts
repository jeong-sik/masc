import { describe, expect, it } from 'vitest'
import serverStatuses from './fixtures/schedule-projection-statuses.json'
import {
  SCHEDULE_QUEUE_PROJECTION_STATUSES,
  SCHEDULE_REACTION_PROJECTION_STATUSES,
} from './schedule-projection-status'

describe('schedule projection status vocabularies', () => {
  it('queue statuses match the server contract, in order', () => {
    expect([...SCHEDULE_QUEUE_PROJECTION_STATUSES]).toEqual(serverStatuses.queue_projection_statuses)
  })

  it('reaction statuses match the server contract, in order', () => {
    expect([...SCHEDULE_REACTION_PROJECTION_STATUSES]).toEqual(
      serverStatuses.reaction_projection_statuses,
    )
  })
})
