import { describe, expect, it } from 'vitest'
import * as helpers from './helpers'
import * as opsState from './ops-state'

describe('ops helper state exports', () => {
  it('re-exports the canonical ops state signals', () => {
    expect(helpers.actorName).toBe(opsState.actorName)
    expect(helpers.broadcastMessage).toBe(opsState.broadcastMessage)
    expect(helpers.pauseReason).toBe(opsState.pauseReason)
    expect(helpers.taskTitle).toBe(opsState.taskTitle)
    expect(helpers.taskDescription).toBe(opsState.taskDescription)
    expect(helpers.taskPriority).toBe(opsState.taskPriority)
    expect(helpers.selectedKeeperName).toBe(opsState.selectedKeeperName)
    expect(helpers.keeperMessage).toBe(opsState.keeperMessage)
    expect(helpers.hydratedWorkflowId).toBe(opsState.hydratedWorkflowId)
  })

  it('re-exports the canonical actor persistence function', () => {
    expect(helpers.persistActorName).toBe(opsState.persistActorName)
  })
})
