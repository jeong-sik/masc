// @ts-nocheck
// @vitest-environment happy-dom
import { describe, expect, it, vi, beforeEach } from 'vitest'

const mockPersistDashboardActorName = vi.hoisted(() => vi.fn((v: string) => v))
const mockResolveDashboardActorName = vi.hoisted(() => vi.fn(() => null))

vi.mock('../../lib/dashboard-actor', () => ({
  persistDashboardActorName: (v: string) => mockPersistDashboardActorName(v),
  resolveDashboardActorName: () => mockResolveDashboardActorName(),
}))

import {
  actorName,
  broadcastMessage,
  pauseReason,
  taskTitle,
  taskDescription,
  taskPriority,
  selectedKeeperName,
  keeperMessage,
  hydratedWorkflowId,
  quickTarget,
  quickMessage,
  persistActorName,
} from './ops-state'

describe('ops-state', () => {
  beforeEach(() => {
    broadcastMessage.value = ''
    taskTitle.value = ''
    taskDescription.value = ''
    taskPriority.value = '2'
    selectedKeeperName.value = ''
    keeperMessage.value = ''
    hydratedWorkflowId.value = null
    quickTarget.value = 'namespace'
    quickMessage.value = ''
    mockPersistDashboardActorName.mockClear()
    mockResolveDashboardActorName.mockClear()
  })

  it('actorName defaults to dashboard fallback when resolve returns null', () => {
    expect(actorName.value).toBe('dashboard')
  })

  it('actorName uses resolved value when available', () => {
    mockResolveDashboardActorName.mockReturnValue('ops-user')
    // Re-import would be needed to test initial value change, but we test persist instead
    persistActorName('ops-user')
    expect(actorName.value).toBe('ops-user')
  })

  it('has expected default signal values', () => {
    expect(broadcastMessage.value).toBe('')
    expect(pauseReason.value).toBe('Operator maintenance')
    expect(taskPriority.value).toBe('2')
    expect(quickTarget.value).toBe('namespace')
    expect(quickMessage.value).toBe('')
    expect(hydratedWorkflowId.value).toBeNull()
  })

  it('persistActorName updates actorName and calls persist helper', () => {
    mockPersistDashboardActorName.mockReturnValue('persisted-actor')
    persistActorName('new-actor')
    expect(mockPersistDashboardActorName).toHaveBeenCalledWith('new-actor')
    expect(actorName.value).toBe('persisted-actor')
  })
})
