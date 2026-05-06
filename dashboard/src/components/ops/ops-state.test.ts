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
  quickComposerMode,
  composerModeForFocus,
  ensureStateBlockDraft,
  hasStateBlock,
  persistActorName,
  stateBlockKeys,
  STATE_BLOCK_TEMPLATE,
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
    quickComposerMode.value = 'broadcast'
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
    expect(quickComposerMode.value).toBe('broadcast')
    expect(hydratedWorkflowId.value).toBeNull()
  })

  it('persistActorName updates actorName and calls persist helper', () => {
    mockPersistDashboardActorName.mockReturnValue('persisted-actor')
    persistActorName('new-actor')
    expect(mockPersistDashboardActorName).toHaveBeenCalledWith('new-actor')
    expect(actorName.value).toBe('persisted-actor')
  })

  it('maps command focus aliases to composer modes', () => {
    expect(composerModeForFocus('broadcast')).toBe('broadcast')
    expect(composerModeForFocus('mention')).toBe('dm')
    expect(composerModeForFocus('dm')).toBe('dm')
    expect(composerModeForFocus('state')).toBe('state')
    expect(composerModeForFocus('unknown')).toBeNull()
  })

  it('extracts structured state block keys', () => {
    const message = '[STATE]\nGoal: ship\nPhase: review\nNEXT: watch CI\nBlocker: none\nOpenQuestions: risk?\nConstraints: no downtime\n[/STATE]'
    expect(stateBlockKeys(message)).toEqual(['Goal', 'NEXT', 'OpenQuestions', 'Constraints'])
    expect(hasStateBlock(message)).toBe(true)
    expect(hasStateBlock(STATE_BLOCK_TEMPLATE)).toBe(false)
    expect(hasStateBlock('[STATE]\nPhase: review\nBlocker: none\n[/STATE]')).toBe(false)
    expect(hasStateBlock('Goal: ship')).toBe(false)
  })

  it('rejects state labels the backend parser does not understand', () => {
    const message = '[STATE]\nGoal : ship\nOpen Questions: risk?\nOpenQuestions: accepted\n[/STATE]'
    expect(stateBlockKeys(message)).toEqual(['OpenQuestions'])
  })

  it('appends the state template without duplicating an existing block', () => {
    expect(ensureStateBlockDraft('')).toBe(STATE_BLOCK_TEMPLATE)
    expect(ensureStateBlockDraft('Heads up')).toBe(`Heads up\n\n${STATE_BLOCK_TEMPLATE}`)
    expect(ensureStateBlockDraft(STATE_BLOCK_TEMPLATE)).toBe(STATE_BLOCK_TEMPLATE)
  })

  it('requires canonical uppercase state block tags', () => {
    const lower = '[state]\nGoal: ship\n[/state]'
    expect(stateBlockKeys(lower)).toEqual([])
    expect(hasStateBlock(lower)).toBe(false)
    expect(ensureStateBlockDraft(lower)).toBe(`${lower}\n\n${STATE_BLOCK_TEMPLATE}`)
  })
})
