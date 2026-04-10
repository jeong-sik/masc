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

  it('filters pending confirmations by global, mine, and actor scopes', () => {
    const items = [
      { confirm_token: 'a', actor: 'dashboard-a' },
      { confirm_token: 'b', actor: 'dashboard-b' },
      { confirm_token: 'c', actor: 'dashboard-a' },
    ]

    expect(
      helpers.filterPendingConfirmations(items, 'dashboard-a', { kind: 'all' }).map(item => item.confirm_token),
    ).toEqual(['a', 'b', 'c'])
    expect(
      helpers.filterPendingConfirmations(items, 'dashboard-a', { kind: 'mine' }).map(item => item.confirm_token),
    ).toEqual(['a', 'c'])
    expect(
      helpers.filterPendingConfirmations(items, 'dashboard-a', { kind: 'actor', actor: 'dashboard-b' }).map(item => item.confirm_token),
    ).toEqual(['b'])
  })

  it('only allows the owning actor to confirm a pending action', () => {
    expect(
      helpers.canManagePendingConfirmation({ confirm_token: 'a', actor: 'dashboard-a' }, 'dashboard-a'),
    ).toBe(true)
    expect(
      helpers.canManagePendingConfirmation({ confirm_token: 'b', actor: 'dashboard-b' }, 'dashboard-a'),
    ).toBe(false)
  })
})
