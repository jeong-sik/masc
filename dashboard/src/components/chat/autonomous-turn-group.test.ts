// Autonomous keeper turns in the chat transcript.
//
// These rows have no chat-store row by design (RFC-0351 §5 keeps the wake
// marker and inert prose out of the durable transcript); the backend projects
// them from the raw-trace store. A keeper wakes far more often than anyone
// talks to it, so the transcript must fold a run of them into one collapsed
// unit instead of listing each between two sentences of conversation.
import { describe, expect, it } from 'vitest'
import type { KeeperConversationEntry } from '../../types'
import { buildChatRenderUnits } from './primitives'
import { chatHistoryEntriesFromRest, isDefaultVisibleConversationEntry } from '../../keeper-state'

const entry = (
  id: string,
  overrides: Partial<KeeperConversationEntry> = {},
): KeeperConversationEntry =>
  ({
    id,
    role: 'assistant',
    source: 'direct_assistant',
    label: 'keeper',
    text: '',
    delivery: 'history',
    ...overrides,
  }) as KeeperConversationEntry

const autonomous = (id: string, timestamp?: string): KeeperConversationEntry =>
  entry(id, { source: 'autonomous_turn', timestamp })

const user = (id: string): KeeperConversationEntry =>
  entry(id, { role: 'user', source: 'direct_user' })

const tool = (id: string): KeeperConversationEntry =>
  entry(id, { role: 'tool', source: 'tool_result' })

describe('buildChatRenderUnits — autonomous turns', () => {
  it('folds a run of consecutive autonomous turns into one unit', () => {
    const units = buildChatRenderUnits(
      [user('u1'), autonomous('a1'), autonomous('a2'), autonomous('a3'), user('u2')],
      true,
    )
    expect(units.map((unit) => unit.kind)).toEqual(['entry', 'autonomousGroup', 'entry'])
    const group = units[1]
    if (group?.kind !== 'autonomousGroup') throw new Error('expected an autonomousGroup')
    expect(group.entries.map((e) => e.id)).toEqual(['a1', 'a2', 'a3'])
  })

  it('keeps separate runs separate so conversation between them stays in place', () => {
    const units = buildChatRenderUnits(
      [autonomous('a1'), user('u1'), autonomous('a2')],
      true,
    )
    expect(units.map((unit) => unit.kind)).toEqual(['autonomousGroup', 'entry', 'autonomousGroup'])
  })

  it('folds autonomous turns even when tool grouping is off', () => {
    // Collapsing them guards against their volume; it is not a preference
    // about how tool calls render.
    const units = buildChatRenderUnits([autonomous('a1'), autonomous('a2')], false)
    expect(units.map((unit) => unit.kind)).toEqual(['autonomousGroup'])
  })

  it('closes an open tool run before starting an autonomous group', () => {
    // Those tool rows belong to the direct turn that preceded the wake, so
    // they must not be swallowed into the autonomous group.
    const units = buildChatRenderUnits([tool('t1'), autonomous('a1')], true)
    expect(units.map((unit) => unit.kind)).toEqual(['toolGroup', 'autonomousGroup'])
  })

  it('leaves a transcript without autonomous turns unchanged', () => {
    const units = buildChatRenderUnits([user('u1'), entry('m1')], true)
    expect(units.map((unit) => unit.kind)).toEqual(['entry', 'entry'])
  })
})

describe('chatHistoryEntriesFromRest — autonomous turn rows', () => {
  const autonomousRow = {
    id: 'autonomous:turn-1',
    role: 'assistant',
    content: 'no work this cycle',
    ts: 1785770777,
    autonomous_turn: {
      turn_id: 'trace-test#41',
      agent_name: 'lane-smith-agent',
      generation: 9,
      model: 'GLM-5-Turbo',
      stop_reason: 'end_turn',
    },
  }

  it('projects the public outcome without raw thinking or tool arguments', () => {
    const [entryOut] = chatHistoryEntriesFromRest('lane-smith', [autonomousRow])
    expect(entryOut?.source).toBe('autonomous_turn')
    expect(entryOut?.text).toBe('no work this cycle')
    expect(entryOut?.traceSteps).toBeUndefined()
    expect(entryOut?.turnRef).toBe('trace-test#41')
  })

  it('is visible without the internal-message toggle', () => {
    const [entryOut] = chatHistoryEntriesFromRest('lane-smith', [autonomousRow])
    expect(entryOut && isDefaultVisibleConversationEntry(entryOut)).toBe(true)
  })

  it('does not advance the direct-conversation source chain', () => {
    // A world-state user row makes the NEXT assistant row internal. An
    // autonomous row between them must not consume that pairing.
    const entries = chatHistoryEntriesFromRest('lane-smith', [
      autonomousRow,
      { role: 'user', content: 'PR 상태 정리해줘', ts: 1785770800 },
      { role: 'assistant', content: '3건 확인했습니다', ts: 1785770801 },
    ])
    expect(entries.map((e) => e.source)).toEqual([
      'autonomous_turn',
      'direct_user',
      'direct_assistant',
    ])
  })

  it('drops a row whose autonomous_turn payload carries no turn id', () => {
    // Unknown shape is not rendered as an empty bubble.
    const entries = chatHistoryEntriesFromRest('lane-smith', [
      { role: 'assistant', content: 'x', ts: 1785770777, autonomous_turn: {} },
    ])
    expect(entries).toEqual([])
  })

  it('keeps absent public text distinct from an explicit empty response', () => {
    const [absent, empty] = chatHistoryEntriesFromRest('lane-smith', [
      { ...autonomousRow, id: 'absent', content: null },
      { ...autonomousRow, id: 'empty', content: '' },
    ])
    expect(absent?.text).toBe('공개된 응답 없음')
    expect(absent?.rawText).toBeNull()
    expect(empty?.text).toBe('')
    expect(empty?.rawText).toBe('')
  })
})
